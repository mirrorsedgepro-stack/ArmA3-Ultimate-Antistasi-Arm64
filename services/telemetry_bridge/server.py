#!/usr/bin/env python3
"""
Arma 3 Dedicated Server Telemetry Bridge (for ArmA3-Monitor on Vercel).

Every value served here is observed, never invented:
  * Live status / player list ...... Valve A2S query against the local server.
  * Server FPS + Antistasi stats ... A3A_fnc_logPerformance lines in the container
                                     log. Antistasi only logs these while players
                                     are connected, so each sample carries its
                                     timestamp and the API reports its age.
  * Headless clients ............... Antistasi addHC / onHeadlessClientDisconnect
                                     log events.
  * Player sessions / history ...... "Player X connected (id=...)" /
                                     "Player X disconnected." engine log lines,
                                     persisted to /data so they survive restarts.
  * Server settings ................ Parsed from the mounted configs/main.cfg.

When something is unknown the field is null; the frontend must show "unknown".
"""

import json
import os
import re
import socket
import struct
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HOST = os.environ.get("TELEMETRY_HOST", "0.0.0.0")
PORT = int(os.environ.get("TELEMETRY_PORT", "2310"))
A2S_HOST = os.environ.get("A2S_HOST", "127.0.0.1")
A2S_PORT = int(os.environ.get("A2S_PORT", "2303"))
GAME_PORT = int(os.environ.get("PORT", "2302"))
PUBLIC_IP = os.environ.get("SERVER_PUBLIC_IP", "")
API_KEY = os.environ.get("TELEMETRY_API_KEY", "").strip()
DOCKER_SOCKET = os.environ.get("DOCKER_SOCKET", "/var/run/docker.sock")
CONTAINER = os.environ.get("ARMA_CONTAINER_NAME", "arma3_antistasi")
EXPECTED_HCS = int(os.environ.get("HEADLESS_CLIENTS", "3"))
MAIN_CFG = os.environ.get("ARMA_MAIN_CFG", "/config/main.cfg")
DATA_DIR = os.environ.get("TELEMETRY_DATA_DIR", "/data")
SESSIONS_FILE = os.path.join(DATA_DIR, "sessions.json")
EVENTS_FILE = os.path.join(DATA_DIR, "events.json")

A2S_CACHE_SEC = 3.0


def now_utc():
    return datetime.now(timezone.utc)


def iso(dt):
    return dt.astimezone(timezone.utc).isoformat().replace("+00:00", "Z") if dt else None


def parse_docker_ts(ts):
    # 2026-10-05T19:13:18.123456789Z -> aware datetime (truncate to microseconds)
    m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?Z", ts)
    if not m:
        return None
    frac = (m.group(2) or ".0")[:7]
    return datetime.strptime(m.group(1) + frac, "%Y-%m-%dT%H:%M:%S.%f").replace(tzinfo=timezone.utc)


# ---------------------------------------------------------------------------
# Docker Engine API (unix socket, HTTP/1.0 so responses are never chunked)
# ---------------------------------------------------------------------------
def docker_request(path, timeout=5.0):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(DOCKER_SOCKET)
    s.sendall(f"GET {path} HTTP/1.0\r\nHost: docker\r\n\r\n".encode())
    return s


def docker_json(path):
    s = docker_request(path)
    buf = b""
    try:
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    finally:
        s.close()
    head, _, body = buf.partition(b"\r\n\r\n")
    status = head.split(b"\r\n", 1)[0]
    if b" 200 " not in status:
        raise RuntimeError(f"docker {path}: {status.decode(errors='replace')}")
    return json.loads(body)


