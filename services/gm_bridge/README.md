# Game Master bridge (A3GM)

Lets the OpenClaw Game Master (`~/openclaw-gm`) act in the running Antistasi mission without
RCON. BattlEye RCON can't run SQF, so the bridge is a server-only addon instead:

- `a3gm_x64.so` (`a3gm.c`): a tiny callExtension that hands over the oldest `*.cmd` file in
  `/arma3/gm_spool/inbox` (bind mount of `./gm_spool`) and deletes it.
- `a3gm.pbo` (`functions/fn_init.sqf`): after Antistasi's `serverInitDone`, polls the extension
  every 2 s and runs the command through a fixed table of handlers. Commands are data
  (`parseSimpleArray`), never code.

| Action | Args | Effect |
|---|---|---|
| `SAY` | text | `OVERLORD: …` from "HQ" in each player's Side channel |
| `AIRDROP` | `AMMO`/`MEDICAL`/`LAUNCHER`/`SUPPORT`, player | parachuted crate 60-120 m from the player, green smoke on landing |
| `MORTAR` | player, rounds 1-6 | friendly 82 mm rounds on enemies 200-800 m from the player; never within 200 m of any player |
| `WEATHER` | overcast, rain, fog (≤ 0.5) | immediate weather change |
| `QRF` | player, size 2-8 | occupant infantry (from `A3A_faction_occ` unit classes) 500-700 m out, search-and-destroy on the player; cleaned up when dead or after 30 min with no player near |
| `STATUS` | – | `name@grid:enemiesWithin800m;…` |
| `INTEL` | player | readable report: grid, nearest town, enemies within 800 m (closest bearing/distance), 3 nearest enemy zones, active Antistasi missions (`A3A_tasksData`) |
| `MISSION` | type (`AS`/`CON`/`DES`/`LOG`/`SUPP`/`RES`/`CONVOY`/`RAN`), player | starts an Antistasi mission via `A3A_fnc_missionRequest` (as Petros does) and returns the new task, or why not |

An empty player name means "the player with the most enemies nearby". Every command logs one
line, which the Game Master waits for:

```
A3GM|done|<id>|<ACTION>|ok|<detail>
A3GM|done|<id>|<ACTION>|fail|<reason>
```

Startup lines: `A3GM|installed`, then `A3GM|ready` once the campaign is loaded
(`A3GM|error|...` if the extension didn't load).

## Chat relay

The addon also pushes a `HandleChatMessage` hook to every player's client (`remoteExec` with a JIP
id, allowed by Antistasi's `CfgRemoteExec` mode 2; headless clients skip it). Each client sends
only the chat its own player types (Global, Side, Command, Group, Vehicle, Direct) to the server,
which takes the sender from `remoteExecutedOwner`, allows one message per second per player and
logs:

```
A3CHAT|<channel 0-5>|<side>|<name>|<text>
```

AI talk the players see on Side, Command and Group (Antistasi HQ messages, AI squad callouts) is
reported too; the server drops repeats of the same line within 10 s, since every client in the
squad sees it:

```
A3AICHAT|<channel 1-3>|<side>|<speaker>|<text>
```

The Game Master posts both into the TFAR TeamSpeak channel, speaks AI talk in the radio voice
(rate-limited), and answers messages addressed to "HQ" or "Overlord" (`chat:` in openclaw-gm's
`config.yaml`). Each client logs `A3GM|chat hook received` in its own RPT.

## Radio keys

The client hook also registers a global TFAR `OnTangent` handler, so the server logs
`A3RADIO|<name>|<sw|lr>|<down|up>` whenever a player keys a radio. The Game Master matches these
to speech heard on TeamSpeak to know who is calling, by in-game name.

## Build

```bash
python3 services/gm_bridge/build.py            # pack the PBO, copy the prebuilt .so
python3 services/gm_bridge/build.py --compile  # also rebuild the .so (amd64 container, QEMU)
```

Both land in `servermods/@a3gm`, which loads at the next server start. There is no hot-load:
the extension needs a server restart.
