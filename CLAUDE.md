# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Docker setup for a 32-player Arma 3 dedicated server running Antistasi Ultimate + RHS on Altis, with 2 headless clients. The host is ARM64 (aarch64); the x86_64 Arma binary runs under **Box64** inside a `ghcr.io/sonroyaalmerol/steamcmd-arm64` base image. The in-container orchestration (`container_src/`) is a modified fork of [BrettMayson/Arma3Server](https://github.com/BrettMayson/Arma3Server). See README.md for the operator manual (ports, Steam Guard, client mod sync, admin login).

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
5. On aarch64, prefixes the binary with `$ARMA_BOX64` (the patched Box64, see Gotchas).
6. Renders `configs/$ARMA_CONFIG` to `/tmp/arma3.cfg`, replacing `${ARMA_PASSWORD}`, `${ARMA_PASSWORD_ADMIN}` and `${ARMA_PASSWORD_COMMAND}` with env values (and appending `headlessClients[]`/`localClient[]` if HCs are enabled). The server always uses `/tmp/arma3.cfg`, not the mounted file. If `HEADLESS_CLIENTS > 0`, launches each HC as a background `Popen` connecting to `127.0.0.1` with the `password` parsed from the rendered config by regex.
7. Runs the server with `os.system` (blocks), profiles at `/arma3/configs/profiles`.

**Configuration split:**
- `.env` (from `.env.example`; keep both in sync when adding vars) — Steam creds and launch env vars. Defaults also live as `ENV` in the `Dockerfile`. `HEADLESS_CLIENTS_PROFILE` uses `$$` escaping because Compose interpolates `.env`.
- `configs/main.cfg` — server.cfg (hostname, passwords, mission cycle with Antistasi `autoLoadLastGame`); `configs/basic.cfg` — network tuning, passed via `-cfg=` in `ARMA_PARAMS`.
- `configs/preset.html` — the single source of truth for the server modset; also handed to players for Launcher import. Adding/removing a mod means editing this file.

**Volumes:** `server_base` is an **external** volume (`armaa_server_base`) — it must exist before `docker compose up` (`docker volume create armaa_server_base`). Workshop content, DLC dirs, SteamCMD and Steam credentials are separate named volumes. `configs/`, `missions/`, `mods/`, `servermods/` are bind mounts; campaign saves land in `configs/profiles/` (gitignored).

## Gotchas

- `container_src/*.py` are `COPY`'d into the image: changes need a rebuild (`manage.sh start` rebuilds; `restart` does not).
- `network_mode: host`, `restart: "no"` — the container does not come back after reboot or crash on its own.
- **Patched Box64 is required.** Arma uses `makecontext`/`swapcontext` fibers; upstream Box64's `my_makecontext` truncates fiber args to 32 bits, segfaulting the server right after `Ref to nonnetwork object R Petros` at mission init. The Dockerfile's `box64-build` stage builds a pinned Box64 commit with `container_src/box64-makecontext-64bit.patch` (generic `-DARM64=ON`; Debian 13 GCC rejects `-mcpu=gb10`) and installs it as `/usr/local/bin/box64-arma` (`ARMA_BOX64`). SteamCMD still uses the base image's `box64` wrapper. `BOX64_SHOWSEGV=1` in `.env` prints register dumps on crashes.
- Each HC needs its own `-profiles` dir (`configs/profiles/<hc-name>`); with a shared one all HCs get the same identity and the server drops all but the last.
- `setup_binfmt.sh` registers QEMU amd64 emulation, but the image itself is arm64 and uses Box64; the binfmt step is a pre-flight check, not how Arma actually runs.
- `.env` (gitignored) holds the Steam credentials and server passwords — don't echo them into output. Keep `configs/main.cfg` free of real secrets; use the `${ARMA_PASSWORD*}` placeholders. Passwords in `.env` are single-quoted so Compose doesn't interpolate `$`.