def container_started_at():
    try:
        info = docker_json(f"/containers/{CONTAINER}/json")
        state = info.get("State", {})
        if not state.get("Running"):
            return None
        return parse_docker_ts(state.get("StartedAt", ""))
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Persistent session store
# ---------------------------------------------------------------------------
class SessionStore:
    """Player sessions keyed by (uid, connectedAt) so log replays are idempotent."""

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        self.sessions = {}  # key -> dict(name, uid, connectedAt, disconnectedAt)
        self._dirty = False
        self._load()

    def _load(self):
        try:
            with open(self.path) as f:
                for s in json.load(f):
                    self.sessions[f"{s['uid']}|{s['connectedAt']}"] = s
        except FileNotFoundError:
            pass
        except Exception as e:
            print(f"[sessions] could not load {self.path}: {e}", file=sys.stderr)

    def save(self):
        with self.lock:
            if not self._dirty:
                return
            data = sorted(self.sessions.values(), key=lambda s: s["connectedAt"])
            self._dirty = False
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f)
        os.replace(tmp, self.path)

    def connect(self, name, uid, ts):
        key = f"{uid}|{iso(ts)}"
        with self.lock:
            # A reconnect without a disconnect line closes the stale session.
            for s in self.sessions.values():
                if s["uid"] == uid and s["disconnectedAt"] is None and s["connectedAt"] < iso(ts):
                    s["disconnectedAt"] = iso(ts)
                    self._dirty = True
            if key not in self.sessions:
                self.sessions[key] = {"name": name, "uid": uid, "connectedAt": iso(ts), "disconnectedAt": None}
                self._dirty = True

    def disconnect(self, name, ts):
        with self.lock:
            open_ = [s for s in self.sessions.values()
                     if s["name"] == name and s["disconnectedAt"] is None and s["connectedAt"] <= iso(ts)]
            for s in open_:
                s["disconnectedAt"] = iso(ts)
                self._dirty = True

    def close_all_open(self, ts):
        with self.lock:
            for s in self.sessions.values():
                if s["disconnectedAt"] is None and s["connectedAt"] <= iso(ts):
                    s["disconnectedAt"] = iso(ts)
                    self._dirty = True

    def snapshot(self):
        with self.lock:
            return [dict(s) for s in self.sessions.values()]


SESSIONS = SessionStore(SESSIONS_FILE)


class EventStore:
    """Campaign event feed keyed by (type, second, subject) so log replays are idempotent.

    The engine writes some lines (e.g. "X was killed") once per machine, so
    duplicates within the same second collapse onto one key.
    """

    MAX_EVENTS = 2000

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        self.events = {}
        self._dirty = False
        try:
            with open(self.path) as f:
                for e in json.load(f):
                    self.events[e["id"]] = e
        except FileNotFoundError:
            pass
        except Exception as e:
            print(f"[events] could not load {self.path}: {e}", file=sys.stderr)

    def add(self, ts, etype, subject, **fields):
        base = ts.replace(microsecond=0)
        t = iso(base)
        key = f"{etype}|{t}|{subject}"
        # Copies of one line from several machines can straddle a second boundary.
        nearby = {f"{etype}|{iso(base.fromtimestamp(base.timestamp() - d, timezone.utc))}|{subject}" for d in (1, 2)}
        with self.lock:
            if key in self.events or nearby & self.events.keys():
                return
            self.events[key] = {"id": key, "t": t, "type": etype, **fields}
            if len(self.events) > self.MAX_EVENTS:
                for k in sorted(self.events, key=lambda k: self.events[k]["t"])[: len(self.events) - self.MAX_EVENTS]:
                    del self.events[k]
            self._dirty = True

    def save(self):
        with self.lock:
            if not self._dirty:
                return
            data = sorted(self.events.values(), key=lambda e: e["t"])
            self._dirty = False
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f)
        os.replace(tmp, self.path)

    def snapshot(self):
        with self.lock:
            return sorted((dict(e) for e in self.events.values()), key=lambda e: e["t"], reverse=True)


EVENTS = EventStore(EVENTS_FILE)


# ---------------------------------------------------------------------------
# Log follower: FPS, Antistasi stats, HCs, player sessions
# ---------------------------------------------------------------------------
class LogState:
    def __init__(self):
        self.lock = threading.Lock()
        self.reset()
        self.follower_ok = False
        self.follower_error = None

    def reset(self):
        self.perf = None            # dict incl. sampledAt
        self.hc_ids = []            # Antistasi HC owner IDs currently registered
        self.hc_updated_at = None
        self.last_log_at = None
        self.killfeed_at = None     # when the A3KF hook last reported itself installed


LOG = LogState()

