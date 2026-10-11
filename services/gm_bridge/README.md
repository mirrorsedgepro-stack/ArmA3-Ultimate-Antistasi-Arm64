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
| `AIRDROP` | `AMMO`/`MEDICAL`/`LAUNCHER`/`SUPPORT`, player | parachuted crate 60-120 m from the player, green smoke on landing; `AMMO` holds the player's own magazine types; removed after 30 min once nobody is near |
| `MORTAR` | player, rounds 1-6 | friendly 82 mm rounds on enemies 200-800 m from the player; never within 200 m of any player |
| `WEATHER` | overcast, rain, fog (≤ 0.5) | immediate weather change |
| `QRF` | player, size 2-8 | occupant infantry (a militia squad from `A3A_faction_occ`, via `A3A_fnc_createUnit`) 500-700 m out, search-and-destroy on the player; cleaned up when dead or after 30 min with no player near |
| `STATUS` | – | `name@grid:enemiesWithin800m;…` |
| `INTEL` | player | readable report: grid, nearest town, enemies within 800 m (closest bearing/distance), 3 nearest enemy zones, active Antistasi missions (`A3A_tasksData`) |
| `AIRSTRIKE` | grid (4-10 digits), player | friendly jet flyby and four 500 lb bombs around the grid; refused within 200 m of any player |
| `MARK` | id, grid, NATO type (`o_inf`, `o_motor_inf`, `o_mech_inf`, `o_armor`, `o_air`, `o_naval`, `o_art`, `o_recon`, `o_installation`, `o_unknown`), text, reporter | battle net: a contact marker (`HH:MM text`, ColorOPFOR) on the map of the reporter's side only (local markers via JIP `remoteExec`); the same id again replaces it. Faded after 10 min, removed after 15, at most 25 (oldest go) |
| `UNMARK` | id | removes a contact marker |
| `FIREMISSION` | grid (6-10 digits), rounds 1-8 | friendly 82 mm rounds on the grid; refused within 200 m of a player or 150 m of the rebel HQ or rebel fighters |
| `ILLUM` | grid or `""`, player | four illumination rounds over the grid (or the player), one every 35 s |
| `SMOKE` | grid or `""`, player | 80 m smoke screen for about two minutes at the grid, or 40 m from the player towards the nearest enemy |
| `MEDEVAC` | id, player, `revive`/`extract`/`auto` | dustoff helicopter: treats the wounded at the LZ, or lifts the casualty to HQ |
| `BACKUP` | id, player, `air`/`road`/`""` | rebel squad by helicopter or by road, with the player for 15 min |
| `UAV` | id, player | unarmed UAV over the player for 15 min; what it sees is logged as `A3GM\|uavspot` |
| `TRANSPORT` | id, player, grid or `HQ` | helicopter pickup to the grid or the rebel HQ |
| `GUNSHIP` | id, player | armed helicopter orbiting the player for 10 min, weapons free |
| `MAFIA` | `status` / `relocate` / `racket` / `reveal` / `hit` / `funds` / `playable`, argument | the Mafia Syndicate (`servermods/@a3ue_mafia`, built from `~/Antistasi-Ultimate-Extender`): status report, new hideout, racket in a town (or `""` for a random one), hideout on the map, hit squad on a player, add funds, let players join (`on`/`off`). Fails with `the Mafia extender isn't loaded` without the mod. `INTEL` also reports what the rebels know of it |
| `CANCEL` | id | recalls that support asset (anyone aboard is put down first); `nothing to cancel` once it's gone |
| `MISSION` | type (`AS`/`CON`/`DES`/`LOG`/`SUPP`/`RES`/`CONVOY`/`RAN`), player | starts an Antistasi mission via `A3A_fnc_missionRequest` (as Petros does) and returns the new task, or why not |

Support assets log their progress as `A3GM|<asset>|<id>|<stage>|<player>|<detail>` (stages such as `launched`,
`landing`, `wheelsup`, `arrived`, `onstation`, `rtb`, `failed`, `lost`, `cancelled`). A player name of `@<grid>`
makes a stand-in there, so they can be flown on an empty server (`scripts/test_support_flights.sh`);
`@<grid>+15` boards 15 s after the helicopter is down. Air strikes, mortars and fire missions are refused danger
close: within 200 m of a player or 150 m of the rebel HQ or rebel fighters.

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
