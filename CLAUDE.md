# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Docker setup for a 32-player Arma 3 dedicated server running Antistasi Ultimate + RHS + ACE (42-mod set) on Altis, with 3 headless clients. The host is ARM64 (aarch64, DGX Spark); everything x86 (launch.py itself, SteamCMD, the server, the HCs) runs under **FEX-Emu** in an `ubuntu:24.04` arm64 image with an x86_64 Debian RootFS at `/opt/x86-rootfs`. The in-container orchestration (`container_src/`) is a modified fork of [BrettMayson/Arma3Server](https://github.com/BrettMayson/Arma3Server). See README.md for the operator manual (ports, Steam Guard, client mod sync, admin login).

## Commands

All operations go through `./scripts/manage.sh`:

- `start` — pre-flight (`.env` exists, `setup_binfmt.sh` on non-x86 hosts) then `docker compose up -d --build`
- `stop` / `restart` / `status` / `logs` / `hc` / `fps`
- `steam-login [code]` — one-time Steam Guard auth via `docker compose run`; session persists in the `steam_data`/`steam_root` volumes
- `backup` / `restore [archive]` — tar `configs/profiles/` to `backups/` (keeps newest 14); restore takes a `pre_restore_safety_*` snapshot first

There are no tests or linters. Useful sanity checks after edits:

```bash
python3 -m py_compile container_src/*.py
bash -n scripts/*.sh
docker compose config >/dev/null
```

## Architecture

**Startup flow** (`container_src/launch.py`, the container CMD — runs top-to-bottom as a script, no `main()`):
1. Prepares `/arma3/keys` (wiped if `CLEAR_KEYS=true`).
2. Installs the server (AppID 233780) via SteamCMD **only if the `ARMA_BINARY` file is missing** — there is no auto-update; existing installs are never re-validated. Exits non-zero on SteamCMD failure to avoid hammering Steam login.
3. `workshop.preset()` parses Workshop IDs out of `MODS_PRESET` (`configs/preset.html`, regex on `filedetails/?id=`), downloads only mods whose directory is missing/empty in a single SteamCMD session, then lowercases every file/dir in each mod (Linux case sensitivity) and copies `.bikey` files into `/arma3/keys` (`keys.py`). Already-present mods are never updated.
4. `local.mods()` does the same lowercase + key copy for `mods/` and `servermods/` (bind mounts).
5. Renders `configs/$ARMA_CONFIG` to `/tmp/arma3.cfg`, replacing `${ARMA_PASSWORD}`, `${ARMA_PASSWORD_ADMIN}` and `${ARMA_PASSWORD_COMMAND}` with env values (and appending `headlessClients[]`/`localClient[]` if HCs are enabled). The server always uses `/tmp/arma3.cfg`, not the mounted file. If `HEADLESS_CLIENTS > 0`, launches each HC as a background `Popen` connecting to `127.0.0.1` with the `password` parsed from the rendered config by regex.
6. Runs the server with `os.system` (blocks), profiles at `/arma3/configs/profiles`.

**Configuration split:**
- `.env` (from `.env.example`; keep both in sync when adding vars) — Steam creds and launch env vars. Defaults also live as `ENV` in the `Dockerfile`. `HEADLESS_CLIENTS_PROFILE` uses `$$` escaping because Compose interpolates `.env`.
- `configs/main.cfg` — server.cfg (hostname, passwords, mission cycle with Antistasi `autoLoadLastGame`); `configs/basic.cfg` — network tuning, passed via `-cfg=` in `ARMA_PARAMS`.
- `configs/preset.html` — the single source of truth for the server modset; also handed to players for Launcher import. Adding/removing a mod means editing this file.

**Volumes:** `server_base` is an **external** volume (`armaa_server_base`) — it must exist before `docker compose up` (`docker volume create armaa_server_base`). Workshop content, DLC dirs, SteamCMD and Steam credentials are separate named volumes. `configs/`, `missions/`, `mods/`, `servermods/` are bind mounts; campaign saves land in `configs/profiles/` (gitignored).

## Gotchas

- `container_src/*.py` are `COPY`'d into the image: changes need a rebuild (`manage.sh start` rebuilds; `restart` does not).
- `network_mode: host`, `restart: "no"` — the container does not come back after reboot or crash on its own.
- **FEX, not Box64.** Box64 replaces glibc's `makecontext`/`swapcontext` with a partial emulation; Arma's script fibers first segfaulted on it (32-bit arg truncation) and then deadlocked `rvMain` when Antistasi starts a new campaign. FEX runs the real x86 glibc. The container CMD is `FEX /usr/bin/python3 /launch.py`; children inherit FEX through execve. Run any other x86 command explicitly via `FEX` (e.g. `FEX /bin/bash -c ...`), since the host's QEMU binfmt would otherwise catch it. The FEX package names the interpreter `FEX` (no `FEXInterpreter`).
- **RootFS path resolution:** FEX looks up guest paths in `FEX_ROOTFS` first and falls back to the container, so the Dockerfile deletes `/etc/resolv.conf`, `/etc/hosts`, `/etc/hostname`, `/root`, `/tmp`, `/home` and `/steamcmd` from the RootFS. Anything that must come from a volume or Docker has to be absent there.
- **Building needs amd64 emulation** for the `x86-rootfs` stage; `setup_binfmt.sh` (run by `manage.sh start`) registers QEMU for that. QEMU is not used at runtime.
- **Steam Guard:** `manage.sh steam-login <code>` caches a session in the `steam_data` volume (`/root/Steam/config/config.vdf`, `ConnectCache`). `workshop.run_steamcmd()` (used for the server install and Workshop downloads) logs in with the username only so it reuses that session, and falls back to the password only if none is cached. Never pass the password when a session exists: a password login starts a fresh Steam Guard challenge and wipes the cached session. The image deliberately has no `/etc/machine-id`, so the session survives rebuilds. SteamCMD only logs in when something is missing, so ordinary restarts never touch Steam.
- **CPU pinning:** the DGX Spark mixes 10 Cortex-X925 performance cores (CPUs 5-9, 15-19) with 10 slower A725 efficiency cores; `docker-compose.yml` pins the container to the X925s (`cpuset`) because each Arma process is bound by its single main thread. Server health shows in Antistasi's `logPerformance` lines (`ServerFPS=`, every 30 s once a campaign is loaded).
- **Server browser mod list:** `steamProtocolMaxDataSize = 4096` in `main.cfg` is required. At the default of 1024, the 42-mod list overflows the Steam query reply and the browser shows no mods.
- Each HC needs its own `-profiles` dir (`configs/profiles/<hc-name>`); with a shared one all HCs get the same identity and the server drops all but the last.
- `.env` (gitignored) holds the Steam credentials and server passwords — don't echo them into output. Keep `configs/main.cfg` free of real secrets; use the `${ARMA_PASSWORD*}` placeholders. Passwords in `.env` are single-quoted so Compose doesn't interpolate `$`.