RE_LINE = re.compile(r"^(\S+Z) (.*)$")
RE_PERF = re.compile(
    r"A3A_fnc_logPerformance \|\s+ServerFPS=([\d.]+)\s+Players=(\d+)\s+DeadUnits=(\d+)\s+AllUnits=(\d+)"
    r".*?AllVehicles=(\d+).*?FactionCash=(\d+)\s+HR=(\d+)\s+OccAggro=(\d+)\s+InvAggro=(\d+)\s+Warlevel=(\d+)"
)
RE_HC_ADD = re.compile(r"A3A_fnc_addHC \| Headless Client Connected: \[([\d,\s]*)\]")
RE_HC_DEL = re.compile(r"Headless client ID (\d+) disconnected from HC array \[([\d,\s]*)\]")
RE_CONNECT = re.compile(r"^\s*\d{1,2}:\d\d:\d\d Player (.+) connected \(id=([^)]+)\)\.\s*$")
RE_DISCONNECT = re.compile(r"^\s*\d{1,2}:\d\d:\d\d Player (.+) disconnected\.\s*$")
RE_SERVER_START = re.compile(r"Dedicated host created\.")
# Campaign events
RE_KILLED = re.compile(r"^\s*\d{1,2}:\d\d:\d\d\s+> (.+) was killed\s*$")
RE_CAPTURE = re.compile(r"A3A_fnc_mrkWIN \| \w+ at (\d+) \((\w+)\): Flag capture completed by (.+?)\s*(?:\||$)")
RE_ATTACK_START = re.compile(r'A3A_fnc_singleAttack \| Starting attack with parameters \["(\w+)",(WEST|EAST)')
RE_ATTACK_END = re.compile(r"A3A_fnc_singleAttack \| \w+ attack to (\w+) (has been defeated|captured the marker)")
RE_PROMOTE = re.compile(r"A3A_fnc_promotePlayer \| Promoting (.+) player \(Current Rank: \w+\) to new (\w+)\.")
RE_UNIT_PLAYER = re.compile(r"\(([^()]+)\)\s*$")  # "R Alpha 1-2:3 (INTENT)" -> INTENT
# Kill feed lines from services/killfeed (A3KF|1|kind|victim|vSide|vPlayer|killer|kSide|kPlayer|weapon|dist)
RE_KILL = re.compile(
    r"A3KF\|1\|(man|veh)\|([^|]*)\|(\w*)\|(true|false)\|([^|]*)\|(\w*)\|(true|false)\|([^|]*)\|(-?\d+)\s*$"
)
RE_KILLFEED_INSTALLED = re.compile(r"A3KF\|installed\s*$")


def ids(s):
    return [int(x) for x in re.findall(r"\d+", s)]


def handle_line(ts, text):
    with LOG.lock:
        LOG.last_log_at = ts

    if RE_SERVER_START.search(text):
        # Server process restarted: nobody is connected, HC registrations are gone.
        SESSIONS.close_all_open(ts)
        with LOG.lock:
            LOG.hc_ids = []
            LOG.hc_updated_at = ts
            LOG.killfeed_at = None  # the hook lives in the mission; a restart drops it unless the addon loads
        return

    m = RE_PERF.search(text)
    if m:
        with LOG.lock:
            LOG.perf = {
                "serverFps": round(float(m.group(1)), 1),
                # Antistasi's "Players" includes headless clients.
                "connectedClientsInclHCs": int(m.group(2)),
                "deadUnits": int(m.group(3)),
                "allUnits": int(m.group(4)),
                "allVehicles": int(m.group(5)),
                "factionCash": int(m.group(6)),
                "hr": int(m.group(7)),
                "occAggro": int(m.group(8)),
                "invAggro": int(m.group(9)),
                "warLevel": int(m.group(10)),
                "sampledAt": ts,
            }
        return

    m = RE_HC_ADD.search(text)
    if m:
        with LOG.lock:
            LOG.hc_ids = ids(m.group(1))
            LOG.hc_updated_at = ts
        return

    m = RE_HC_DEL.search(text)
    if m:
        gone, arr = int(m.group(1)), ids(m.group(2))
        with LOG.lock:
            LOG.hc_ids = [i for i in arr if i != gone]
            LOG.hc_updated_at = ts
        return

    m = RE_CONNECT.match(text)
    if m:
        name, uid = m.group(1), m.group(2)
        if not uid.startswith("HC"):  # headless clients connect with id=HC<n>
            SESSIONS.connect(name, uid, ts)
            EVENTS.add(ts, "join", name, player=name)
        return

    m = RE_DISCONNECT.match(text)
    if m:
        name = m.group(1)
        if not is_hc_name(name) and name in known_player_names():
            EVENTS.add(ts, "leave", name, player=name)
        SESSIONS.disconnect(name, ts)
        return

    handle_campaign_event(ts, text)


