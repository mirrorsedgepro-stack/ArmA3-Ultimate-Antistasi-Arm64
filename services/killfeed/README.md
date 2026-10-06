# Kill feed and live map (A3KF)

The `@a3kf` server addon has two parts: the kill feed below, and a map feed
(`functions/fn_map.sqf`) for the website's live map.

## Map feed

On mission start it samples the terrain height on a 512×512 grid and logs it once (about 1,000
short lines), then the world's named places. After Antistasi's `serverInitDone` it logs each
zone's owner (from `sidesX`), the rebel HQ, and a player-position snapshot every 15 s (every 60 s
while the server is empty). The bridge serves this as `/api/map` and `/api/map/terrain`; the
terrain is also saved to `/data/map_terrain_<world>.json`.

`functions/fn_mapDetail.sqf` also exports, once per mission start, the ground type (1024 grid),
tree density (256 grid), every road segment (`getRoadInfo`) and building footprint. The bridge
draws these into Arma-style map tiles (`services/telemetry_bridge/tiles.py`, zoom 0-6, about
2,000 land tiles / 90 MB in `/data/tiles/<version>`), only when the export or the drawing code
changes. Bump the `render-N` salt in `server.py` after changing `tiles.py`.

Privacy, in `.env` (restart only the bridge to apply):

- `MAP_POSITION_DELAY`: seconds to delay player positions on the site (0 = live).
- `MAP_SHOW_HQ`: `false` hides the rebel HQ marker.

## Kill feed

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

The snippet contains both the kill feed and the map feed.


1. Join, open chat and `#login <admin password>`.
2. Press **Y** for Zeus (the mission gives Zeus to the logged-in admin).
3. Place **Zeus Enhanced → Execute Code** (or open it from the ZEN module list).
4. Paste the contents of `zeus_snippet.sqf`, set the target to **Server**, and execute.

The server log then shows `A3KF|installed`, and `/api/telemetry` reports `killFeed.installedAt`.
Running it again just replaces the handler. It lasts until the mission restarts; after that the
addon in `servermods/@a3kf` takes over.

The mission's debug console is restricted to the Antistasi developers' Steam IDs, so it can't be
used for this; logged-in admins can always use ZEN's Execute Code.
