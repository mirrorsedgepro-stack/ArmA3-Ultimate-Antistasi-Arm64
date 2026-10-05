#!/usr/bin/env python3
"""
Arma 3 Dedicated Server Telemetry Bridge
Exposes real-time A2S query data, server FPS, Antistasi metrics, and HC status
over HTTP for the ArmA3-Monitor Vercel frontend.
"""

import os
import sys
import time
import json
import re
import socket
import struct
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

HOST = os.environ.get("TELEMETRY_HOST", "0.0.0.0")
PORT = int(os.environ.get("TELEMETRY_PORT", "2310"))
A2S_HOST = os.environ.get("A2S_HOST", "127.0.0.1")
A2S_PORT = int(os.environ.get("A2S_PORT", "2303"))
GAME_PORT = int(os.environ.get("PORT", "2302"))
API_KEY = os.environ.get("TELEMETRY_API_KEY", "").strip()
DOCKER_SOCKET = os.environ.get("DOCKER_SOCKET", "/var/run/docker.sock")
CONTAINER_NAME = os.environ.get("ARMA_CONTAINER_NAME", "arma3_antistasi")
EXPECTED_HCS = int(os.environ.get("HEADLESS_CLIENTS", "3"))

CACHE_TTL_SEC = 2.0
_cache = {
    "timestamp": 0.0,
    "data": None
}


def read_cstring(data: bytes, offset: int):
    end = data.find(b"\x00", offset)
    if end == -1:
        return data[offset:].decode("utf-8", errors="replace"), len(data)
    return data[offset:end].decode("utf-8", errors="replace"), end + 1