def known_player_names():
    return {s["name"] for s in SESSIONS.snapshot()}


# Antistasi marker prefix -> display name
MARKER_KINDS = {
    "outpost": "Outpost", "resource": "Resource", "factory": "Factory", "seaport": "Seaport",
    "airport": "Airbase", "milbase": "Military base", "Synd_HQ": "Rebel HQ",
}


def marker_label(marker):
    prefix, _, num = marker.partition("_")
    if marker in MARKER_KINDS:
        return MARKER_KINDS[marker]
    kind = MARKER_KINDS.get(prefix)
    if not kind:
        return marker
    return f"{kind} {num}" if num.isdigit() else kind


def handle_campaign_event(ts, text):
    # Cheap pre-filter: every campaign line contains one of these.
    if "was killed" not in text and "A3A_fnc_" not in text and "A3KF|" not in text:
        return

    if "A3KF|" in text:
        m = RE_KILL.search(text)
        if m:
            kind, victim, v_side, v_player, killer, k_side, k_player, weapon, dist = m.groups()
            dist = int(dist)
            EVENTS.add(ts, "kill", f"{victim}|{killer}",
                       kind=kind, victim=victim, victimSide=v_side or None, victimIsPlayer=v_player == "true",
                       killer=killer or None, killerSide=k_side or None, killerIsPlayer=k_player == "true",
                       weapon=weapon or None, distance=dist if dist >= 0 else None)
        elif RE_KILLFEED_INSTALLED.search(text):
            with LOG.lock:
                LOG.killfeed_at = ts
        return

    m = RE_KILLED.match(text)
    if m:
        name = m.group(1)
        # Only real players: guards against AI names or chat text that looks alike.
        if name in known_player_names():
            EVENTS.add(ts, "death", name, player=name)
        return

    m = RE_CAPTURE.search(text)
    if m:
        grid, marker, by = m.group(1), m.group(2), m.group(3).strip()
        pm = RE_UNIT_PLAYER.search(by)
        player = pm.group(1) if pm else None  # "commanderX" is the rebel commander's unit, not a name
        EVENTS.add(ts, "capture", marker, place=marker_label(marker), marker=marker, grid=grid,
                   player=player, by=None if player else "Rebel commander")
        return

    m = RE_ATTACK_START.search(text)
    if m:
        marker, side = m.group(1), m.group(2)
        EVENTS.add(ts, "counterattack", marker, place=marker_label(marker), marker=marker,
                   enemy="Occupants" if side == "WEST" else "Invaders")
        return

    m = RE_ATTACK_END.search(text)
    if m:
        marker, outcome = m.group(1), m.group(2)
        EVENTS.add(ts, "defended" if outcome == "has been defeated" else "lost", marker,
                   place=marker_label(marker), marker=marker)
        return

    m = RE_PROMOTE.search(text)
    if m:
        EVENTS.add(ts, "promotion", m.group(1), player=m.group(1), rank=m.group(2).capitalize())


