// OpenClaw Game Master "ears": runs on the silent "ears" bot in the TFAR channel and hands each
// speaker's utterances there to the Game Master as WAV files (/voice_in = openclaw-gm/voice_in), which transcribes them and answers calls to
// HQ / Overlord. Audio never leaves this host. Loaded by the Game Master over the local web API
// (plugin load OpenClawEars.cs), since TS3AudioBot 0.12 doesn't autostart bot plugins.
using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using TS3AudioBot.Plugins;
using TSLib;
using TSLib.Audio;
using TSLib.Full;

namespace OpenClaw
{
	public class OpenClawEars : IBotPlugin, IAudioPassiveConsumer
	{
		private const string OutDir = "/voice_in";
		private const int Rate = 48_000;                   // DecoderPipe output: 48 kHz stereo 16-bit
		private const int MinBytes = Rate * 2 * 6 / 10;    // shorter than 0.6 s mono: a click, skip
		private const int MaxBytes = Rate * 2 * 20;        // cut very long transmissions at 20 s
		private static readonly TimeSpan Gap = TimeSpan.FromMilliseconds(450);  // silence = end of utterance

		private readonly TsFullClient client;
		private readonly object gate = new object();
		private readonly Dictionary<ushort, Utterance> talking = new Dictionary<ushort, Utterance>();
		private IAudioPassiveConsumer? previous;
		private DecoderPipe? decoder;
		private Timer? timer;

		private sealed class Utterance
		{
			public readonly MemoryStream Pcm = new MemoryStream();
			public readonly DateTime Start = DateTime.UtcNow;
			public DateTime Last;
		}

		public OpenClawEars(TsFullClient client) { this.client = client; }

		public bool Active => true;

		public void Initialize()
		{
			Directory.CreateDirectory(OutDir);
			decoder = new DecoderPipe { OutStream = this };
			var guarded = new Guard(new AudioPacketReader { OutStream = decoder });
			previous = client.OutStream;
			client.OutStream = previous is null ? (IAudioPassiveConsumer)guarded : new Tee(guarded, previous);
			timer = new Timer(_ => { Flush(); WriteWhisperStats(); }, null, 200, 200);
		}

		// Called on the network thread with decoded PCM, one call per voice packet.
		public void Write(Span<byte> data, Meta? meta)
		{
			if (meta is null) return;
			var sender = meta.In.Sender;
			// OVERLORD whispers into the channel from outside (TFAR mutes non-game clients in it);
			// players talk normally, so skipping whispers keeps it from hearing itself.
			if (sender == client.ClientId || meta.In.Whisper) return;
			lock (gate)
			{
				if (!talking.TryGetValue(sender.Value, out var u))
					talking[sender.Value] = u = new Utterance();
				for (int i = 0; i + 3 < data.Length; i += 4)  // keep the left channel: mono 16-bit
				{
					u.Pcm.WriteByte(data[i]);
					u.Pcm.WriteByte(data[i + 1]);
				}
				u.Last = DateTime.UtcNow;
				if (u.Pcm.Length >= MaxBytes)
				{
					talking.Remove(sender.Value);
					Save(sender.Value, u);
				}
			}
		}

		private long lastWhisperCount = -1;
		private void WriteWhisperStats()
		{
			var n = Interlocked.Read(ref Guard.WhisperPackets);
			if (n == lastWhisperCount) return;
			lastWhisperCount = n;
			try { File.WriteAllText(Path.Combine(OutDir, ".whispers"), $"{n} {Guard.LastWhisper:o}\n"); }
			catch (Exception) { }
		}

		private void Flush()
		{
			var done = new List<(ushort, Utterance)>();
			lock (gate)
			{
				var now = DateTime.UtcNow;
				foreach (var kv in talking)
					if (now - kv.Value.Last > Gap)
						done.Add((kv.Key, kv.Value));
				foreach (var (id, _) in done)
					talking.Remove(id);
			}
			foreach (var (id, u) in done)
				Save(id, u);
		}

		// <clid>_<startMs>_<endMs>.wav: the Game Master matches the start to TFAR radio key presses.
		private static void Save(ushort clientId, Utterance u)
		{
			var pcm = u.Pcm;
			if (pcm.Length < MinBytes) return;
			try
			{
				var name = $"{clientId}_{new DateTimeOffset(u.Start).ToUnixTimeMilliseconds()}_{new DateTimeOffset(u.Last).ToUnixTimeMilliseconds()}.wav";
				var tmp = Path.Combine(OutDir, "." + name);  // the Game Master skips dotfiles
				using (var f = File.Create(tmp))
				using (var w = new BinaryWriter(f))
				{
					int len = (int)pcm.Length;
					w.Write(new[] { (byte)'R', (byte)'I', (byte)'F', (byte)'F' });
					w.Write(36 + len);
					w.Write(new[] { (byte)'W', (byte)'A', (byte)'V', (byte)'E', (byte)'f', (byte)'m', (byte)'t', (byte)' ' });
					w.Write(16); w.Write((short)1); w.Write((short)1);  // PCM, mono
					w.Write(Rate); w.Write(Rate * 2); w.Write((short)2); w.Write((short)16);
					w.Write(new[] { (byte)'d', (byte)'a', (byte)'t', (byte)'a' });
					w.Write(len);
					pcm.WriteTo(f);
				}
				File.Move(tmp, Path.Combine(OutDir, name));
			}
			catch (Exception) { /* a lost utterance isn't worth taking the bot down */ }
		}

		public void Dispose()
		{
			timer?.Dispose();
			if (client.OutStream is Guard || client.OutStream is Tee)
				client.OutStream = previous;
			decoder?.Dispose();
		}

		// Runs on the bot's network thread: an exception here (the Opus decoder throws on a bad packet)
		// would take the whole TS3AudioBot process down, so drop the packet instead. Whispers (OVERLORD
		// talking into the channel) are skipped before decoding.
		private sealed class Guard : IAudioPassiveConsumer
		{
			private readonly IAudioPassiveConsumer inner;
			public static long WhisperPackets;
			public static DateTime LastWhisper;
			public Guard(IAudioPassiveConsumer inner) { this.inner = inner; }
			public bool Active => true;
			public void Write(Span<byte> data, Meta? meta)
			{
				if (meta is null) return;
				if (meta.In.Whisper)
				{
					// Diagnostic: proves OVERLORD's whisper reaches the TFAR channel (/voice_in/.whispers).
					Interlocked.Increment(ref WhisperPackets);
					LastWhisper = DateTime.UtcNow;
					return;
				}
				try { inner.Write(data, meta); }
				catch (Exception) { /* undecodable packet */ }
			}
		}

		private sealed class Tee : IAudioPassiveConsumer
		{
			private readonly IAudioPassiveConsumer a, b;
			public Tee(IAudioPassiveConsumer a, IAudioPassiveConsumer b) { this.a = a; this.b = b; }
			public bool Active => true;
			public void Write(Span<byte> data, Meta? meta)
			{
				// AudioPacketReader rewrites meta, so give the other consumer its own copy of the packet.
				var copy = data.ToArray();
				a.Write(data, meta);
				b.Write(copy, meta);
			}
		}
	}
}
