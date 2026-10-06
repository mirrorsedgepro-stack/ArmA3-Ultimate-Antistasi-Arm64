# Kill feed (A3KF)

A server-side `EntityKilled` hook that writes one line per kill to the server log:

```
A3KF|1|kind|victim|victimSide|victimIsPlayer|killer|killerSide|killerIsPlayer|weapon|distance
```

The telemetry bridge (`services/telemetry_bridge/server.py`) turns these into `kill` events
(`/api/events`) and per-player kill counts (`/api/players`). Clients need nothing.

- `kind` is `man`, or `veh` for vehicles destroyed by a player.
- Killer fields are empty when nobody else caused the death (falls, drowning, own grenade).
- Sides: `GUER` rebels, `WEST` occupants, `EAST` invaders, `CIV` civilians.

## Build

```bash
python3 services/killfeed/build.py
```

Writes `servermods/@a3kf/addons/a3kf.pbo` (loaded automatically at the next server start, like
every `@` folder in `servermods/`) and `services/killfeed/zeus_snippet.sqf`.

## Enable on a running server (no restart)

1. Join, open chat and `#login <admin password>`.
2. Press **Y** for Zeus (the mission gives Zeus to the logged-in admin).
3. Place **Zeus Enhanced → Execute Code** (or open it from the ZEN module list).
4. Paste the contents of `zeus_snippet.sqf`, set the target to **Server**, and execute.

The server log then shows `A3KF|installed`, and `/api/telemetry` reports `killFeed.installedAt`.
Running it again just replaces the handler. It lasts until the mission restarts; after that the
addon in `servermods/@a3kf` takes over.

The mission's debug console is restricted to the Antistasi developers' Steam IDs, so it can't be
used for this; logged-in admins can always use ZEN's Execute Code.