def follow_logs_forever():
    """Stream the container log (from the start, then follow). Reconnects on exit."""
    while True:
        try:
            with LOG.lock:
                LOG.reset()
            s = docker_request(
                f"/containers/{CONTAINER}/logs?follow=1&stdout=1&stderr=1&timestamps=1&tail=all",
                timeout=None,
            )
            s.settimeout(None)
            f = s.makefile("rb")
            # HTTP headers
            status = f.readline()
            if b" 200 " not in status:
                raise RuntimeError(status.decode(errors="replace").strip())
            while f.readline() not in (b"\r\n", b"\n", b""):
                pass
            LOG.follower_ok = True
            LOG.follower_error = None
            pending = b""
            last_save = time.time()
            while True:
                header = f.read(8)
                if len(header) < 8:
                    break
                if header[0] in (0, 1, 2) and header[1:4] == b"\x00\x00\x00":
                    size = struct.unpack(">I", header[4:8])[0]
                    payload = f.read(size)
                else:  # TTY container: raw stream
                    payload = header + f.readline()
                pending += payload
                *lines, pending = pending.split(b"\n")
                for raw in lines:
                    line = raw.decode("utf-8", errors="replace").rstrip("\r")
                    m = RE_LINE.match(line)
                    if not m:
                        continue
                    ts = parse_docker_ts(m.group(1))
                    if ts:
                        handle_line(ts, m.group(2))
                if time.time() - last_save > 10:
                    SESSIONS.save()
                    EVENTS.save()
                    last_save = time.time()
            SESSIONS.save()
            EVENTS.save()
        except Exception as e:
            LOG.follower_error = str(e)
            print(f"[logs] follower error: {e}", file=sys.stderr)
        LOG.follower_ok = False
        time.sleep(10)


# ---------------------------------------------------------------------------
# A2S
# ---------------------------------------------------------------------------
def read_cstring(data, offset):
    end = data.find(b"\x00", offset)
    if end == -1:
        return data[offset:].decode("utf-8", errors="replace"), len(data)
    return data[offset:end].decode("utf-8", errors="replace"), end + 1


def a2s_request(sock, payload):
    sock.sendto(payload, (A2S_HOST, A2S_PORT))
    res, _ = sock.recvfrom(65535)
    if res[4:5] == b"\x41":  # challenge
        chal = res[5:9]
        if payload[4:5] == b"\x54":
            sock.sendto(payload + chal, (A2S_HOST, A2S_PORT))
        else:
            sock.sendto(payload[:5] + chal, (A2S_HOST, A2S_PORT))
        res, _ = sock.recvfrom(65535)
    return res


def query_a2s():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(2.0)
    try:
        t0 = time.perf_counter()
        res = a2s_request(sock, b"\xff\xff\xff\xff\x54Source Engine Query\x00")
        ping = round((time.perf_counter() - t0) * 1000)
        if res[4:5] != b"\x49":
            raise ValueError("bad A2S_INFO reply")
        i = 6
        name, i = read_cstring(res, i)
        map_name, i = read_cstring(res, i)
        _folder, i = read_cstring(res, i)
        mission, i = read_cstring(res, i)
        i += 2
        players, max_players, _bots = res[i], res[i + 1], res[i + 2]
        i += 5
        visibility, vac = res[i], res[i + 1]
        i += 2
        version, i = read_cstring(res, i)

        roster = []
        pres = a2s_request(sock, b"\xff\xff\xff\xff\x55\xff\xff\xff\xff")
        if pres[4:5] == b"\x44":
            j = 6
            for _ in range(pres[5]):
                if j >= len(pres):
                    break
                j += 1
                pname, j = read_cstring(pres, j)
                if j + 8 > len(pres):
                    break
                score = struct.unpack("<i", pres[j:j + 4])[0]
                dur = struct.unpack("<f", pres[j + 4:j + 8])[0]
                j += 8
                if pname.strip():
                    roster.append({"name": pname, "score": score, "timePlayedSeconds": int(dur)})
        return {
            "ok": True, "name": name, "map": map_name, "mission": mission, "version": version,
            "rawPlayerCount": players, "maxPlayers": max_players, "passwordProtected": bool(visibility),
            "battleye": bool(vac), "ping": ping, "roster": roster,
        }
    except Exception as e:
        return {"ok": False, "error": str(e)}
    finally:
        sock.close()


_a2s_cache = {"t": 0.0, "v": None}
_a2s_lock = threading.Lock()


def cached_a2s():
    with _a2s_lock:
        if _a2s_cache["v"] is None or time.time() - _a2s_cache["t"] > A2S_CACHE_SEC:
            _a2s_cache["v"] = query_a2s()
            _a2s_cache["t"] = time.time()
        return _a2s_cache["v"]