def query_a2s():
    """Queries Valve A2S_INFO and A2S_PLAYER via UDP."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(2.0)
    start_time = time.perf_counter()

    info = {}
    players_raw = []

    try:
        # 1. A2S_INFO
        info_req = b"\xff\xff\xff\xff\x54Source Engine Query\x00"
        sock.sendto(info_req, (A2S_HOST, A2S_PORT))
        res, _ = sock.recvfrom(4096)
        ping_ms = round((time.perf_counter() - start_time) * 1000)

        # Handle challenge response (0x41)
        if res.startswith(b"\xff\xff\xff\xff\x41"):
            challenge = res[5:9]
            sock.sendto(info_req + challenge, (A2S_HOST, A2S_PORT))
            res, _ = sock.recvfrom(4096)

        if not res.startswith(b"\xff\xff\xff\xff\x49"):
            raise ValueError(f"Invalid A2S_INFO header: {res[:5]!r}")

        idx = 5
        _proto = res[idx]; idx += 1
        name, idx = read_cstring(res, idx)
        map_name, idx = read_cstring(res, idx)
        folder, idx = read_cstring(res, idx)
        game, idx = read_cstring(res, idx)
        _steam_id = struct.unpack("<H", res[idx:idx+2])[0]; idx += 2
        players_count = res[idx]; idx += 1
        max_players = res[idx]; idx += 1
        _bots = res[idx]; idx += 1
        _server_type = chr(res[idx]); idx += 1
        _env = chr(res[idx]); idx += 1
        visibility = res[idx]; idx += 1
        vac = res[idx]; idx += 1
        version, idx = read_cstring(res, idx)

        info = {
            "name": name,
            "map": map_name,
            "mission": game,
            "gameType": folder,
            "version": version,
            "rawPlayers": players_count,
            "maxPlayers": max_players,
            "battleye": bool(vac),
            "passwordProtected": bool(visibility),
            "ping": ping_ms,
        }

        # 2. A2S_PLAYER
        p_req = b"\xff\xff\xff\xff\x55\xff\xff\xff\xff"
        sock.sendto(p_req, (A2S_HOST, A2S_PORT))
        p_res, _ = sock.recvfrom(4096)

        if p_res.startswith(b"\xff\xff\xff\xff\x41"):
            p_chal = p_res[5:9]
            sock.sendto(b"\xff\xff\xff\xff\x55" + p_chal, (A2S_HOST, A2S_PORT))
            p_res, _ = sock.recvfrom(4096)

        if p_res.startswith(b"\xff\xff\xff\xff\x44"):
            num_players = p_res[5]
            p_idx = 6
            for p_num in range(num_players):
                if p_idx >= len(p_res):
                    break
                _slot = p_res[p_idx]; p_idx += 1
                p_name, p_idx = read_cstring(p_res, p_idx)
                if p_idx + 8 > len(p_res):
                    break
                p_score = struct.unpack("<i", p_res[p_idx:p_idx+4])[0]; p_idx += 4
                p_dur = struct.unpack("<f", p_res[p_idx:p_idx+4])[0]; p_idx += 4
                players_raw.append({
                    "id": p_num + 1,
                    "name": p_name,
                    "score": p_score,
                    "timePlayedSeconds": int(p_dur),
                })

        return True, info, players_raw
    except Exception as e:
        return False, {"error": str(e)}, []
    finally:
        sock.close()


def query_docker_stats():
    """Queries Docker socket for container uptime and log telemetry."""
    if not os.path.exists(DOCKER_SOCKET):
        return None, None, None

    uptime_str = None
    fps = None
    antistasi_metrics = None

    try:
        # Container info for uptime
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(1.5)
        s.connect(DOCKER_SOCKET)
        req = f"GET /containers/{CONTAINER_NAME}/json HTTP/1.1\r\nHost: localhost\r\n\r\n"
        s.sendall(req.encode())
        res = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            res += chunk
            if b"\r\n\r\n" in res and (b"}\r\n" in res or res.endswith(b"}")):
                break
        s.close()

        body_idx = res.find(b"\r\n\r\n")
        if body_idx != -1:
            raw_json = res[body_idx+4:].decode("utf-8", errors="ignore")
            # Handle chunked transfer if present
            if "\r\n" in raw_json and not raw_json.strip().startswith("{"):
                parts = raw_json.split("\r\n", 1)
                if len(parts) > 1:
                    raw_json = parts[1]
            try:
                cdata = json.loads(raw_json)
                started_at = cdata.get("State", {}).get("StartedAt")
                if started_at:
                    # e.g. 2026-10-05T04:41:27.123456789Z
                    clean_iso = started_at[:19] + "Z"
                    start_dt = datetime.fromisoformat(clean_iso.replace("Z", "+00:00"))
                    diff = datetime.now(timezone.utc) - start_dt
                    total_seconds = int(diff.total_seconds())
                    hours = total_seconds // 3600
                    minutes = (total_seconds % 3600) // 60
                    uptime_str = f"{hours}h {minutes}m"
            except Exception:
                pass
    except Exception:
        pass

    # Read latest logs to get Antistasi ServerFPS
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(1.5)
        s.connect(DOCKER_SOCKET)
        # Fetch last 400 lines of logs
        req = f"GET /containers/{CONTAINER_NAME}/logs?stdout=1&stderr=1&tail=400 HTTP/1.1\r\nHost: localhost\r\n\r\n"
        s.sendall(req.encode())
        log_bytes = b""
        while len(log_bytes) < 65536:
            chunk = s.recv(4096)
            if not chunk:
                break
            log_bytes += chunk
        s.close()

        # Extract text ignoring binary frame headers
        clean_text = "".join(
            chr(b) if 32 <= b <= 126 or b == 10 else " " for b in log_bytes
        )

        # Regex for ServerFPS
        fps_matches = re.findall(r"ServerFPS=([\d.]+)", clean_text)
        if fps_matches:
            fps = round(float(fps_matches[-1]), 1)

        # Regex for Antistasi rich performance stats
        # e.g. ServerFPS=62.2568 Players=4 DeadUnits=75 AllUnits=15 ... FactionCash=14552 HR=32 OccAggro=87 InvAggro=0 Warlevel=2 RivalsActivityLevel=5
        last_perf = re.findall(
            r"ServerFPS=([\d.]+)\s+Players=(\d+)\s+DeadUnits=(\d+)\s+AllUnits=(\d+).*?FactionCash=(\d+)\s+HR=(\d+)\s+OccAggro=(\d+)\s+InvAggro=(\d+)\s+Warlevel=(\d+)",
            clean_text,
        )
        if last_perf:
            m = last_perf[-1]
            antistasi_metrics = {
                "serverFps": round(float(m[0]), 1),
                "players": int(m[1]),
                "deadUnits": int(m[2]),
                "allUnits": int(m[3]),
                "factionCash": int(m[4]),
                "hr": int(m[5]),
                "occAggro": int(m[6]),
                "invAggro": int(m[7]),
                "warLevel": int(m[8]),
            }
    except Exception:
        pass

    return uptime_str, fps, antistasi_metrics


def is_headless_client(name: str) -> bool:
    if not name:
        return False
    n = name.lower()
    return bool(re.search(r"(antistasi_server-)?hc(-\d+)?", n) or "headless" in n)


def get_full_telemetry():
    now = time.time()
    if _cache["data"] and (now - _cache["timestamp"] < CACHE_TTL_SEC):
        return _cache["data"]

    success, a2s_data, raw_players = query_a2s()
    uptime_str, log_fps, antistasi_stats = query_docker_stats()

    # Filter out Headless Clients from human player list
    human_players = []
    active_hcs = []
    for p in raw_players:
        if is_headless_client(p.get("name", "")):
            active_hcs.append(p.get("name", ""))
        else:
            human_players.append(p)

    # Calculate real human players count
    human_player_count = len(human_players)

    status = "online" if success else "offline"
    server_fps = log_fps if log_fps is not None else 50.0

    telemetry = {
        "name": a2s_data.get("name", "Frenchy's Antistasi Ultimate [RHS] | 32-Player Dedicated"),
        "ip": os.environ.get("SERVER_PUBLIC_IP", "180.181.238.103"),
        "port": GAME_PORT,
        "queryPort": A2S_PORT,
        "status": status,
        "ping": a2s_data.get("ping", 15),
        "players": human_player_count,
        "maxPlayers": a2s_data.get("maxPlayers", 32),
        "playerList": human_players,
        "map": a2s_data.get("map", "Altis"),
        "mission": a2s_data.get("mission", "Antistasi Ultimate - Altis"),
        "gameType": a2s_data.get("gameType", "Antistasi Ultimate"),
        "version": a2s_data.get("version", "2.22.154089"),
        "battleye": a2s_data.get("battleye", True),
        "passwordProtected": a2s_data.get("passwordProtected", False),
        "difficulty": "Custom",
        "timeOfDay": "Dynamic (In-Game)",
        "uptime": uptime_str or "Active",
        "querySource": "direct_a2s",
        "lastUpdated": datetime.now(timezone.utc).isoformat(),
        "discordUrl": "https://discord.gg/arma3",
        "platform": "Linux Dedicated Server (ARM64 / FEX x86_64)",
        "serverFps": server_fps,
        "headlessClients": {
            "total": EXPECTED_HCS,
            "active": len(active_hcs),
            "names": active_hcs,
        },
        "antistasi": antistasi_stats,
    }

    _cache["timestamp"] = now
    _cache["data"] = telemetry
    return telemetry


class TelemetryHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Keep stdout clean; only log errors or when debugging
        if sys.stderr.isatty():
            super().log_message(format, *args)

    def send_cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization, x-api-key")

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_cors_headers()
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        # Healthcheck
        if path in ("", "/health"):
            self.send_response(200)
            self.send_cors_headers()
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"status": "ok", "service": "arma3-telemetry-bridge"}).encode("utf-8"))
            return

        # Main telemetry endpoint
        if path in ("/api/telemetry", "/telemetry", "/api/server"):
            # Check optional API Key
            if API_KEY:
                req_key = self.headers.get("x-api-key", "")
                if not req_key and "Authorization" in self.headers:
                    auth = self.headers.get("Authorization", "")
                    if auth.lower().startswith("bearer "):
                        req_key = auth[7:].strip()

                if req_key != API_KEY:
                    self.send_response(401)
                    self.send_cors_headers()
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    self.wfile.write(json.dumps({"error": "Unauthorized: Invalid or missing API key"}).encode("utf-8"))
                    return

            data = get_full_telemetry()
            payload = json.dumps(data, indent=2).encode("utf-8")

            self.send_response(200)
            self.send_cors_headers()
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "public, s-maxage=2, stale-while-revalidate=5")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        self.send_response(404)
        self.send_cors_headers()
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"error": "Not Found"}).encode("utf-8"))


def main():
    server_address = (HOST, PORT)
    httpd = HTTPServer(server_address, TelemetryHandler)
    print(f"Arma 3 Telemetry Bridge running on http://{HOST}:{PORT}")
    print(f"Monitoring A2S at {A2S_HOST}:{A2S_PORT} and Docker {CONTAINER_NAME}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down Telemetry Bridge...")
        httpd.server_close()


if __name__ == "__main__":
    main()