# ---------------------------------------------------------------------------
# main.cfg facts
# ---------------------------------------------------------------------------
def read_server_config():
    try:
        with open(MAIN_CFG, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except Exception:
        return None
    text = re.sub(r"//[^\n]*", "", text)

    def num(key):
        m = re.search(rf"^\s*{key}\s*=\s*(-?\d+)\s*;", text, re.M | re.I)
        return int(m.group(1)) if m else None

    diff = re.search(r'difficulty\s*=\s*"([^"]+)"', text, re.I)
    return {
        "battlEye": num("BattlEye"),
        "verifySignatures": num("verifySignatures"),
        "maxPlayers": num("maxPlayers"),
        "voiceEnabled": None if num("disableVoN") is None else num("disableVoN") == 0,
        "persistent": None if num("persistent") is None else num("persistent") == 1,
        "difficulty": diff.group(1) if diff else None,
    }


# ---------------------------------------------------------------------------
# Derived views
# ---------------------------------------------------------------------------
def is_hc_name(name):
    return bool(re.match(r"^headlessclient( \(\d+\))?$", name, re.I)) or "-hc-" in name.lower()


def build_telemetry():
    a2s = cached_a2s()
    started = container_started_at()
    now = now_utc()
    with LOG.lock:
        perf = dict(LOG.perf) if LOG.perf else None
        hc_ids = list(LOG.hc_ids)
        hc_at = LOG.hc_updated_at
        killfeed_at = LOG.killfeed_at
    if perf:
        perf["ageSeconds"] = int((now - perf["sampledAt"]).total_seconds())
        perf["sampledAt"] = iso(perf["sampledAt"])

    humans = [p for p in a2s.get("roster", []) if not is_hc_name(p["name"])] if a2s.get("ok") else []
    for idx, p in enumerate(humans, 1):
        p["id"] = idx

    out = {
        "status": "online" if a2s.get("ok") else ("offline" if started is None else "unreachable"),
        "ip": PUBLIC_IP or None,
        "port": GAME_PORT,
        "queryPort": A2S_PORT,
        "querySource": "telemetry_bridge",
        "lastUpdated": iso(now),
        "players": len(humans) if a2s.get("ok") else None,
        "playerList": humans,
        "uptimeSeconds": int((now - started).total_seconds()) if started else None,
        "containerStartedAt": iso(started),
        "platform": "Linux aarch64 (Arma 3 x86_64 server under FEX-Emu)",
        # Antistasi only writes performance samples while players are connected.
        "performance": perf,
        "serverFps": perf["serverFps"] if perf and perf["ageSeconds"] <= 90 else None,
        "headlessClients": {
            "expected": EXPECTED_HCS,
            "active": len(hc_ids),
            "updatedAt": iso(hc_at),
        } if LOG.follower_ok or hc_at else None,
        "serverConfig": read_server_config(),
        "logFollower": {"ok": LOG.follower_ok, "error": LOG.follower_error},
        "killFeed": {"installedAt": iso(killfeed_at)} if killfeed_at else None,
    }
    if a2s.get("ok"):
        out.update({k: a2s[k] for k in ("name", "map", "mission", "version", "maxPlayers",
                                         "passwordProtected", "battleye", "ping")})
    else:
        out["a2sError"] = a2s.get("error")
    return out


def build_players():
    sessions = SESSIONS.snapshot()
    now = now_utc()
    roster = {}
    for s in sessions:
        start = datetime.fromisoformat(s["connectedAt"].replace("Z", "+00:00"))
        end = datetime.fromisoformat(s["disconnectedAt"].replace("Z", "+00:00")) if s["disconnectedAt"] else now
        r = roster.setdefault(s["uid"], {
            "name": s["name"], "sessions": 0, "totalSeconds": 0,
            "firstSeen": s["connectedAt"], "lastSeen": None, "online": False,
        })
        r["name"] = s["name"]  # latest name wins
        r["sessions"] += 1
        r["totalSeconds"] += max(0, int((end - start).total_seconds()))
        r["firstSeen"] = min(r["firstSeen"], s["connectedAt"])
        seen = s["disconnectedAt"] or iso(now)
        r["lastSeen"] = max(r["lastSeen"] or seen, seen)
        if s["disconnectedAt"] is None:
            r["online"] = True
    deaths, kills = {}, {}
    has_killfeed = False
    for e in EVENTS.snapshot():
        if e["type"] == "death":
            deaths[e["player"]] = deaths.get(e["player"], 0) + 1
        elif e["type"] == "kill":
            has_killfeed = True
            if e.get("killerIsPlayer") and e.get("kind") == "man" and e.get("killer"):
                kills[e["killer"]] = kills.get(e["killer"], 0) + 1
    for r in roster.values():
        r["deaths"] = deaths.get(r["name"], 0)
        if has_killfeed:
            r["kills"] = kills.get(r["name"], 0)
    # Cross-check "online" against the live A2S roster when available.
    a2s = cached_a2s()
    if a2s.get("ok"):
        live = {p["name"] for p in a2s["roster"]}
        for r in roster.values():
            r["online"] = r["name"] in live
    players = sorted(roster.values(), key=lambda r: (-r["online"], -r["totalSeconds"]))
    earliest = min((s["connectedAt"] for s in sessions), default=None)
    return {"trackingSince": earliest, "generatedAt": iso(now), "players": players}


def build_events(limit):
    events = EVENTS.snapshot()
    return {
        "trackingSince": events[-1]["t"] if events else None,
        "generatedAt": iso(now_utc()),
        "events": events[:limit],
    }


def build_history(hours, bucket_minutes):
    now = now_utc()
    start_ts = now.timestamp() - hours * 3600
    step = bucket_minutes * 60
    spans = []
    for s in SESSIONS.snapshot():
        a = datetime.fromisoformat(s["connectedAt"].replace("Z", "+00:00")).timestamp()
        b = (datetime.fromisoformat(s["disconnectedAt"].replace("Z", "+00:00")).timestamp()
             if s["disconnectedAt"] else now.timestamp())
        spans.append((a, b, s["uid"]))
    points = []
    t = start_ts - (start_ts % step)
    while t <= now.timestamp():
        b_end = t + step
        # peak = players overlapping this bucket at any moment
        count = len({uid for a, b, uid in spans if a < b_end and b > t})
        points.append({"t": iso(datetime.fromtimestamp(t, timezone.utc)), "players": count})
        t += step
    earliest = min((a for a, _, _ in spans), default=None)
    return {
        "hours": hours, "bucketMinutes": bucket_minutes,
        "trackingSince": iso(datetime.fromtimestamp(earliest, timezone.utc)) if earliest else None,
        "points": points,
    }


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _send(self, code, obj, cache="no-store"):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization, x-api-key")
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", cache)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self._send(204, {})

    def _authorized(self):
        if not API_KEY:
            return True
        key = self.headers.get("x-api-key", "")
        auth = self.headers.get("Authorization", "")
        if not key and auth.lower().startswith("bearer "):
            key = auth[7:].strip()
        return key == API_KEY

    def do_GET(self):
        url = urlparse(self.path)
        path = url.path.rstrip("/") or "/"
        q = parse_qs(url.query)
        if path in ("/", "/health"):
            return self._send(200, {"status": "ok", "logFollower": LOG.follower_ok})
        if not self._authorized():
            return self._send(401, {"error": "Unauthorized"})
        try:
            if path in ("/api/telemetry", "/api/server"):
                return self._send(200, build_telemetry())
            if path == "/api/players":
                return self._send(200, build_players())
            if path == "/api/events":
                limit = max(1, min(500, int(q.get("limit", ["100"])[0])))
                return self._send(200, build_events(limit))
            if path == "/api/history":
                hours = max(1, min(24 * 30, int(q.get("hours", ["24"])[0])))
                bucket = max(1, min(240, int(q.get("bucket", ["15"])[0])))
                return self._send(200, build_history(hours, bucket))
        except Exception as e:
            return self._send(500, {"error": str(e)})
        return self._send(404, {"error": "Not Found"})


def main():
    threading.Thread(target=follow_logs_forever, daemon=True).start()
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Telemetry bridge on http://{HOST}:{PORT} (A2S {A2S_HOST}:{A2S_PORT}, container {CONTAINER})", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
