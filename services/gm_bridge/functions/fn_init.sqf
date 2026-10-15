// A3GM: runs whitelisted OpenClaw Game Master actions on the server.
// The Game Master writes ["id","ACTION",[args]] to gm_spool/inbox; the a3gm extension hands
// the files over oldest first. Nothing in a command is ever compiled or executed as code.
// Each command logs exactly one result line for the Game Master:
//   A3GM|done|id|ACTION|ok|detail      A3GM|done|id|ACTION|fail|reason
if (!isServer) exitWith {};

if (("a3gm" callExtension "version") isEqualTo "") exitWith {
    diag_log text "A3GM|error|a3gm_x64.so not loaded";
};

A3GM_fnc_clean = { (_this splitString "|") joinString "/" };

A3GM_fnc_players = {
    (allPlayers - entities "HeadlessClient_F") select { alive _x }
};

A3GM_fnc_hostileSides = {
    if (isNil "Occupants") then { [west, east] } else { [Occupants, Invaders] }
};

// Named player, else the player with the most enemies within 800 m.
A3GM_fnc_target = {
    params [["_name", "", [""]]];
    private _players = call A3GM_fnc_players;
    if (_players isEqualTo []) exitWith { objNull };
    private _named = _players findIf { name _x == _name };
    if (_name != "" && {_named >= 0}) exitWith { _players select _named };
    private _hostile = call A3GM_fnc_hostileSides;
    private _best = _players select 0;
    private _bestCount = -1;
    {
        private _n = count ((_x nearEntities ["CAManBase", 800]) select { alive _x && {side group _x in _hostile} });
        if (_n > _bestCount) then { _best = _x; _bestCount = _n };
    } forEach _players;
    _best
};

// args: [text]
A3GM_fnc_say = {
    params [["_text", "", [""]]];
    if (_text isEqualTo "") exitWith { [false, "empty text"] };
    // Side channel as "HQ", for each player's own side (sideChat is local, so per client).
    private _line = format ["OVERLORD: %1", _text select [0, 400]];
    { [[side group _x, "HQ"], _line] remoteExecCall ["sideChat", owner _x] } forEach (call A3GM_fnc_players);
    [true, "sent"]
};

// args: [kind (AMMO|MEDICAL|LAUNCHER|SUPPORT), player name or ""]
A3GM_fnc_airdrop = {
    params [["_kind", "AMMO", [""]], ["_name", "", [""]]];
    private _target = [_name] call A3GM_fnc_target;
    if (isNull _target) exitWith { [false, "no player to drop to"] };
    private _class = switch (toUpper _kind) do {
        case "MEDICAL": { "ACE_medicalSupplyCrate_advanced" };
        case "LAUNCHER": { "Box_NATO_WpsLaunch_F" };
        case "SUPPORT": { "Box_NATO_Support_F" };
        default { "Box_NATO_Ammo_F" };
    };
    if (!isClass (configFile >> "CfgVehicles" >> _class)) then { _class = "Box_NATO_Ammo_F" };

    private _pos = _target getPos [60 + random 60, random 360];
    _pos set [2, 200];
    private _chute = createVehicle ["B_Parachute_02_F", _pos, [], 0, "FLY"];
    _chute setPosATL _pos;
    private _box = createVehicle [_class, _pos, [], 0, "CAN_COLLIDE"];
    _box attachTo [_chute, [0, 0, -1.3]];
    if (_class == "Box_NATO_Ammo_F") then {
        // what the caller shoots: the NATO crate's own magazines fit none of the modded weapons
        private _mags = [];
        { _mags pushBackUnique _x } forEach (primaryWeaponMagazine _target + handgunMagazine _target
            + secondaryWeaponMagazine _target + magazines _target);
        _mags = _mags select [0, 10];
        if (_mags isNotEqualTo []) then {
            clearMagazineCargoGlobal _box;
            { _box addMagazineCargoGlobal [_x, [6, 12] select (_forEachIndex == 0)] } forEach _mags;
        };
    };
    [_box, _chute] spawn {
        params ["_box", "_chute"];
        private _timeout = time + 180;
        waitUntil { sleep 1; isNull _chute || {((getPosATL _box) select 2) < 3} || {time > _timeout} };
        detach _box;
        private _p = getPosATL _box;
        _p set [2, 0];
        _box setPosATL _p;
        createVehicle ["SmokeShellGreen", _p, [], 0, "CAN_COLLIDE"];
        if (!isNull _chute) then { deleteVehicle _chute };
        sleep 1800;  // then removed once nobody is near it
        waitUntil { sleep 30; ((call A3GM_fnc_players) findIf { _x distance2D _box < 300 }) < 0 };
        deleteVehicle _box;
    };
    [true, format ["%1 for %2 near grid %3", _class, name _target, mapGridPosition _pos]]
};

// Who a fire mission would land on: "" if nobody, else e.g. "Frenchy within 200 m". Players, the rebel HQ and
// rebel fighters on foot.
A3GM_fnc_friendliesNear = {
    params ["_pos", ["_players", 200], ["_others", 150]];
    private _near = ((call A3GM_fnc_players) select { _x distance2D _pos < _players }) apply { name _x };
    if (_near isNotEqualTo []) exitWith { format ["%1 within %2 m", _near joinString ", ", _players] };
    private _hq = markerPos "Synd_HQ";
    if (_hq isNotEqualTo [0, 0, 0] && {_hq distance2D _pos < _others}) exitWith { format ["the rebel HQ within %1 m", _others] };
    private _side = missionNamespace getVariable ["teamPlayer", independent];
    if (((_pos nearEntities ["CAManBase", _others]) findIf { alive _x && {side group _x == _side} }) >= 0) exitWith {
        format ["rebel fighters within %1 m", _others] };
    ""
};

// 82 mm rounds around a point, the first after _delay s
A3GM_fnc_shells = {
    _this spawn {
        params ["_aim", "_rounds", ["_spread", 35], ["_delay", 10]];
        sleep _delay;
        for "_i" from 1 to _rounds do {
            private _p = _aim getPos [random _spread, random 360];
            _p set [2, 150];
            private _shell = createVehicle ["Sh_82mm_AMOS", _p, [], 0, "CAN_COLLIDE"];
            _shell setVelocity [0, 0, -80];
            sleep (2 + random 2);
        };
    };
};

// A grid, else where the named player is: a position, or a string saying why not
A3GM_fnc_spot = {
    params ["_grid", "_name"];
    _grid = (_grid splitString " ,.-") joinString "";
    if (_grid != "") exitWith { _grid call A3GM_fnc_gridPos };
    private _target = [_name] call A3GM_fnc_target;
    if (isNull _target) exitWith { "no player" };
    getPosATL _target
};

// FIREMISSION: mortars on a grid the caller names (corrections such as "add 100" are the Game Master's: it
// sends the shifted grid). Refused danger close. args: [grid (6-10 digits), rounds 1-8]
A3GM_fnc_fireMission = {
    params [["_grid", "", [""]], ["_rounds", 4, [0]]];
    _grid = (_grid splitString " ,.-") joinString "";
    _rounds = 1 max (round _rounds min 8);
    private _pos = _grid call A3GM_fnc_gridPos;
    if (_pos isEqualType "") exitWith { [false, _pos] };
    private _close = [_pos] call A3GM_fnc_friendliesNear;
    if (_close != "") exitWith { [false, format ["danger close: %1 of grid %2", _close, _grid]] };
    [_pos, _rounds, 30, 15] call A3GM_fnc_shells;
    [true, format ["%1 rounds on grid %2 (%3), splash in about 20 seconds", _rounds, _grid, mapGridPosition _pos]]
};

// ILLUM: four illumination rounds over a grid, or over the player, one every 35 s. args: [grid or "", player name or ""]
A3GM_fnc_illum = {
    params [["_grid", "", [""]], ["_name", "", [""]]];
    private _pos = [_grid, _name] call A3GM_fnc_spot;
    if (_pos isEqualType "") exitWith { [false, _pos] };
    private _class = ["Flare_82mm_AMOS_White", "F_40mm_White"] select { isClass (configFile >> "CfgAmmo" >> _x) } param [0, ""];
    if (_class == "") exitWith { [false, "no illumination rounds"] };
    [_pos, _class] spawn {
        params ["_pos", "_class"];
        sleep 8;
        for "_i" from 1 to 4 do {
            private _p = _pos getPos [random 80, random 360];
            _p set [2, 280];
            private _flare = createVehicle [_class, _p, [], 0, "CAN_COLLIDE"];
            _flare setPosATL _p;
            _flare setVelocity [0, 0, -4];
            sleep 35;
        };
    };
    [true, format ["illumination over grid %1 for about two minutes", mapGridPosition _pos]]
};

// SMOKE: a smoke screen 80 m wide for about two minutes, at a grid, or 40 m from the player towards the nearest
// enemy and across the line to them. args: [grid or "", player name or ""]
A3GM_fnc_smoke = {
    params [["_grid", "", [""]], ["_name", "", [""]]];
    private _pos = [_grid, _name] call A3GM_fnc_spot;
    if (_pos isEqualType "") exitWith { [false, _pos] };
    private _dir = random 360;
    if (((_grid splitString " ,.-") joinString "") == "") then {
        private _hostile = call A3GM_fnc_hostileSides;
        private _enemies = (_pos nearEntities ["CAManBase", 600]) select { alive _x && {side group _x in _hostile} };
        if (_enemies isNotEqualTo []) then {
            private _e = ([_enemies, [_pos], { _input0 distance2D _x }, "ASCEND"] call BIS_fnc_sortBy) select 0;
            _dir = (_pos getDir _e) + 90;
            _pos = _pos getPos [40 min ((_pos distance2D _e) / 2), _pos getDir _e];
        };
    };
    [_pos, _dir] spawn {
        params ["_pos", "_dir"];
        for "_wave" from 1 to 2 do {
            {
                private _p = _pos getPos [_x, _dir];
                _p set [2, 0];
                createVehicle ["SmokeShell", _p, [], 0, "CAN_COLLIDE"];
            } forEach [-40, -20, 0, 20, 40];
            sleep 50;
        };
    };
    [true, format ["smoke screen at grid %1 for about two minutes", mapGridPosition _pos]]
};

// Friendly mortar mission on enemies near a player, never within 200 m of any player (or on the rebel HQ or
// rebel fighters). args: [player name or "", rounds 1-6]
A3GM_fnc_mortar = {
    params [["_name", "", [""]], ["_rounds", 4, [0]]];
    _rounds = 1 max (round _rounds min 6);
    private _target = [_name] call A3GM_fnc_target;
    if (isNull _target) exitWith { [false, "no player"] };
    private _hostile = call A3GM_fnc_hostileSides;
    private _enemies = (_target nearEntities [["CAManBase", "LandVehicle"], 800]) select {
        alive _x && {side group _x in _hostile} && {!isPlayer _x} && {([getPosATL _x, 200, 100] call A3GM_fnc_friendliesNear) == ""}
    };
    if (_enemies isEqualTo []) exitWith { [false, "no enemies 200-800 m from players"] };
    private _aim = getPosATL (selectRandom _enemies);
    [_aim, _rounds] call A3GM_fnc_shells;
    [true, format ["%1 rounds on grid %2 near %3", _rounds, mapGridPosition _aim, name _target]]
};

// Map grid "EEENNN" (4/6/8/10 digits) -> [x, y, 0], or a string saying why not.
A3GM_fnc_gridPos = {
    private _grid = _this;
    if !(count _grid in [4, 6, 8, 10]) exitWith { format ["can't read grid %1", _grid] };
    private _half = count _grid / 2;
    // Altis-style grids count squares from the south-west corner (100 m for 6 digits, 10 m for 8). Checked
    // against the map's own 6-digit grid; BIS_fnc_gridToPos is only a fallback (it returns no usable
    // position for 8/10-digit grids).
    private _scale = 10 ^ (5 - _half);
    private _pos = [(parseNumber (_grid select [0, _half]) + 0.5) * _scale, (parseNumber (_grid select [_half, _half]) + 0.5) * _scale, 0];
    private _n = 3 min _half;
    private _check = mapGridPosition _pos;
    if ((_check select [0, _n]) + (_check select [3, _n]) != (_grid select [0, _n]) + (_grid select [_half, _n])) then {
        _pos = [];
        private _found = [_grid select [0, _n] + (_grid select [_half, _n]), true] call BIS_fnc_gridToPos;
        if (_found isEqualType [] && {count _found > 0} && {(_found select 0) isEqualType []}) then { _pos = _found select 0 };
        if (_pos isNotEqualTo [] && {mapGridPosition _pos != (_grid select [0, _n]) + (_grid select [_half, _n])}) then { _pos = [] };
    };
    if (_pos isEqualTo []) exitWith { format ["can't locate grid %1", _grid] };
    _pos = [_pos select 0, _pos select 1, 0];
    if ((_pos select 0) < 0 || {(_pos select 1) < 0} || {(_pos select 0) > worldSize} || {(_pos select 1) > worldSize}) exitWith {
        format ["grid %1 is off the map", _grid] };
    _pos
};

// Air strike on a map grid the caller names. args: [grid "EEENNN" (4/6/8 digits), player name or ""]
// A friendly jet flies over and four 500 lb bombs land around the grid square's centre. Refused within
// 200 m of any player or 150 m of the rebel HQ or rebel fighters (danger close), or off the map.
A3GM_fnc_airstrike = {
    params [["_grid", "", [""]], ["_name", "", [""]]];
    _grid = (_grid splitString " ,.-") joinString "";
    private _pos = _grid call A3GM_fnc_gridPos;
    if (_pos isEqualType "") exitWith { [false, _pos] };
    private _close = [_pos] call A3GM_fnc_friendliesNear;
    if (_close != "") exitWith { [false, format ["danger close: %1 of grid %2", _close, _grid]] };

    private _caller = [_name] call A3GM_fnc_target;
    private _side = if (isNull _caller) then { missionNamespace getVariable ["teamPlayer", independent] } else { side group _caller };
    private _jet = ["I_Plane_Fighter_03_dynamicLoadout_F", "I_Plane_Fighter_04_F", "B_Plane_CAS_01_dynamicLoadout_F"]
        select { isClass (configFile >> "CfgVehicles" >> _x) } param [0, ""];
    private _dir = random 360;
    if (_jet != "") then {
        private _from = _pos getPos [4000, _dir + 180]; _from set [2, 250];
        private _to = _pos getPos [4000, _dir]; _to set [2, 250];
        [_from, _to, 250, "FULL", _jet, _side] call BIS_fnc_ambientFlyby;
    };
    [_pos] spawn {
        params ["_pos"];
        sleep 22;  // the jet is over the target about now
        for "_i" from 1 to 4 do {
            private _p = _pos getPos [random 45, random 360];
            _p set [2, 120];
            private _bomb = createVehicle ["Bo_GBU12_LGB", _p, [], 0, "CAN_COLLIDE"];
            _bomb setVelocity [0, 0, -90];
            sleep 0.4;
        };
    };
    [true, format ["air strike on grid %1 (%2), impact in about 25 seconds", _grid, mapGridPosition _pos]]
};

// Battle net: contacts reported to Overlord, marked on the map of the reporter's side only. The addon is
// server-only, so each client draws its own local marker (remoteExec to that side, JIP id = marker name:
// late joiners get the current version, re-marking replaces it). Faded after A3GM_markFade s, removed after
// A3GM_markLife s, at most A3GM_markMax at once (oldest go first).
A3GM_marks = createHashMap;  // id -> [marker name, side, created (time), draw args, faded flag once faded]
A3GM_markFade = 600;
A3GM_markLife = 900;
A3GM_markMax = 25;
A3GM_fnc_markDraw = {
    // Runs on the clients. args: [marker name, pos, type, text, alpha]
    params ["_name", "_pos", "_type", "_text", "_alpha"];
    deleteMarkerLocal _name;
    private _m = createMarkerLocal [_name, _pos];
    _m setMarkerTypeLocal _type;
    _m setMarkerColorLocal "ColorOPFOR";
    _m setMarkerTextLocal _text;
    _m setMarkerAlphaLocal _alpha;
};
A3GM_fnc_markSend = {
    params ["_name", "_side", "_args"];
    [_args, A3GM_fnc_markDraw] remoteExec ["spawn", _side, _name];  // "spawn": as the chat hook, allowed by the mission
};
A3GM_fnc_markRemove = {
    params ["_id"];
    private _entry = A3GM_marks getOrDefault [_id, []];
    if (_entry isEqualTo []) exitWith { false };
    private _name = _entry select 0;
    remoteExec ["", _name];  // drop it from the JIP queue
    [[_name], { deleteMarkerLocal (_this select 0) }] remoteExec ["spawn", 0];
    A3GM_marks deleteAt _id;
    true
};

// args: [id, grid (8 digits), NATO type (o_inf, o_armor, ...), text, reporter name or ""]
A3GM_fnc_mark = {
    params [["_id", "", [""]], ["_grid", "", [""]], ["_type", "o_unknown", [""]], ["_text", "", [""]], ["_name", "", [""]]];
    if (_id isEqualTo "" || {(_id regexFind ["[^A-Za-z0-9_]"]) isNotEqualTo []}) exitWith { [false, "bad id"] };
    if !(_type in ["o_inf", "o_motor_inf", "o_mech_inf", "o_armor", "o_air", "o_naval", "o_art", "o_recon",
                   "o_installation", "o_unknown"]) then { _type = "o_unknown" };
    private _pos = _grid call A3GM_fnc_gridPos;
    if (_pos isEqualType "") exitWith { [false, _pos] };
    private _players = call A3GM_fnc_players;
    private _idx = _players findIf { name _x == _name };
    private _side = if (_idx >= 0) then { side group (_players select _idx) } else { missionNamespace getVariable ["teamPlayer", independent] };
    private _marker = format ["A3GM_contact_%1", _id];
    private _label = format ["%1 %2", [daytime, "HH:MM"] call BIS_fnc_timeToString, (_text select [0, 60]) call A3GM_fnc_clean];
    [_id] call A3GM_fnc_markRemove;  // an update: replace it (it may have moved)
    // Over the cap: the oldest goes
    if (count A3GM_marks >= A3GM_markMax) then {
        private _oldest = ""; private _t = 1e10;
        { if ((_y select 2) < _t) then { _t = _y select 2; _oldest = _x } } forEach A3GM_marks;
        if (_oldest != "") then { [_oldest] call A3GM_fnc_markRemove };
    };
    A3GM_marks set [_id, [_marker, _side, time, [_marker, _pos, _type, _label]]];
    [_marker, _side, [_marker, _pos, _type, _label, 1]] call A3GM_fnc_markSend;
    [true, format ["marked %1 at %2 for %3", _id, mapGridPosition _pos, _side call A3GM_fnc_sideName]]
};

// args: [id]
A3GM_fnc_unmark = {
    params [["_id", "", [""]]];
    if ([_id] call A3GM_fnc_markRemove) then { [true, format ["removed %1", _id]] } else { [false, format ["no marker %1", _id]] }
};

// Fade and expire contact markers
[] spawn {
    waitUntil { sleep 5; missionNamespace getVariable ["serverInitDone", false] };
    while { true } do {
        sleep 30;
        {
            _y params ["_name", "_side", "_created", "_draw"];
            private _age = time - _created;
            if (_age > A3GM_markLife) then {
                [_x] call A3GM_fnc_markRemove;
            } else {
                if (_age > A3GM_markFade && {count _y < 5}) then {
                    (A3GM_marks get _x) pushBack true;  // faded once (_y is the copy's)
                    [_name, _side, _draw + [0.45]] call A3GM_fnc_markSend;
                };
            };
        } forEach +A3GM_marks;
    };
};

// MEDEVAC: a friendly helicopter ("dustoff") flies from the rebel HQ to a casualty.
//   revive:  lands near them, the crew medic treats every wounded player within 60 m, then it leaves
//   extract: lands, loads the casualty (unconscious ones are carried aboard), flies them to HQ, unloads, heals
//   auto:    revive if they're hurt, extract if they're fit
// args: [id, player name, mode]. Progress for the Game Master's radio:
//   A3GM|medevac|id|stage|player|detail   stage: launched, landing, landed, healed, aboard, wheelsup, hq, done, failed
A3GM_medevacHelis = ["I_Heli_Transport_02_F", "I_Heli_light_03_unarmed_F", "B_Heli_Transport_01_F", "B_Heli_Light_01_F",
    "O_Heli_Light_02_unarmed_F", "O_Heli_Transport_04_covered_F"];
A3GM_backupHelis = ["I_Heli_Transport_02_F", "B_Heli_Transport_01_F", "O_Heli_Transport_04_covered_F",
    "B_Heli_Transport_03_F", "CUP_I_UH60M_Unarmed_ION", "CUP_B_UH60M_US", "CUP_B_CH47F_USA",
    "CUP_O_Mi8_VVS_Underslung", "CUP_I_Mi17_UN", "I_Heli_light_03_unarmed_F", "O_Heli_Light_02_unarmed_F"];

// The available classes from a list, the given side's own first (I_ independent, B_ west, O_ east)
A3GM_fnc_sideClasses = {
    params ["_classes", "_side"];
    private _prefix = ["I_", "B_", "O_"] select (([independent, west, east] find _side) max 0);
    private _ok = _classes select { isClass (configFile >> "CfgVehicles" >> _x) };
    (_ok select { (_x select [0, 2]) == _prefix }) + (_ok select { (_x select [0, 2]) != _prefix })
};

// The player a support asset is for; "@<grid>" makes a stand-in casualty there (a wounded rebel, removed after
// 20 min) so the flights can be tested on an empty server. "@<grid>+15" boards 15 s after the helicopter is down,
// as a player walking to it would.
A3GM_fnc_supportTarget = {
    params ["_name"];
    private _players = call A3GM_fnc_players;
    private _idx = _players findIf { name _x == _name };
    if (_idx >= 0) exitWith { _players select _idx };
    if ((_name select [0, 1]) != "@") exitWith { objNull };
    private _spec = (_name select [1]) splitString "+";
    private _pos = (_spec param [0, ""]) call A3GM_fnc_gridPos;
    if (_pos isEqualType "") exitWith { objNull };
    private _grp = createGroup [missionNamespace getVariable ["teamPlayer", independent], true];
    private _u = _grp createUnit ["I_G_Soldier_F", _pos, [], 0, "NONE"];
    _u setDamage 0.5;
    _u disableAI "PATH";
    _u setVariable ["A3GM_standin", true];  // boards a landed helicopter by itself (it can't walk to it)
    _u setVariable ["A3GM_standinDelay", parseNumber (_spec param [1, "0"])];
    [_u] spawn { sleep 1200; deleteVehicle (_this select 0) };
    diag_log text format ["A3GM|test|stand-in at %1", mapGridPosition _u];
    _u
};

// Support assets by id, so a caller can cancel ("Overlord, cancel the pickup"): id -> [cancelled, vehicles and
// units]. Cancelling only sets the flag; the asset's own script sees it at its next step and sends it home.
A3GM_supportAssets = createHashMap;
A3GM_fnc_supportRegister = {
    params ["_id", "_assets"];
    { if (((_y select 1) findIf { alive _x }) < 0) then { A3GM_supportAssets deleteAt _x } } forEach +A3GM_supportAssets;
    A3GM_supportAssets set [_id, [false, _assets]];
};
A3GM_fnc_cancelled = { params ["_id"]; (A3GM_supportAssets getOrDefault [_id, [false]]) select 0 };
// args: [id]
A3GM_fnc_cancel = {
    params [["_id", "", [""]]];
    private _entry = A3GM_supportAssets getOrDefault [_id, []];
    if (_entry isEqualTo [] || {_entry select 0} || {((_entry select 1) findIf { alive _x }) < 0}) exitWith {
        [false, "nothing to cancel"] };
    _entry set [0, true];
    { _x setVariable ["A3GM_cancel", true] } forEach (_entry select 1);
    [true, format ["cancelled %1", _id]]
};

// The pilot is dead or out: lost, rather than "could not land"
A3GM_fnc_heliLost = { params ["_heli"]; !alive _heli || {!alive driver _heli} };

A3GM_fnc_medevacLog = {
    params ["_id", "_stage", "_unit", ["_detail", ""]];
    diag_log text format ["A3GM|medevac|%1|%2|%3|%4", _id, _stage, (if (isNull _unit) then {""} else {name _unit}) call A3GM_fnc_clean,
        _detail call A3GM_fnc_clean];
};

// Full heal where the unit is local (ACE when present), waking it if unconscious
A3GM_fnc_medevacHeal = {
    params ["_u"];
    [[_u], {
        params ["_u"];
        if (!isNil "ace_medical_treatment_fnc_fullHealLocal") then { [_u] call ace_medical_treatment_fnc_fullHealLocal }
        else { _u setDamage 0; if (lifeState _u == "INCAPACITATED") then { _u setUnconscious false } };
    }] remoteExec ["spawn", _u];
};

A3GM_fnc_medevacLZ = {
    params ["_center", ["_radius", 150]];
    // A hot LZ costs the helicopter: with enemies within 500 m, look on the side away from the nearest
    private _from = _center;
    private _search = _radius;
    private _hostile = call A3GM_fnc_hostileSides;
    private _enemies = (_center nearEntities [["CAManBase", "LandVehicle"], 500]) select { alive _x && {side group _x in _hostile} };
    if (_enemies isNotEqualTo []) then {
        private _e = ([_enemies, [_center], { _input0 distance2D _x }, "ASCEND"] call BIS_fnc_sortBy) select 0;
        _from = _center getPos [_radius * 0.6, _e getDir _center];
        _search = _radius * 0.5;
    };
    private _lz = [_from, 0, _search, 12, 0, 0.35, 0, [], [_center, _center]] call BIS_fnc_findSafePos;
    if (count _lz < 2 || {_lz distance2D _center > _radius + 50}) then { _lz = _center };
    [_lz select 0, _lz select 1, 0]
};

A3GM_fnc_medevacLand = {
    // Fly to _lz and land; true once on the ground (or false: shot down, crew dead, timed out)
    params ["_heli", "_lz", ["_timeout", 300]];
    private _pad = createVehicle ["Land_HelipadEmpty_F", _lz, [], 0, "CAN_COLLIDE"];
    private _grp = group driver _heli;
    driver _heli enableAI "MOVE";  // parked at the last stop
    _heli setVariable ["A3GM_parked", false];
    _heli land "NONE";
    _grp move _lz;
    _heli flyInHeight 70;
    private _end = time + _timeout;
    private _retry = time + 8;
    private _diag = [_heli, _lz] spawn {  // flight diagnostics every 15 s (A3GM|diag|...)
        params ["_heli", "_lz"];
        while { alive _heli } do {
            private _grp = group driver _heli;
            diag_log text format ["A3GM|diag|heli %1 at %2 dist %3 alt %4 speed %5 ground %6 leader %7 (%8) cmd %9 wps %10 ready %11 engine %12 local %13 dmg %14",
                typeOf _heli, mapGridPosition _heli, round (_heli distance2D _lz), round ((getPosATL _heli) select 2),
                round speed _heli, isTouchingGround _heli, name leader _grp, assignedVehicleRole (leader _grp),
                currentCommand driver _heli, count waypoints _grp, unitReady driver _heli, isEngineOn _heli,
                local driver _heli, (damage _heli) toFixed 2];
            sleep 15;
        };
    };
    waitUntil {
        sleep 1;
        // A move order given to a pilot who's still shutting down from the last landing gets dropped (it then sits
        // there, engine off, with its passengers aboard): repeat it while it's on the ground with nothing to do.
        if (time > _retry && {alive _heli} && {alive driver _heli} && {isTouchingGround _heli} && {unitReady driver _heli}
            && {_heli distance2D _lz >= 250}) then {
            _retry = time + 8;
            diag_log text format ["A3GM|diag|heli %1 at %2 still down, engine %3: take-off order repeated",
                typeOf _heli, mapGridPosition _heli, isEngineOn _heli];
            _heli land "NONE";
            _heli engineOn true;
            _grp move _lz;
            driver _heli doMove _lz;
            _heli flyInHeight 70;
        };
        !alive _heli || {!alive driver _heli} || {time > _end} || {_heli distance2D _lz < 250}
            || {_heli getVariable ["A3GM_cancel", false]}
    };
    if (alive _heli && {alive driver _heli} && {time <= _end} && {!(_heli getVariable ["A3GM_cancel", false])}) then {
        // A land order given while the move is still finishing gets dropped (the heli then hovers at its flight
        // height): repeat it while it's still up there. Close and low, leave it alone: a fresh move order makes it
        // climb out and come round again (the up-and-down players saw on slopes).
        _heli land "LAND";
        waitUntil {
            sleep 2;
            private _alt = (getPosATL _heli) select 2;
            if (_alt > 8 && {unitReady driver _heli}) then {
                if (_heli distance2D _lz > 60) then { driver _heli doMove _lz };
                _heli land "LAND";
            };
            !alive _heli || {!alive driver _heli} || {time > _end}
                || {(isTouchingGround _heli || {((getPosATL _heli) select 2) < 1.5}) && {speed _heli < 3}}
        };
    };
    deleteVehicle _pad;
    terminate _diag;
    // down at the LZ: one that never left the last stop hasn't landed here
    private _down = alive _heli && {alive driver _heli} && {isTouchingGround _heli || {((getPosATL _heli) select 2) < 1.5}}
        && {_heli distance2D _lz < 400};
    if (_down) then {
        // Parked: the pilot can't lift off (a "GET IN" landing climbs out again when someone outside the crew
        // walks up), and anyone may board
        driver _heli disableAI "MOVE";
        _heli lock 0;
        _heli lockCargo false;
        _heli setVariable ["A3GM_parked", true];
        _heli setVariable ["A3GM_parkedAt", time];
    };
    _down
};

// Passengers: everyone aboard who isn't the helicopter's own crew
A3GM_fnc_heliPassengers = {
    params ["_heli"];
    private _crew = units group driver _heli;
    (crew _heli) select { !(_x in _crew) && {alive _x} }
};

// Wait for the person who called it, then for everyone else close by who's coming along: any player within
// 75 m of the helicopter, and their AI squadmates, until they're all aboard (up to _extra s more).
// Returns the number of passengers aboard.
A3GM_fnc_heliBoard = {
    params ["_heli", "_target", ["_timeout", 180], ["_extra", 45]];
    private _end = time + _timeout;
    waitUntil {
        sleep 2;
        if (_target getVariable ["A3GM_standin", false] && {vehicle _target != _heli} && {_target distance2D _heli < 300}
            && {time >= (_heli getVariable ["A3GM_parkedAt", time]) + (_target getVariable ["A3GM_standinDelay", 0])}) then {
            _target moveInCargo _heli;
        };
        !alive _heli || {vehicle _target == _heli} || {time > _end} || {_heli getVariable ["A3GM_cancel", false]}
    };
    if (!alive _heli || {vehicle _target != _heli}) exitWith { 0 };
    private _end2 = time + _extra;
    waitUntil {
        sleep 3;
        private _coming = (call A3GM_fnc_players) select { alive _x && {_x distance2D _heli < 75} && {vehicle _x != _heli} };
        { _coming append ((units group _x) select { !isPlayer _x && {alive _x} && {_x distance2D _heli < 75} && {vehicle _x != _heli} }) }
            forEach +_coming;
        !alive _heli || {_coming isEqualTo []} || {time > _end2}
    };
    sleep 3;  // the last one in, doors closing
    count ([_heli] call A3GM_fnc_heliPassengers)
};

// Get every passenger out, again and again (slow or unconscious ones), until nobody is left aboard. True if
// empty; false after _timeout (the helicopter then stays down rather than fly off with someone).
A3GM_fnc_heliUnload = {
    params ["_heli", ["_timeout", 300]];
    private _end = time + _timeout;
    waitUntil {
        {
            [[_x], { params ["_u"]; unassignVehicle _u; moveOut _u }] remoteExec ["spawn", _x];
        } forEach ([_heli] call A3GM_fnc_heliPassengers);
        sleep 3;
        !alive _heli || {([_heli] call A3GM_fnc_heliPassengers) isEqualTo []} || {time > _end}
    };
    { if (!alive _x) then { moveOut _x } } forEach crew _heli;  // nobody's body flies away either
    ([_heli] call A3GM_fnc_heliPassengers) isEqualTo []
};

A3GM_fnc_medevacLeave = {
    params ["_heli", "_from"];
    if (!alive _heli) exitWith {};
    if (isTouchingGround _heli && {([_heli] call A3GM_fnc_heliPassengers) isNotEqualTo []}) then {
        [_heli, 120] call A3GM_fnc_heliUnload;  // last check before lifting off with someone aboard
    };
    driver _heli enableAI "MOVE";
    _heli setVariable ["A3GM_parked", false];
    private _grp = group driver _heli;
    _heli land "NONE";
    _grp move (_from getPos [4000, (_heli getDir _from) + 180]);
    _heli flyInHeight 150;
    [_heli, _grp] spawn {
        params ["_heli", "_grp"];
        private _end = time + 240;
        waitUntil { sleep 5; !alive _heli || {time > _end} || {((call A3GM_fnc_players) findIf { _x distance2D _heli < 2500 }) < 0} };
        if (alive _heli && {(crew _heli) findIf { isPlayer _x } >= 0}) exitWith {};  // a player hitched a ride: leave it
        { deleteVehicle _x } forEach crew _heli;
        deleteVehicle _heli;
        deleteGroup _grp;
    };
};

// A cancelled flight: anyone aboard is put down where it is first, then it goes home
A3GM_fnc_supportAbort = {
    params ["_asset", "_id", "_target", "_heli"];
    [_asset, _id, "cancelled", _target, ""] call A3GM_fnc_supportLog;
    if (alive _heli && {!isTouchingGround _heli} && {([_heli] call A3GM_fnc_heliPassengers) isNotEqualTo []}) then {
        _heli setVariable ["A3GM_cancel", false];
        [_heli, [getPos _heli, 200] call A3GM_fnc_medevacLZ, 300] call A3GM_fnc_medevacLand;
    };
    [_heli, getPos _heli] call A3GM_fnc_medevacLeave;
};

// A squad nobody needs any more: gone once no player is within 500 m (3 minutes at most), with its empty vehicles
A3GM_fnc_squadRemove = {
    _this spawn {
        params ["_grp", ["_vehicles", []]];
        private _end = time + 180;
        waitUntil { sleep 5; time > _end || {((call A3GM_fnc_players) findIf { _x distance2D (leader _grp) < 500 }) < 0} };
        { deleteVehicle _x } forEach units _grp;
        { if (!isNull _x && {(crew _x) findIf { isPlayer _x } < 0}) then { deleteVehicle _x } } forEach _vehicles;
        deleteGroup _grp;
    };
};

A3GM_fnc_medevac = {
    params [["_id", "", [""]], ["_name", "", [""]], ["_mode", "auto", [""]]];
    private _target = [_name] call A3GM_fnc_supportTarget;
    if (isNull _target) exitWith { [false, "no such player"] };
    private _hq = [_target] call A3GM_fnc_rebelHQ;
    _mode = toLower _mode;
    if (_mode == "auto") then { _mode = ["extract", "revive"] select ((_target call A3GM_fnc_condition) != "fit") };
    if (_mode == "extract" && {_target distance2D _hq < 400}) exitWith { [false, "you're already at HQ"] };

    private _heli = [_target, side group _target] call A3GM_fnc_spawnHeli;
    if (isNull _heli) exitWith { [false, "no medevac helicopter available"] };
    private _eta = round ((_heli distance2D _target) / 55 + 40);
    [_id, [_heli]] call A3GM_fnc_supportRegister;
    [_id, "launched", _target, format ["%1 %2 eta %3", typeOf _heli, _mode, _eta]] call A3GM_fnc_medevacLog;

    [_id, _target, _heli, _mode, _hq] spawn {
        params ["_id", "_target", "_heli", "_mode", "_hq"];
        private _lz = [getPos _target] call A3GM_fnc_medevacLZ;
        private _smoke = createVehicle ["SmokeShellGreen", _lz, [], 0, "CAN_COLLIDE"];
        [_id, "landing", _target, mapGridPosition _lz] call A3GM_fnc_medevacLog;
        private _landed = [_heli, _lz] call A3GM_fnc_medevacLand;
        if ([_id] call A3GM_fnc_cancelled) exitWith { ["medevac", _id, _target, _heli] call A3GM_fnc_supportAbort };
        if (!_landed) exitWith {
            [_id, "failed", _target, ["could not land", "lost"] select ([_heli] call A3GM_fnc_heliLost)] call A3GM_fnc_medevacLog;
            [_heli, _lz] call A3GM_fnc_medevacLeave;
        };
        [_id, "landed", _target, mapGridPosition _heli] call A3GM_fnc_medevacLog;

        if (_mode == "revive") exitWith {
            sleep 8;  // the medic gets out to them (the LZ can be 250 m off: flat ground, away from the enemy)
            private _treated = (call A3GM_fnc_players) select { _x distance2D _heli < 60 && {(_x call A3GM_fnc_condition) != "fit"} };
            if (alive _target && {_target distance2D _heli < 250}) then { _treated pushBackUnique _target };
            if (_treated isEqualTo []) exitWith {
                [_id, "failed", _target, "casualty not at the LZ"] call A3GM_fnc_medevacLog;
                [_heli, _lz] call A3GM_fnc_medevacLeave;
            };
            { [_x] call A3GM_fnc_medevacHeal } forEach _treated;
            [_id, "healed", _target, (_treated apply { name _x }) joinString ", "] call A3GM_fnc_medevacLog;
            sleep 5;
            [_id, "wheelsup", _target, "rtb"] call A3GM_fnc_medevacLog;
            [_heli, _lz] call A3GM_fnc_medevacLeave;
            [_id, "done", _target, ""] call A3GM_fnc_medevacLog;
        };

        // extract: board them (carry them aboard if they can't walk), up to 3 minutes
        private _end = time + 180;
        waitUntil {
            sleep 2;
            // the crew carries a casualty who can't walk from anywhere the LZ could be (up to 150 m away)
            if (alive _target && {vehicle _target != _heli} && {_target distance2D _heli < 200}
                && {(_target call A3GM_fnc_condition) in ["unconscious", "bleeding"] || {_target getVariable ["A3GM_standin", false]}}) then {
                [[_target, _heli], { params ["_u", "_h"]; _u moveInCargo _h }] remoteExec ["spawn", _target];
            };
            !alive _heli || {!alive _target} || {vehicle _target == _heli} || {time > _end} || {[_id] call A3GM_fnc_cancelled}
        };
        if ([_id] call A3GM_fnc_cancelled) exitWith { ["medevac", _id, _target, _heli] call A3GM_fnc_supportAbort };
        if (!alive _heli || {vehicle _target != _heli}) exitWith {
            [_id, "failed", _target, ["casualty didn't board", "lost"] select (!alive _heli)] call A3GM_fnc_medevacLog;
            [_heli, _lz] call A3GM_fnc_medevacLeave;
        };
        // anyone else coming along (squadmates escorting the casualty)
        private _aboard = [_heli, _target, 5, 30] call A3GM_fnc_heliBoard;
        [_id, "aboard", _target, str _aboard] call A3GM_fnc_medevacLog;
        [_target] call A3GM_fnc_medevacHeal;  // the crew medic works on them in flight
        [_id, "wheelsup", _target, "hq"] call A3GM_fnc_medevacLog;
        private _hqLz = [_hq, 200] call A3GM_fnc_medevacLZ;
        _landed = [_heli, _hqLz, 600] call A3GM_fnc_medevacLand;
        if ([_id] call A3GM_fnc_cancelled) exitWith { ["medevac", _id, _target, _heli] call A3GM_fnc_supportAbort };
        if (!_landed) exitWith {
            [_id, "failed", _target, ["could not land at HQ", "lost"] select ([_heli] call A3GM_fnc_heliLost)] call A3GM_fnc_medevacLog;
            [_heli, getPos _heli] call A3GM_fnc_medevacLeave;
        };
        if !([_heli] call A3GM_fnc_heliUnload) then {
            [_id, "diag", _target, "passengers still aboard at HQ"] call A3GM_fnc_medevacLog;
        };
        [_id, "hq", _target, mapGridPosition _heli] call A3GM_fnc_medevacLog;
        [_heli, _hqLz] call A3GM_fnc_medevacLeave;
        [_id, "done", _target, ""] call A3GM_fnc_medevacLog;
    };
    [true, format ["%1 %2 eta %3", _mode, mapGridPosition _target, _eta]]
};

// Support assets, all reporting progress as A3GM|<asset>|id|stage|player|detail for the Game Master's radio.
A3GM_fnc_supportLog = {
    params ["_asset", "_id", "_stage", "_unit", ["_detail", ""]];
    diag_log text format ["A3GM|%1|%2|%3|%4|%5", _asset, _id, _stage,
        (if (isNull _unit) then {""} else {name _unit}) call A3GM_fnc_clean, _detail call A3GM_fnc_clean];
};

A3GM_fnc_rebelHQ = {
    params ["_near"];
    private _hq = markerPos "Synd_HQ";
    if (_hq isEqualTo [0, 0, 0]) then { _hq = _near getPos [3000, random 360] };
    _hq
};

// A helicopter with an AI crew of the player's side, flying in from HQ (or 3 km out on the HQ side)
A3GM_fnc_spawnHeli = {
    params ["_target", "_side", ["_classes", A3GM_medevacHelis], ["_offset", [0, 0, 0]]];
    private _class = [_classes, _side] call A3GM_fnc_sideClasses param [0, ""];
    if (_class == "") exitWith { objNull };
    private _hq = [_target] call A3GM_fnc_rebelHQ;
    // from HQ when that's 1.5-6 km away, else 3 km out on the HQ side (a caller at HQ had it appear overhead)
    private _d = _target distance2D _hq;
    private _start = if (_d > 1500 && {_d < 6000}) then { _hq } else { _target getPos [3000, _target getDir _hq] };
    _start = [(_start select 0) + (_offset select 0), (_start select 1) + (_offset select 1), 150 + (_offset select 2)];
    private _heli = createVehicle [_class, _start, [], 0, "FLY"];
    _heli setPosATL _start;
    _heli setDir (_start getDir _target);
    _heli setVelocityModelSpace [0, 40, 0];
    private _grp = createGroup [_side, true];
    createVehicleCrew _heli;
    (crew _heli) joinSilent _grp;
    _grp setBehaviour "CARELESS";
    _grp setCombatMode "BLUE";
    _heli lockCargo false;
    _heli
};

// High-tier military combat loadouts for backup troops
A3GM_fnc_equipMilitaryUnit = {
    params ["_unit", "_role", "_side"];
    removeAllWeapons _unit;
    removeAllItems _unit;
    removeAllAssignedItems _unit;
    removeUniform _unit;
    removeVest _unit;
    removeBackpack _unit;
    removeHeadgear _unit;
    removeGoggles _unit;

    private _isIndep = _side == independent;
    private _isWest = _side == west;

    private _uniform = switch (true) do {
        case _isWest: { "U_B_CombatUniform_mcam" };
        case _isIndep: { "U_I_CombatUniform" };
        default { "U_O_CombatUniform_ocamo" };
    };
    if (!isClass (configFile >> "CfgWeapons" >> _uniform)) then { _uniform = "U_I_CombatUniform" };

    private _vest = switch (true) do {
        case _isWest: { "V_PlateCarrier2_rgr" };
        case _isIndep: { "V_PlateCarrierIA2_dgtl" };
        default { "V_HarnessO_brn" };
    };
    if (!isClass (configFile >> "CfgWeapons" >> _vest)) then { _vest = "V_PlateCarrier1_rgr" };

    private _headgear = switch (true) do {
        case _isWest: { "H_HelmetB" };
        case _isIndep: { "H_HelmetIA" };
        default { "H_HelmetO_ocamo" };
    };
    if (!isClass (configFile >> "CfgWeapons" >> _headgear)) then { _headgear = "H_HelmetB" };

    private _backpack = switch (true) do {
        case _isWest: { "B_AssaultPack_mcamo" };
        case _isIndep: { "B_AssaultPack_dgtl" };
        default { "B_FieldPack_ocamo" };
    };
    if (!isClass (configFile >> "CfgVehicles" >> _backpack)) then { _backpack = "B_AssaultPack_rgr" };

    _unit forceAddUniform _uniform;
    _unit addVest _vest;
    _unit addHeadgear _headgear;
    _unit addBackpack _backpack;

    private _primary = "";
    private _primaryMags = [];
    private _secondary = "";
    private _secondaryMags = [];
    private _handgun = "hgun_P07_F";
    private _handgunMag = "16Rnd_9x21_Mag";
    private _optic = "optic_ACO_grn";

    switch (_role) do {
        case "SL": {
            _primary = if (_isIndep) then { "arifle_Mk20_GL_F" } else { if (_isWest) then { "arifle_MX_GL_F" } else { "arifle_Katiba_GL_F" } };
            _optic = if (_isIndep) then { "optic_MRCO" } else { "optic_Hamr" };
            _primaryMags = [["30Rnd_556x45_Stanag", 8], ["1Rnd_HE_Grenade_shell", 4], ["1Rnd_Smoke_Grenade_shell", 2]];
            _unit addWeapon "Binocular";
        };
        case "MG": {
            _primary = if (_isIndep) then { "LMG_Mk200_F" } else { if (_isWest) then { "arifle_MX_SW_F" } else { "LMG_Zafir_F" } };
            _optic = "optic_Holosight";
            private _mag = if (_isIndep) then { "200Rnd_65x39_cased_Box" } else { if (_isWest) then { "100Rnd_65x39_caseless_mag" } else { "150Rnd_762x54_Box" } };
            _primaryMags = [[_mag, 4]];
        };
        case "LAT": {
            _primary = if (_isIndep) then { "arifle_Mk20_F" } else { if (_isWest) then { "arifle_MX_F" } else { "arifle_Katiba_F" } };
            _primaryMags = [["30Rnd_556x45_Stanag", 6]];
            _secondary = if (_isIndep) then { "launch_NLAW_F" } else { if (_isWest) then { "launch_NLAW_F" } else { "launch_RPG32_F" } };
            _secondaryMags = [["NLAW_F", 2], ["RPG32_F", 2]] select (!_isIndep && !_isWest);
        };
        case "MEDIC": {
            _primary = if (_isIndep) then { "arifle_Mk20C_F" } else { if (_isWest) then { "arifle_MXC_F" } else { "arifle_Katiba_C_F" } };
            _primaryMags = [["30Rnd_556x45_Stanag", 6]];
        };
        case "MARKSMAN": {
            _primary = if (_isIndep) then { "srifle_DMR_06_camo_F" } else { if (_isWest) then { "srifle_EBR_F" } else { "srifle_DMR_01_F" } };
            _optic = "optic_SOS";
            _primaryMags = [["20Rnd_762x51_Mag", 7], ["10Rnd_762x54_Mag", 7]] select (!_isIndep && !_isWest);
            _unit addWeapon "Binocular";
        };
        case "GL": {
            _primary = if (_isIndep) then { "arifle_Mk20_GL_F" } else { if (_isWest) then { "arifle_MX_GL_F" } else { "arifle_Katiba_GL_F" } };
            _primaryMags = [["30Rnd_556x45_Stanag", 6], ["1Rnd_HE_Grenade_shell", 6], ["1Rnd_Smoke_Grenade_shell", 2]];
        };
        default {
            _primary = if (_isIndep) then { "arifle_Mk20_F" } else { if (_isWest) then { "arifle_MX_F" } else { "arifle_Katiba_F" } };
            _primaryMags = [["30Rnd_556x45_Stanag", 7]];
        };
    };

    if (!isClass (configFile >> "CfgWeapons" >> _primary)) then {
        _primary = "arifle_Mk20_F";
        _primaryMags = [["30Rnd_556x45_Stanag", 6]];
    };

    {
        _x params ["_magClass", "_count"];
        if (isClass (configFile >> "CfgMagazines" >> _magClass)) then {
            for "_m" from 1 to _count do { _unit addMagazine _magClass };
        };
    } forEach _primaryMags;

    if (_secondary != "" && {isClass (configFile >> "CfgWeapons" >> _secondary)}) then {
        {
            _x params ["_magClass", "_count"];
            if (isClass (configFile >> "CfgMagazines" >> _magClass)) then {
                for "_m" from 1 to _count do { _unit addMagazine _magClass };
            };
        } forEach _secondaryMags;
        _unit addWeapon _secondary;
    };

    _unit addWeapon _primary;
    if (_optic != "" && {isClass (configFile >> "CfgWeapons" >> _optic)}) then {
        _unit addPrimaryWeaponItem _optic;
    };

    if (isClass (configFile >> "CfgWeapons" >> _handgun) && {isClass (configFile >> "CfgMagazines" >> _handgunMag)}) then {
        _unit addMagazine _handgunMag;
        _unit addMagazine _handgunMag;
        _unit addWeapon _handgun;
    };

    if (!isNil "ace_medical_treatment_fnc_fullHealLocal") then {
        for "_i" from 1 to 8 do { _unit addItem "ACE_fieldDressing" };
        for "_i" from 1 to 4 do { _unit addItem "ACE_morphine" };
        for "_i" from 1 to 2 do { _unit addItem "ACE_tourniquet" };
        for "_i" from 1 to 2 do { _unit addItem "ACE_splint" };
        if (_role == "MEDIC") then {
            for "_i" from 1 to 15 do { _unit addItem "ACE_elasticBandage" };
            for "_i" from 1 to 15 do { _unit addItem "ACE_packingBandage" };
            for "_i" from 1 to 8 do { _unit addItem "ACE_epinephrine" };
            for "_i" from 1 to 4 do { _unit addItem "ACE_salineIV_500" };
            _unit addItem "ACE_surgicalKit";
        };
    } else {
        for "_i" from 1 to ([3, 10] select (_role == "MEDIC")) do { _unit addItem "FirstAidKit" };
        if (_role == "MEDIC") then { _unit addItem "Medikit" };
    };

    _unit addItem "MiniGrenade";
    _unit addItem "MiniGrenade";
    _unit addItem "SmokeShell";
    _unit addItem "SmokeShellGreen";

    _unit linkItem "ItemMap";
    _unit linkItem "ItemCompass";
    _unit linkItem "ItemWatch";
    _unit linkItem "NVGoggles";

    private _radio = missionNamespace getVariable ["A3GM_radioItem", "ItemRadio"];
    if (isClass (configFile >> "CfgWeapons" >> _radio)) then { _unit linkItem _radio };

    _unit selectWeapon (primaryWeapon _unit);
};

// High-tier equipped combat squad for backup
A3GM_fnc_rebelSquad = {
    params ["_side", "_pos", ["_n", 8]];
    private _grp = createGroup [_side, true];
    private _roles = ["SL", "MG", "LAT", "MEDIC", "MARKSMAN", "GL", "RIFLE", "RIFLE", "MG", "LAT", "RIFLE", "RIFLE", "RIFLE", "RIFLE", "RIFLE", "RIFLE"];
    for "_i" from 0 to (_n - 1) do {
        private _role = _roles select (_i mod count _roles);
        private _u = _grp createUnit ["I_G_Soldier_F", _pos, [], 5, "NONE"];
        [_u, _role, _side] call A3GM_fnc_equipMilitaryUnit;
        if (!isNil "A3A_fnc_initRevive") then { [_u] call A3A_fnc_initRevive };
        _u setVariable ["spawner", true, true];
    };
    _grp selectLeader ((units _grp) select 0);
    _grp setBehaviour "AWARE";
    _grp setCombatMode "RED";
    _grp
};

// The squad sticks with the player as a bodyguard squad for 15 minutes, then is removed once no player is near
A3GM_fnc_backupEscort = {
    params ["_asset", "_id", "_target", "_grp", ["_vehicles", []]];
    if (_vehicles isEqualType objNull) then { _vehicles = [_vehicles] };
    private _end = time + 900;
    while { time < _end && {({ alive _x } count units _grp) > 0} && {!([_id] call A3GM_fnc_cancelled)} } do {
        if (alive _target) then {
            if ((leader _grp) distance2D _target > 35) then {
                _grp setSpeedMode "FULL";
                _grp move (_target getPos [12 + random 10, random 360]);
            } else {
                _grp setSpeedMode "NORMAL";
            };
        };
        sleep 10;
    };
    if ([_id] call A3GM_fnc_cancelled) exitWith {
        [_asset, _id, "cancelled", _target, ""] call A3GM_fnc_supportLog;
        [_grp, _vehicles] call A3GM_fnc_squadRemove;
    };
    [_asset, _id, ["done", "lost"] select (({ alive _x } count units _grp) == 0), _target, ""] call A3GM_fnc_supportLog;
    waitUntil { sleep 10; ((call A3GM_fnc_players) findIf { _x distance2D (leader _grp) < 1200 }) < 0 || {({ alive _x } count units _grp) == 0} };
    { deleteVehicle _x } forEach units _grp;
    { if (!isNull _x && {(crew _x) findIf { isPlayer _x } < 0}) then { deleteVehicle _x } } forEach _vehicles;
    deleteGroup _grp;
};

// BACKUP: helicopter air-insertion with armed gunship escort providing cover fire. args: [id, player name]
A3GM_fnc_backup = {
    params [["_id", "", [""]], ["_name", "", [""]]];
    private _target = [_name] call A3GM_fnc_supportTarget;
    if (isNull _target) exitWith { [false, "no such player"] };
    private _side = side group _target;

    private _heliClass = [A3GM_backupHelis, _side] call A3GM_fnc_sideClasses param [0, ""];
    if (_heliClass == "") exitWith { [false, "no transport helicopter available"] };
    private _gunshipClass = [A3GM_gunships, _side] call A3GM_fnc_sideClasses param [0, ""];

    // Spawn transport helicopter
    private _heli = [_target, _side, [_heliClass], [0, 0, 0]] call A3GM_fnc_spawnHeli;
    if (isNull _heli) exitWith { [false, "failed to spawn transport helicopter"] };

    // Spawn armed escort gunship if available
    private _gunship = if (_gunshipClass != "") then {
        [_target, _side, [_gunshipClass], [150, 150, 30]] call A3GM_fnc_spawnHeli
    } else { objNull };

    // Fill 100% of transport passenger seats
    private _capacity = (_heli emptyPositions "cargo") max 8;
    private _squad = [_side, getPos _heli, _capacity] call A3GM_fnc_rebelSquad;
    { _x moveInCargo _heli } forEach units _squad;

    private _assets = [_heli] + units _squad;
    if (!isNull _gunship) then { _assets pushBack _gunship };
    [_id, _assets] call A3GM_fnc_supportRegister;

    private _eta = round ((_heli distance2D _target) / 55 + 40);
    ["backup", _id, "launched", _target, format ["helicopter %1 eta %2", count units _squad, _eta]] call A3GM_fnc_supportLog;

    // Launch gunship escort routine
    if (!isNull _gunship) then {
        private _gunshipGrp = group driver _gunship;
        _gunshipGrp setBehaviour "COMBAT";
        _gunshipGrp setCombatMode "RED";
        _gunship lockCargo true;
        _gunship flyInHeight 120;
        (driver _gunship) setSkill 0.9;
        if (!isNull (gunner _gunship)) then { (gunner _gunship) setSkill 0.95 };

        [_id, _target, _gunship, _gunshipGrp] spawn {
            params ["_id", "_target", "_gunship", "_gunshipGrp"];
            private _center = getPos _target;
            private _wp = _gunshipGrp addWaypoint [_center, 0];
            _wp setWaypointType "LOITER";
            _wp setWaypointLoiterType "CIRCLE_L";
            _wp setWaypointLoiterRadius 300;
            _wp setWaypointSpeed "NORMAL";

            waitUntil {
                sleep 2;
                [_gunship] call A3GM_fnc_heliLost || {_gunship distance2D _center < 700} || {[_id] call A3GM_fnc_cancelled}
            };
            if (!([_gunship] call A3GM_fnc_heliLost) && {!([_id] call A3GM_fnc_cancelled)}) then {
                ["backup", _id, "escort_onstation", _target, mapGridPosition _center] call A3GM_fnc_supportLog;
            };

            private _hostile = call A3GM_fnc_hostileSides;
            private _end = time + 500;
            while { !([_gunship] call A3GM_fnc_heliLost) && {time < _end} && {!([_id] call A3GM_fnc_cancelled)} } do {
                if (alive _target && {_target distance2D _center > 150}) then {
                    _center = getPos _target;
                    _wp setWaypointPosition [_center, 0];
                };
                private _enemies = (_center nearEntities [["CAManBase", "LandVehicle"], 700]) select { alive _x && {side group _x in _hostile} };
                {
                    _gunshipGrp reveal [_x, 3.5];
                    if (!isNull (gunner _gunship)) then { (gunner _gunship) doTarget _x };
                } forEach _enemies;

                private _hasAmmo = ({ (_x select 2) > 0 } count (magazinesAllTurrets _gunship)) > 0;
                if (!_hasAmmo) exitWith {
                    diag_log text format ["A3GM|diag|backup %1 gunship out of ammo", _id];
                };
                sleep 10;
            };

            if ([_id] call A3GM_fnc_cancelled) then {
                ["backup", _id, "escort_cancelled", _target, ""] call A3GM_fnc_supportLog;
            } else {
                ["backup", _id, ["escort_rtb", "escort_lost"] select ([_gunship] call A3GM_fnc_heliLost), _target, ""] call A3GM_fnc_supportLog;
            };
            _gunshipGrp setCombatMode "BLUE";
            _gunshipGrp setBehaviour "CARELESS";
            while { count waypoints _gunshipGrp > 0 } do { deleteWaypoint [_gunshipGrp, 0] };
            [_gunship, getPos _gunship] call A3GM_fnc_medevacLeave;
        };
    };

    // Transport flight and unloading routine
    [_id, _target, _heli, _squad] spawn {
        params ["_id", "_target", "_heli", "_squad"];
        private _lz = [_target getPos [120 + random 50, random 360], 150] call A3GM_fnc_medevacLZ;
        private _smoke = createVehicle ["SmokeShellGreen", _lz, [], 0, "CAN_COLLIDE"];
        ["backup", _id, "landing", _target, mapGridPosition _lz] call A3GM_fnc_supportLog;

        private _landed = [_heli, _lz] call A3GM_fnc_medevacLand;
        if ([_id] call A3GM_fnc_cancelled) exitWith {
            ["backup", _id, "cancelled", _target, ""] call A3GM_fnc_supportLog;
            [_heli, _lz] call A3GM_fnc_medevacLeave;
            [_squad] call A3GM_fnc_squadRemove;
        };
        if (!_landed) exitWith {
            ["backup", _id, "lost", _target, "helicopter"] call A3GM_fnc_supportLog;
            [_heli, _lz] call A3GM_fnc_medevacLeave;
            [_squad] call A3GM_fnc_squadRemove;
        };

        createVehicle ["SmokeShellGreen", getPosATL _heli, [], 0, "CAN_COLLIDE"];

        // Unload all passengers reliably
        {
            unassignVehicle _x;
            [_x] orderGetIn false;
            [_x] allowGetIn false;
            _x leaveVehicle _heli;
            moveOut _x;
        } forEach units _squad;

        private _unloadTimeout = time + 45;
        waitUntil {
            sleep 2;
            {
                if (vehicle _x == _heli) then {
                    unassignVehicle _x;
                    [_x] orderGetIn false;
                    [_x] allowGetIn false;
                    _x leaveVehicle _heli;
                    moveOut _x;
                };
            } forEach units _squad;
            !alive _heli || {([_heli] call A3GM_fnc_heliPassengers) isEqualTo []} || {time > _unloadTimeout}
        };

        ["backup", _id, "arrived", _target, mapGridPosition _lz] call A3GM_fnc_supportLog;
        [_heli, _lz] call A3GM_fnc_medevacLeave;

        _squad setBehaviour "AWARE";
        _squad setCombatMode "RED";
        _squad selectLeader ((units _squad) select 0);

        ["backup", _id, _target, _squad] call A3GM_fnc_backupEscort;
    };

    [true, format ["helicopter %1 %2 eta %3", count units _squad, mapGridPosition _target, _eta]]
};

// UAV: an unarmed Greyhawk loitering over the player for 15 minutes; the player gets a UAV terminal if they
// have none; enemy groups it knows about are reported for the battle net every 15 s:
//   A3GM|uavspot|id|x|y|count|kind      kind: INF VEH APC ARMOR AIR BOAT
// args: [id, player name]
A3GM_fnc_uav = {
    params [["_id", "", [""]], ["_name", "", [""]]];
    private _target = [_name] call A3GM_fnc_supportTarget;
    if (isNull _target) exitWith { [false, "no such player"] };
    private _side = side group _target;
    private _class = [["I_UAV_02_dynamicLoadout_F", "B_UAV_02_dynamicLoadout_F", "O_UAV_02_dynamicLoadout_F",
        "I_UAV_01_F", "B_UAV_01_F", "O_UAV_01_F"], _side] call A3GM_fnc_sideClasses param [0, ""];
    if (_class == "") exitWith { [false, "no UAV available"] };
    private _hq = [_target] call A3GM_fnc_rebelHQ;
    private _start = _target getPos [2000, _target getDir _hq];
    _start = [_start select 0, _start select 1, 450];
    private _uav = createVehicle [_class, _start, [], 0, "FLY"];
    _uav setPosATL _start;
    _uav setVelocityModelSpace [0, 50, 0];
    createVehicleCrew _uav;
    private _grp = createGroup [_side, true];
    (crew _uav) joinSilent _grp;
    { _uav setPylonLoadout [_forEachIndex + 1, ""] } forEach (getPylonMagazines _uav);  // recon only
    _grp setBehaviour "CARELESS";
    _grp setCombatMode "BLUE";
    _uav flyInHeight 450;
    private _wp = _grp addWaypoint [getPos _target, 0];
    _wp setWaypointType "LOITER";
    _wp setWaypointLoiterType "CIRCLE_L";
    _wp setWaypointLoiterRadius 600;
    private _terminal = ["I_UavTerminal", "B_UavTerminal", "O_UavTerminal"] select (([independent, west, east] find _side) max 0);
    [[_target, _terminal], {
        params ["_u", "_t"];
        if ((assignedItems _u) findIf { "uavterminal" in toLower _x } < 0) then { _u linkItem _t };
    }] remoteExec ["spawn", _target];
    [_id, [_uav]] call A3GM_fnc_supportRegister;
    ["uav", _id, "launched", _target, format ["%1 eta %2", getText (configFile >> "CfgVehicles" >> _class >> "displayName"),
        round ((_uav distance2D _target) / 60)]] call A3GM_fnc_supportLog;

    [_id, _target, _uav, _grp] spawn {
        params ["_id", "_target", "_uav", "_grp"];
        private _center = getPos _target;
        waitUntil { sleep 3; !alive _uav || {_uav distance2D _center < 900} || {[_id] call A3GM_fnc_cancelled} };
        if (alive _uav && {!([_id] call A3GM_fnc_cancelled)}) then {
            ["uav", _id, "onstation", _target, mapGridPosition _center] call A3GM_fnc_supportLog };
        private _hostile = call A3GM_fnc_hostileSides;
        private _end = time + 900;
        while { alive _uav && {time < _end} && {!([_id] call A3GM_fnc_cancelled)} } do {
            // What the camera can see: within 1.5 km and not hidden by terrain or buildings (the UAV crew's own
            // knowsAbout stays at 0)
            private _eye = getPosASL _uav;
            private _seen = allGroups select {
                side _x in _hostile && {alive leader _x} && {(leader _x) distance2D _uav < 1500}
                && {([_uav, "VIEW", vehicle leader _x] checkVisibility [_eye, eyePos (leader _x)]) > 0.2}
            };
            {
                private _l = leader _x;
                private _v = vehicle _l;
                private _kind = switch (true) do {
                    case (_v isKindOf "Air"): { "AIR" };
                    case (_v isKindOf "Ship"): { "BOAT" };
                    case (_v isKindOf "Tank"): { "ARMOR" };
                    case (_v isKindOf "Wheeled_APC_F" || {_v isKindOf "Tracked_APC"}): { "APC" };
                    case (_v isKindOf "Car"): { "VEH" };
                    default { "INF" };
                };
                diag_log text format ["A3GM|uavspot|%1|%2|%3|%4|%5", _id, round ((getPos _l) select 0), round ((getPos _l) select 1),
                    { alive _x } count units _x, _kind];
            } forEach (_seen select [0, 12]);
            diag_log text format ["A3GM|diag|uav %1 at %2 alt %5 dmg %6: %3 enemy groups within 2 km, %4 known",
                _id, mapGridPosition _uav, { side _x in _hostile && {(leader _x) distance2D _uav < 2000} } count allGroups, count _seen,
                round ((getPosATL _uav) select 2), (damage _uav) toFixed 2];
            sleep 15;
        };
        ["uav", _id, ["rtb", "lost"] select (!alive _uav), _target,
            ["", "cancelled"] select ([_id] call A3GM_fnc_cancelled)] call A3GM_fnc_supportLog;
        if (alive _uav) then { [_uav, getPos _uav] call A3GM_fnc_medevacLeave };
    };
    [true, format ["%1 over %2", _class, mapGridPosition _target]]
};

// TRANSPORT: a helicopter picks the player (and whoever boards with them) up and flies them to a grid, or to the
// rebel HQ ("HQ"), lands, unloads and leaves. args: [id, player name, grid or "HQ"]
A3GM_fnc_transport = {
    params [["_id", "", [""]], ["_name", "", [""]], ["_grid", "", [""]]];
    private _target = [_name] call A3GM_fnc_supportTarget;
    if (isNull _target) exitWith { [false, "no such player"] };
    private _dest = if (toUpper _grid == "HQ") then { markerPos "Synd_HQ" } else { _grid call A3GM_fnc_gridPos };
    if (_dest isEqualType "") exitWith { [false, _dest] };
    if (_dest isEqualTo [0, 0, 0]) exitWith { [false, "HQ has no fixed position right now"] };
    if (_target distance2D _dest < 500) exitWith { [false, "you're already there"] };
    private _heli = [_target, side group _target] call A3GM_fnc_spawnHeli;
    if (isNull _heli) exitWith { [false, "no helicopter available"] };
    [_id, [_heli]] call A3GM_fnc_supportRegister;
    private _eta = round ((_heli distance2D _target) / 55 + 40);
    ["transport", _id, "launched", _target, format ["%1 eta %2", mapGridPosition _dest, _eta]] call A3GM_fnc_supportLog;
    [_id, _target, _heli, _dest] spawn {
        params ["_id", "_target", "_heli", "_dest"];
        private _lz = [getPos _target, 150] call A3GM_fnc_medevacLZ;
        createVehicle ["SmokeShellGreen", _lz, [], 0, "CAN_COLLIDE"];
        ["transport", _id, "landing", _target, mapGridPosition _lz] call A3GM_fnc_supportLog;
        private _landed = [_heli, _lz] call A3GM_fnc_medevacLand;
        if ([_id] call A3GM_fnc_cancelled) exitWith { ["transport", _id, _target, _heli] call A3GM_fnc_supportAbort };
        if (!_landed) exitWith {
            ["transport", _id, "failed", _target, ["could not land", "lost"] select ([_heli] call A3GM_fnc_heliLost)] call A3GM_fnc_supportLog;
            [_heli, _lz] call A3GM_fnc_medevacLeave;
        };
        // the caller first, then everyone close by who's coming (players and their AI squadmates)
        private _aboard = [_heli, _target] call A3GM_fnc_heliBoard;
        if ([_id] call A3GM_fnc_cancelled) exitWith { ["transport", _id, _target, _heli] call A3GM_fnc_supportAbort };
        if (!alive _heli || {vehicle _target != _heli}) exitWith {
            ["transport", _id, "failed", _target, ["nobody boarded", "lost"] select (!alive _heli)] call A3GM_fnc_supportLog;
            [_heli, _lz] call A3GM_fnc_medevacLeave;
        };
        ["transport", _id, "wheelsup", _target, format ["%1 %2", mapGridPosition _dest, _aboard]] call A3GM_fnc_supportLog;
        _heli land "NONE";
        private _destLz = [_dest, 200] call A3GM_fnc_medevacLZ;
        _landed = [_heli, _destLz, 900] call A3GM_fnc_medevacLand;
        if ([_id] call A3GM_fnc_cancelled) exitWith { ["transport", _id, _target, _heli] call A3GM_fnc_supportAbort };
        if (!_landed) exitWith {
            ["transport", _id, "failed", _target, ["could not land at the destination", "lost"] select ([_heli] call A3GM_fnc_heliLost)] call A3GM_fnc_supportLog;
            [_heli, getPos _heli] call A3GM_fnc_medevacLeave;
        };
        // everybody out, and nobody left aboard, before it leaves
        if !([_heli] call A3GM_fnc_heliUnload) then {
            ["transport", _id, "diag", _target, "passengers still aboard at the destination"] call A3GM_fnc_supportLog;
        };
        ["transport", _id, "arrived", _target, mapGridPosition _destLz] call A3GM_fnc_supportLog;
        [_heli, _destLz] call A3GM_fnc_medevacLeave;
    };
    [true, format ["%1 eta %2", mapGridPosition _dest, _eta]]
};

// GUNSHIP: an armed helicopter orbiting the player for 10 minutes, shown every enemy within 700 m of them and
// free to engage. args: [id, player name]. Stages: launched, onstation, rtb, lost
A3GM_gunships = ["I_Heli_light_03_dynamicLoadout_F", "B_Heli_Light_01_dynamicLoadout_F", "O_Heli_Light_02_dynamicLoadout_F",
    "B_Heli_Attack_01_dynamicLoadout_F", "O_Heli_Attack_02_dynamicLoadout_F"];
A3GM_fnc_gunship = {
    params [["_id", "", [""]], ["_name", "", [""]]];
    private _target = [_name] call A3GM_fnc_supportTarget;
    if (isNull _target) exitWith { [false, "no such player"] };
    private _heli = [_target, side group _target, A3GM_gunships] call A3GM_fnc_spawnHeli;
    if (isNull _heli) exitWith { [false, "no gunship available"] };
    private _grp = group driver _heli;
    _grp setBehaviour "COMBAT";
    _grp setCombatMode "RED";
    _heli lockCargo true;
    _heli flyInHeight 120;
    private _wp = _grp addWaypoint [getPos _target, 0];
    _wp setWaypointType "LOITER";
    _wp setWaypointLoiterType "CIRCLE_L";
    _wp setWaypointLoiterRadius 350;
    [_id, [_heli]] call A3GM_fnc_supportRegister;
    private _eta = round ((_heli distance2D _target) / 55 + 20);
    ["gunship", _id, "launched", _target, format ["%1 eta %2", getText (configFile >> "CfgVehicles" >> typeOf _heli >> "displayName"),
        _eta]] call A3GM_fnc_supportLog;
    [_id, _target, _heli, _grp, _wp] spawn {
        params ["_id", "_target", "_heli", "_grp", "_wp"];
        private _center = getPos _target;
        waitUntil { sleep 3; [_heli] call A3GM_fnc_heliLost || {_heli distance2D _center < 700} || {[_id] call A3GM_fnc_cancelled} };
        if (!([_heli] call A3GM_fnc_heliLost) && {!([_id] call A3GM_fnc_cancelled)}) then {
            ["gunship", _id, "onstation", _target, mapGridPosition _center] call A3GM_fnc_supportLog };
        private _hostile = call A3GM_fnc_hostileSides;
        private _end = time + 600;
        while { !([_heli] call A3GM_fnc_heliLost) && {time < _end} && {!([_id] call A3GM_fnc_cancelled)} } do {
            // the orbit follows the caller; the crew is told about every enemy near them
            if (alive _target && {_target distance2D _center > 150}) then {
                _center = getPos _target;
                _wp setWaypointPosition [_center, 0];
            };
            private _enemies = (_center nearEntities [["CAManBase", "LandVehicle"], 700]) select { alive _x && {side group _x in _hostile} };
            { _grp reveal [_x, 2.5] } forEach _enemies;
            diag_log text format ["A3GM|diag|gunship %1 at %2 alt %3 dmg %4: %5 enemies within 700 m of %6, ammo %7",
                _id, mapGridPosition _heli, round ((getPosATL _heli) select 2), (damage _heli) toFixed 2, count _enemies,
                mapGridPosition _center, { (_x select 2) > 0 } count (magazinesAllTurrets _heli)];
            sleep 15;
        };
        ["gunship", _id, ["rtb", "lost"] select ([_heli] call A3GM_fnc_heliLost), _target,
            ["", "cancelled"] select ([_id] call A3GM_fnc_cancelled)] call A3GM_fnc_supportLog;
        _grp setCombatMode "BLUE";
        _grp setBehaviour "CARELESS";
        while { count waypoints _grp > 0 } do { deleteWaypoint [_grp, 0] };
        [_heli, getPos _heli] call A3GM_fnc_medevacLeave;
    };
    [true, format ["%1 eta %2", typeOf _heli, _eta]]
};

// args: [overcast 0-1, rain 0-1, fog 0-0.5]
A3GM_fnc_weather = {
    params [["_overcast", 0.5, [0]], ["_rain", 0, [0]], ["_fog", 0, [0]]];
    _overcast = 0 max (_overcast min 1);
    _rain = 0 max (_rain min 1);
    _fog = 0 max (_fog min 0.5);
    0 setOvercast _overcast;
    forceWeatherChange;
    0 setRain _rain;
    120 setFog _fog;
    [true, format ["overcast %1 rain %2 fog %3", _overcast, _rain, _fog]]
};

// Occupant infantry hunting a player from 500-700 m out. args: [player name, "" or "@<grid>", size 2-8]
A3GM_fnc_qrf = {
    params [["_name", "", [""]], ["_size", 4, [0]]];
    _size = 2 max (round _size min 8);
    // "@<grid>": a stand-in to hunt, for testing on an empty server
    private _target = if ((_name select [0, 1]) == "@") then { [_name] call A3GM_fnc_supportTarget } else { [_name] call A3GM_fnc_target };
    if (isNull _target) exitWith { [false, "no player"] };

    // One of the occupant faction's militia squads. Its entries are Antistasi unit types ("loadouts_occ_militia_
    // Rifleman"), not vehicle classes: they only exist through A3A_fnc_createUnit.
    private _faction = missionNamespace getVariable ["A3A_faction_occ", createHashMap];
    private _squads = (_faction getOrDefault ["groupsMilitiaSquads", []]) select { _x isEqualType [] && {_x isNotEqualTo []} };
    private _pool = if (_squads isEqualTo []) then { [] } else { +(selectRandom _squads) };
    if (_pool isEqualTo []) then {
        private _grunt = _faction getOrDefault ["unitMilitiaGrunt", ""];
        if (_grunt isEqualType [] && {_grunt isNotEqualTo []}) then { _grunt = _grunt select 0 };
        _pool = [_grunt];
    };
    _pool = _pool select { _x isEqualType "" && {_x != ""} };
    if (_pool isEqualTo [] || {isNil "A3A_fnc_createUnit"}) exitWith { [false, "no occupant squads (A3A_faction_occ groupsMilitiaSquads)"] };

    private _players = call A3GM_fnc_players;
    private _pos = [];
    for "_i" from 1 to 20 do {
        private _p = _target getPos [500 + random 200, random 360];
        if (!surfaceIsWater _p && {(_players findIf { _x distance2D _p < 400 }) == -1}) exitWith { _pos = _p };
    };
    if (_pos isEqualTo []) exitWith { [false, "no spawn position on land"] };

    private _side = if (isNil "Occupants") then { west } else { Occupants };
    private _grp = createGroup [_side, true];
    for "_i" from 0 to _size - 1 do {
        private _unit = [_grp, _pool select (_i mod count _pool), _pos, [], 10, "FORM"] call A3A_fnc_createUnit;
        if (!isNil "_unit" && {!isNull _unit} && {!isNil "A3A_fnc_NATOinit"}) then { [_unit] call A3A_fnc_NATOinit };
    };
    if ((units _grp) isEqualTo []) exitWith { deleteGroup _grp; [false, "the occupant squad could not be created"] };
    _grp setBehaviour "AWARE";
    _grp setCombatMode "RED";
    private _wp = _grp addWaypoint [getPosATL _target, 50];
    _wp setWaypointType "SAD";

    // Clean up once the patrol is dead, or after 30 min when no player is close.
    [_grp] spawn {
        params ["_grp"];
        private _end = time + 1800;
        waitUntil {
            sleep 60;
            ({ alive _x } count units _grp) == 0 ||
            { time > _end && {((call A3GM_fnc_players) findIf { _x distance2D leader _grp < 1000 }) == -1} }
        };
        { deleteVehicle _x } forEach units _grp;
        deleteGroup _grp;
    };
    [true, format ["%1 men at grid %2 hunting %3", count units _grp, mapGridPosition _pos, name _target]]
};

// Battlefield snapshot for the Game Master. args: []
A3GM_fnc_status = {
    private _hostile = call A3GM_fnc_hostileSides;
    private _parts = (call A3GM_fnc_players) apply {
        private _n = count ((_x nearEntities ["CAManBase", 800]) select { alive _x && {side group _x in _hostile} });
        format ["%1@%2:%3", (name _x) call A3GM_fnc_clean, mapGridPosition _x, _n]
    };
    [true, _parts joinString ";"]
};

// "outpost_11" -> "Outpost 11" (same labels as openclaw-gm's adapter)
A3GM_fnc_zoneLabel = {
    private _parts = _this splitString "_";
    private _kind = createHashMapFromArray [["airport", "Airbase"], ["outpost", "Outpost"], ["resource", "Resource"],
        ["factory", "Factory"], ["seaport", "Seaport"], ["control", "Roadblock"], ["milbase", "Military base"]]
        getOrDefault [_parts select 0, _this];
    if (count _parts > 1 && {(_parts select 1) regexMatch "[0-9]+"}) then { format ["%1 %2", _kind, _parts select 1] } else { _kind }
};

A3GM_fnc_sideName = {
    switch (_this) do {
        case (missionNamespace getVariable ["Occupants", west]): { "Occupants" };
        case (missionNamespace getVariable ["Invaders", east]): { "Invaders" };
        case (missionNamespace getVariable ["teamPlayer", independent]): { "Rebels" };
        default { str _this };
    }
};

// One line per active Antistasi mission: "CON: Take the outpost (grid 102220, CREATED)"
A3GM_fnc_taskSummary = {
    private _id = _this;
    private _entry = (missionNamespace getVariable ["A3A_tasksData", []]) select { (_x select 0) isEqualTo _id };
    private _type = if (_entry isEqualTo []) then { "?" } else { _entry select 0 select 1 };
    private _state = if (_entry isEqualTo []) then { "" } else { _entry select 0 select 2 };
    private _title = _id;
    private _desc = [_id] call BIS_fnc_taskDescription;
    if (_desc isEqualType [] && {count _desc > 1}) then {
        _title = _desc select 1;
        if (_title isEqualType []) then { _title = _title param [0, _id] };
    };
    private _dest = [_id] call BIS_fnc_taskDestination;
    if (_dest isEqualType objNull) then { _dest = if (isNull _dest) then { [] } else { getPos _dest } };
    private _where = if (_dest isEqualType [] && {count _dest >= 2} && {(_dest select 0) isEqualType 0}) then {
        format ["grid %1", mapGridPosition _dest] } else { "no fixed location" };
    if !(_title isEqualType "") then { _title = str _title };
    format ["%1: %2 (%3, %4)", _type, _title, _where, _state]
};

// Intel for the Game Master's conversations. args: [player name]
A3GM_fnc_intel = {
    params [["_name", "", [""]]];
    private _p = [_name] call A3GM_fnc_target;
    if (isNull _p) exitWith { [false, "no such player"] };
    private _pos = getPosATL _p;
    private _parts = [format ["%1 is at grid %2", name _p, mapGridPosition _p]];
    private _towns = nearestLocations [_pos, ["NameCityCapital", "NameCity", "NameVillage"], 3000];
    if (_towns isNotEqualTo []) then {
        private _t = _towns select 0;
        _parts pushBack format ["nearest town %1 (%2 m, bearing %3)", text _t, round (_p distance2D locationPosition _t),
            round (_p getDir locationPosition _t)];
    };
    private _hostile = call A3GM_fnc_hostileSides;
    private _enemies = (_p nearEntities ["CAManBase", 800]) select { alive _x && {side group _x in _hostile} };
    if (_enemies isEqualTo []) then { _parts pushBack "no enemies within 800 m" } else {
        private _near = [_enemies, [_p], { _input0 distance2D _x }, "ASCEND"] call BIS_fnc_sortBy;
        private _e = _near select 0;
        _parts pushBack format ["%1 enemies within 800 m, closest %2 m bearing %3", count _enemies,
            round (_p distance2D _e), round (_p getDir _e)];
    };
    private _zones = [];
    {
        private _list = missionNamespace getVariable [_x, []];
        { _zones pushBack _x } forEach _list;
    } forEach ["outposts", "airportsX", "milbases", "resourcesX", "factories", "seaports"];
    private _sides = missionNamespace getVariable ["sidesX", objNull];
    private _enemyZones = _zones select {
        private _owner = if (isNull _sides) then { sideUnknown } else { _sides getVariable [_x, sideUnknown] };
        _owner in _hostile
    };
    _enemyZones = [_enemyZones, [_p], { _input0 distance2D markerPos _x }, "ASCEND"] call BIS_fnc_sortBy;
    private _zoneText = (_enemyZones select [0, 3]) apply {
        format ["%1 (%2) grid %3, %4 km bearing %5", _x call A3GM_fnc_zoneLabel, (_sides getVariable [_x, sideUnknown]) call A3GM_fnc_sideName,
            mapGridPosition markerPos _x, ((_p distance2D markerPos _x) / 1000) toFixed 1, round (_p getDir markerPos _x)]
    };
    if (_zoneText isNotEqualTo []) then { _parts pushBack ("nearest enemy zones: " + (_zoneText joinString "; ")) };
    private _tasks = (missionNamespace getVariable ["A3A_tasksData", []]) apply { (_x select 0) call A3GM_fnc_taskSummary };
    _parts pushBack (["active missions: none", "active missions: " + (_tasks joinString "; ")] select (_tasks isNotEqualTo []));
    // What HQ has to work with (Antistasi's own numbers), for "what's our funding / manpower?"
    private _server = missionNamespace getVariable ["server", objNull];
    if (!isNull _server) then {
        _parts pushBack format ["rebel HQ has %1 in funds and %2 recruits available, war level %3", round (_server getVariable ["resourcesFIA", 0]),
            round (_server getVariable ["hr", 0]), missionNamespace getVariable ["tierWar", 1]];
    };
    // The Mafia Syndicate (the A3UE Mafia extender), as far as the rebels know it
    if (!isNil "A3UE_mafiaFunds" && {!isNil "A3UE_fnc_mafiaStatus"}) then { _parts pushBack ([false] call A3UE_fnc_mafiaStatus) };
    [true, _parts joinString ". "]
};

// Nearest enemy-held Antistasi zones to a position. args: [pos, count] -> marker names
A3GM_fnc_enemyZones = {
    params ["_pos", ["_n", 3]];
    private _hostile = call A3GM_fnc_hostileSides;
    private _sides = missionNamespace getVariable ["sidesX", objNull];
    if (isNull _sides) exitWith { [] };
    private _zones = [];
    { _zones append (missionNamespace getVariable [_x, []]) } forEach ["outposts", "airportsX", "milbases", "resourcesX", "factories", "seaports"];
    _zones = _zones select { (_sides getVariable [_x, sideUnknown]) in _hostile };
    ([_zones, [_pos], { _input0 distance2D markerPos _x }, "ASCEND"] call BIS_fnc_sortBy) select [0, _n]
};

// ACE-aware condition of a player
A3GM_fnc_condition = {
    private _u = _this;
    if (!alive _u) exitWith { "dead" };
    if (_u getVariable ["ACE_isUnconscious", false] || {lifeState _u == "INCAPACITATED"}) exitWith { "unconscious" };
    if (_u getVariable ["ace_medical_woundBleeding", 0] > 0) exitWith { "bleeding" };
    if (damage _u > 0.25 || {_u getVariable ["ace_medical_bloodVolume", 6] < 5.5}) exitWith { "wounded" };
    "fit"
};

// Fields for the Game Master's sitrep: no "~" or ";" inside a field
A3GM_fnc_field = { (((str _this) splitString "~;") joinString " ") call A3GM_fnc_clean };

// Sitrep for the caller's area, every human player and the active missions. args: [player name]
//   local: grid~town~townM~townBrg~enemies~closestM~closestBrg~zone~zoneGrid~zoneM~zoneBrg~zoneOwner
//   players (;-separated): name~grid~condition~vehicle~enemiesWithin800m
//   missions (;-separated task summaries); the three sections are joined with "##"
A3GM_fnc_sitrep = {
    params [["_name", "", [""]]];
    private _p = [_name] call A3GM_fnc_target;
    if (isNull _p) exitWith { [false, "no such player"] };
    private _hostile = call A3GM_fnc_hostileSides;
    private _enemiesNear = { params ["_u"]; (_u nearEntities ["CAManBase", 800]) select { alive _x && {side group _x in _hostile} } };
    private _clean = { private _s = _this call A3GM_fnc_field; if ((_s select [0, 1]) == """") then { _s select [1, count _s - 2] } else { _s } };

    private _town = ["", 0, 0];
    private _towns = nearestLocations [getPosATL _p, ["NameCityCapital", "NameCity", "NameVillage"], 3000];
    if (_towns isNotEqualTo []) then {
        private _t = _towns select 0;
        _town = [text _t, round (_p distance2D locationPosition _t), round (_p getDir locationPosition _t)];
    };
    private _enemies = [_p] call _enemiesNear;
    private _closest = [0, 0];
    if (_enemies isNotEqualTo []) then {
        private _e = ([_enemies, [_p], { _input0 distance2D _x }, "ASCEND"] call BIS_fnc_sortBy) select 0;
        _closest = [round (_p distance2D _e), round (_p getDir _e)];
    };
    private _zone = ["", "", 0, 0, ""];
    private _z = [getPosATL _p, 1] call A3GM_fnc_enemyZones;
    if (_z isNotEqualTo []) then {
        private _m = _z select 0;
        _zone = [_m call A3GM_fnc_zoneLabel, mapGridPosition markerPos _m, round (_p distance2D markerPos _m),
            round (_p getDir markerPos _m), ((missionNamespace getVariable "sidesX") getVariable [_m, sideUnknown]) call A3GM_fnc_sideName];
    };
    private _local = ([mapGridPosition _p] + _town + [count _enemies] + _closest + _zone) apply { _x call _clean };

    private _players = ((allPlayers - entities "HeadlessClient_F") apply {
        private _veh = vehicle _x;
        private _vehName = if (_veh isEqualTo _x) then { "" } else { getText (configOf _veh >> "displayName") };
        ([name _x, mapGridPosition _x, _x call A3GM_fnc_condition, _vehName, count ([_x] call _enemiesNear)] apply { _x call _clean }) joinString "~"
    }) joinString ";";
    private _tasks = ((missionNamespace getVariable ["A3A_tasksData", []]) apply { ((_x select 0) call A3GM_fnc_taskSummary) splitString ";" joinString "," }) joinString ";";
    [true, ([_local joinString "~", _players, _tasks]) joinString "##"]
};

// Start an Antistasi mission the way Petros does. args: [type, player name]
A3GM_fnc_mission = {
    params [["_type", "RAN", [""]], ["_name", "", [""]]];
    _type = toUpper _type;
    if !(_type in ["AS", "CON", "DES", "LOG", "SUPP", "RES", "CONVOY", "RAN"]) exitWith { [false, "unknown mission type"] };
    if (isNil "A3A_fnc_missionRequest") exitWith { [false, "Antistasi mission requests unavailable"] };
    if (_type in (missionNamespace getVariable ["A3A_activeTasks", []])) exitWith { [false, format ["a %1 mission is already active", _type]] };
    private _petros = missionNamespace getVariable ["petros", objNull];
    if (isNull _petros || {leader group _petros != _petros}) exitWith { [false, "Petros is not commanding HQ"] };
    private _target = [_name] call A3GM_fnc_target;
    private _before = (missionNamespace getVariable ["A3A_tasksData", []]) apply { _x select 0 };
    [_type, [2, owner _target] select !(isNull _target), false] spawn A3A_fnc_missionRequest;
    private _end = time + 15;
    private _new = [];
    waitUntil {
        sleep 0.5;
        _new = ((missionNamespace getVariable ["A3A_tasksData", []]) apply { _x select 0 }) - _before;
        _new isNotEqualTo [] || {time > _end}
    };
    if (_new isEqualTo []) exitWith { [false, "HQ found no suitable target for that mission"] };
    [true, (_new select 0) call A3GM_fnc_taskSummary]
};

// Newcomer-friendly TFAR: the rebels' default handheld (AN/PRC-154) only reaches about 2 km. Unlock the
// 5 km AN/PRC-148 JEM and the 20 km AN/PRC-155 backpacks in the arsenal (unlimited, like any Antistasi
// unlock) and make the 148 JEM what TFAR hands out for "ItemRadio", server-forced.
A3GM_fnc_betterRadios = {
    if !(isClass (configFile >> "CfgPatches" >> "tfar_core")) exitWith {};
    private _unlocked = [];
    {
        if ((isClass (configFile >> "CfgWeapons" >> _x) || {isClass (configFile >> "CfgVehicles" >> _x)}) && {!isNil "A3A_fnc_unlockEquipment"}) then {
            [_x] call A3A_fnc_unlockEquipment;
            _unlocked pushBack _x;
        };
    } forEach ["TFAR_anprc148jem", "TFAR_anprc155", "TFAR_anprc155_coyote"];
    if (!isNil "CBA_settings_fnc_set") then {
        {
            _x params ["_setting", "_value"];
            [_setting, _value, 2, "server"] call CBA_settings_fnc_set;
        } forEach [
            ["TFAR_DefaultRadio_Rifleman_Independent", "TFAR_anprc148jem"],
            ["TFAR_DefaultRadio_Personal_Independent", "TFAR_anprc148jem"],
            ["TFAR_DefaultRadio_Backpack_Independent", "TFAR_anprc155"],
            // OVERLORD speaks by whispering into the TFAR channel from a TeamSpeak bot. Current TFAR plugins
            // (1.-1.0.341) hard-mute every TeamSpeak client that isn't in the game, so players heard nothing
            // (only an outdated plugin let it through). Without the automatic mute TFAR still decides who hears
            // whom, through voice volume instead (a little more CPU on each player's PC).
            ["TFAR_disableAutoMute", true]
        ];
    };
    diag_log text format ["A3GM|radios|unlocked %1; default handheld TFAR_anprc148jem; TFAR_disableAutoMute %2",
        _unlocked joinString ", ", missionNamespace getVariable ["TFAR_disableAutoMute", "?"]];
};

// MAPEXPORT: what a custom base map needs, logged once (a few minutes, run on an empty server):
//   A3MX|begin|world|size|cells                 heights grid: cells per side (16 m on Chernarus Redux)
//   A3MX|h|row|part|hex                          heights, rows south to north, 256 cells a part: 00 sea,
//                                                else 1 + height/1.5 m; then sea depth as A3MX|d (00 land, 1 + depth/1 m)
//   A3MX|f|row|hex                               tree density, 64 m cells: trees counted within 45 m (capped 255)
//   A3MX|r|type|x1|y1|x2|y2|width|bridge         one per road segment (getRoadInfo)
//   A3MX|b|x|y|dir|width|length|kind             one per building (terrain objects)
//   A3MX|end|roads|buildings|seconds
A3GM_fnc_mapExport = {
    if (!isNil "A3GM_exporting") exitWith { [false, "already exporting"] };
    A3GM_exporting = true;
    [] spawn {
        private _t0 = diag_tickTime;
        private _size = worldSize;
        private _n = round (_size / 16);
        private _step = _size / _n;
        private _digits = "0123456789abcdef" splitString "";
        private _hex = [];
        { private _hi = _x; { _hex pushBack (_hi + _x) } forEach _digits } forEach _digits;
        diag_log text format ["A3MX|begin|%1|%2|%3", worldName, _size, _n];
        for "_r" from 0 to _n - 1 do {
            private _y = (_r + 0.5) * _step;
            private _parts = ceil (_n / 256);
            for "_part" from 0 to _parts - 1 do {
                private _h = []; private _d = [];
                for "_c" from _part * 256 to (((_part + 1) * 256) min _n) - 1 do {
                    private _z = getTerrainHeightASL [(_c + 0.5) * _step, _y];
                    _h pushBack (_hex select ([0, 1 + (254 min round (_z / 1.5))] select (_z > 0)));
                    _d pushBack (_hex select ([0, 1 + (254 min round (- _z))] select (_z <= 0)));
                };
                diag_log text format ["A3MX|h|%1|%2|%3", _r, _part, _h joinString ""];
                diag_log text format ["A3MX|d|%1|%2|%3", _r, _part, _d joinString ""];
            };
            if (_r % 16 == 0) then { sleep 0.01 };
        };
        // trees, 64 m cells
        private _fn = round (_size / 64); private _fs = _size / _fn;
        for "_r" from 0 to _fn - 1 do {
            private _row = [];
            for "_c" from 0 to _fn - 1 do {
                private _k = count nearestTerrainObjects [[(_c + 0.5) * _fs, (_r + 0.5) * _fs], ["TREE", "SMALL TREE"], 45, false, true];
                _row pushBack (_hex select (_k min 255));
            };
            diag_log text format ["A3MX|f|%1|%2", _r, _row joinString ""];
            sleep 0.01;
        };
        // roads
        private _center = [_size / 2, _size / 2];
        private _roads = _center nearRoads (_size * 0.75);
        {
            private _i = getRoadInfo _x;
            _i params ["_type", "_width", "_ped", "", "", "", "_beg", "_end", "_bridge"];
            if (count _beg >= 2 && {count _end >= 2}) then {
                diag_log text format ["A3MX|r|%1|%2|%3|%4|%5|%6|%7", _type, round (_beg select 0), round (_beg select 1),
                    round (_end select 0), round (_end select 1), round _width, [0, 1] select _bridge];
            };
            if (_forEachIndex % 500 == 0) then { sleep 0.01 };
        } forEach _roads;
        // buildings
        private _kinds = ["BUILDING", "HOUSE", "CHURCH", "CHAPEL", "FUEL STATION", "HOSPITAL", "LIGHTHOUSE", "FORTRESS",
            "BUNKER", "POWER LINES", "TRANSMITTER", "WATERTOWER", "RUIN", "VIEW-TOWER", "POWERSOLAR", "POWERWIND", "SHIPWRECK"];
        private _blds = nearestTerrainObjects [_center, _kinds - ["POWER LINES"], _size * 0.75, false, true];
        {
            private _bb = boundingBoxReal _x;
            private _w = abs (((_bb select 1) select 0) - ((_bb select 0) select 0));
            private _l = abs (((_bb select 1) select 1) - ((_bb select 0) select 1));
            if (_w > 2 && {_l > 2} && {_w < 200} && {_l < 200}) then {
                private _p = getPosWorld _x;
                diag_log text format ["A3MX|b|%1|%2|%3|%4|%5|%6", round (_p select 0), round (_p select 1), round getDir _x,
                    round _w, round _l, (getModelInfo _x) select 0];
            };
            if (_forEachIndex % 500 == 0) then { sleep 0.01 };
        } forEach _blds;
        diag_log text format ["A3MX|end|%1|%2|%3", count _roads, count _blds, round (diag_tickTime - _t0)];
        A3GM_exporting = nil;
    };
    [true, "map export started"]
};

// The map's grid convention, for the Game Master's targeting: mapGridPosition at known positions
A3GM_fnc_gridInfo = {
    private _probe = [[50, 50], [1050, 50], [50, 1050], [worldSize - 50, worldSize - 50]];
    [true, format ["%1 size %2 %3", worldName, worldSize,
        (_probe apply { format ["%1,%2=%3", _x select 0, _x select 1, mapGridPosition _x] }) joinString " "]]
};

// Make Steam IDs campaign members, the way Antistasi's own "add member" does (membersX, saved with the campaign).
// Accepted before the campaign loads: the IDs are added as soon as it has.
A3GM_fnc_members = {
    private _uids = _this select { _x isEqualType "" && {_x regexMatch "\d{17}"} };
    if (_uids isEqualTo []) exitWith { [false, "no Steam IDs"] };
    private _add = {
        params ["_uids"];
        private _new = _uids select { !(_x in membersX) };
        { membersX pushBackUnique _x } forEach _new;
        publicVariable "membersX";
        { if (getPlayerUID _x in _uids) then { _x setVariable ["eligible", true, true] } } forEach allPlayers;
        diag_log text format ["A3GM|members|%1 added, %2 members%3", count _new, count membersX,
            ["", " (membership is off in this campaign)"] select !(missionNamespace getVariable ["membershipEnabled", true])];
        count _new
    };
    if (missionNamespace getVariable ["serverInitDone", false] && {!isNil "membersX"}) exitWith {
        [true, format ["%1 of %2 added", [_uids] call _add, count _uids]]
    };
    [_uids, _add] spawn {
        params ["_uids", "_add"];
        waitUntil { sleep 5; missionNamespace getVariable ["serverInitDone", false] && {!isNil "membersX"} };
        [_uids] call _add;
    };
    [true, format ["%1 queued until the campaign loads", count _uids]]
};

// The Mafia Syndicate, when the A3UE Mafia extender is loaded. [sub, arg]:
//   status | relocate | racket <town or ""> | reveal | hit <player or ""> | funds <amount> | playable <on|off>
A3GM_fnc_mafia = {
    params [["_sub", "status", [""]], ["_arg", "", [""]]];
    if (isNil "A3UE_fnc_mafiaCommand") exitWith { [false, "the Mafia extender isn't loaded"] };
    [_sub, _arg] call A3UE_fnc_mafiaCommand
};

A3GM_actions = createHashMapFromArray [
    ["SAY", A3GM_fnc_say],
    ["AIRDROP", A3GM_fnc_airdrop],
    ["MORTAR", A3GM_fnc_mortar],
    ["WEATHER", A3GM_fnc_weather],
    ["QRF", A3GM_fnc_qrf],
    ["STATUS", A3GM_fnc_status],
    ["INTEL", A3GM_fnc_intel],
    ["MISSION", A3GM_fnc_mission],
    ["SITREP", A3GM_fnc_sitrep],
    ["AIRSTRIKE", A3GM_fnc_airstrike],
    ["MARK", A3GM_fnc_mark],
    ["UNMARK", A3GM_fnc_unmark],
    ["MEDEVAC", A3GM_fnc_medevac],
    ["BACKUP", A3GM_fnc_backup],
    ["UAV", A3GM_fnc_uav],
    ["TRANSPORT", A3GM_fnc_transport],
    ["GUNSHIP", A3GM_fnc_gunship],
    ["FIREMISSION", A3GM_fnc_fireMission],
    ["ILLUM", A3GM_fnc_illum],
    ["SMOKE", A3GM_fnc_smoke],
    ["CANCEL", A3GM_fnc_cancel],
    ["GRIDINFO", A3GM_fnc_gridInfo],
    ["MAPEXPORT", A3GM_fnc_mapExport],
    ["MEMBERS", A3GM_fnc_members],
    ["MAFIA", A3GM_fnc_mafia]
];

// Chat relay. Each player's client sends the chat its own player types here; the sender comes
// from remoteExecutedOwner, so a client can't post under someone else's name. One line per message:
//   A3CHAT|channel|side|name|text      channel: 0 global 1 side 2 command 3 group 4 vehicle 5 direct
A3GM_chatLast = createHashMap;
A3GM_fnc_chatIn = {
    params [["_channel", -1, [0]], ["_text", "", [""]]];
    private _from = remoteExecutedOwner;
    private _idx = allPlayers findIf { owner _x == _from };
    if (_idx < 0 || {_text isEqualTo ""}) exitWith {};
    if (time - (A3GM_chatLast getOrDefault [_from, -10]) < 1) exitWith {};
    A3GM_chatLast set [_from, time];
    private _unit = allPlayers select _idx;
    _text = ((_text splitString toString [10, 13]) joinString " ") select [0, 300];
    diag_log text format ["A3CHAT|%1|%2|%3|%4", _channel, side group _unit,
        (name _unit) call A3GM_fnc_clean, _text call A3GM_fnc_clean];
};

// AI talk the players see: Antistasi HQ messages and AI squad callouts (Side, Command, Group).
// Every client in the squad/side reports the same line, so repeats within 10 s are dropped.
//   A3AICHAT|channel|side|speaker|text[|@x,y,dir]
// The speaker's position and facing (when it's a unit in the reporting player's group) let the Game Master
// put callouts like "Contact - infantry - 300m - South" on the battle net.
A3GM_aiSeen = createHashMap;
A3GM_fnc_aiChatIn = {
    params [["_channel", -1, [0]], ["_text", "", [""]], ["_speaker", "", [""]]];
    private _from = remoteExecutedOwner;
    private _idx = allPlayers findIf { owner _x == _from };
    if (_idx < 0 || {_text isEqualTo ""} || {_channel < 1 || _channel > 3}) exitWith {};
    if ((_text find "OVERLORD:") == 0 || {(_text find "[HQ] OVERLORD") == 0}) exitWith {};
    private _key = format ["%1|%2|%3", _channel, _speaker, _text];
    if (time - (A3GM_aiSeen getOrDefault [_key, -100]) < 10) exitWith {};
    if (count A3GM_aiSeen > 500) then { A3GM_aiSeen = createHashMap };
    A3GM_aiSeen set [_key, time];
    _text = ((_text splitString toString [10, 13]) joinString " ") select [0, 300];
    private _player = allPlayers select _idx;
    private _where = "";
    private _unit = (units group _player) select { name _x == _speaker };
    if (_unit isNotEqualTo []) then {
        private _u = _unit select 0;
        _where = format ["|@%1,%2,%3", round ((getPosATL _u) select 0), round ((getPosATL _u) select 1), round (getDir _u)];
    };
    diag_log text format ["A3AICHAT|%1|%2|%3|%4%5", _channel, side group _player,
        (_speaker select [0, 60]) call A3GM_fnc_clean, _text call A3GM_fnc_clean, _where];
};

// Clients confirm the hook, and (while A3GM_chatTrace is on) describe each chat line they see, so
// the server log shows what HandleChatMessage reports on a real client.
A3GM_fnc_chatAck = {
    params [["_what", "", [""]]];
    private _from = remoteExecutedOwner;
    private _idx = allPlayers findIf { owner _x == _from };
    private _who = if (_idx < 0) then { format ["owner %1", _from] } else { name (allPlayers select _idx) };
    diag_log text format ["A3GM|chat %1|%2", _who call A3GM_fnc_clean, (_what select [0, 200]) call A3GM_fnc_clean];
};

// TFAR radio key presses, so the Game Master can tell who is talking on the radio on TeamSpeak.
//   A3RADIO|name|sw|lr|down|up
A3GM_fnc_radioKey = {
    params [["_lr", false, [false]], ["_down", false, [false]]];
    private _from = remoteExecutedOwner;
    private _idx = allPlayers findIf { owner _x == _from };
    if (_idx < 0) exitWith {};
    diag_log text format ["A3RADIO|%1|%2|%3", (name (allPlayers select _idx)) call A3GM_fnc_clean,
        ["sw", "lr"] select _lr, ["up", "down"] select _down];
};

// Runs on every client (and JIP); the addon itself is server-only.
A3GM_fnc_chatHook = {
    diag_log text format ["A3GM|chat hook received (interface=%1)", hasInterface];
    if (!hasInterface) exitWith {};
    if (!isNil "A3GM_chatEH") then { removeMissionEventHandler ["HandleChatMessage", A3GM_chatEH] };
    A3GM_chatEH = addMissionEventHandler ["HandleChatMessage", {
        params ["_channel", "_owner", "_from", "_text", "_person", "_name", "_strID", "_forcedDisplay", "_isPlayerMessage"];
        if (missionNamespace getVariable ["A3GM_chatTrace", false]) then {
            [format ["trace me=%1 player=%2 %3", clientOwner, name player, str _this]] remoteExecCall ["A3GM_fnc_chatAck", 2];
        };
        // On a dedicated server the sender's own lines arrive without the player flag or person, so
        // fall back to the sender name.
        private _fromName = if (_from isEqualType "") then { _from } else { "" };
        private _mine = _isPlayerMessage && {_owner == clientOwner} || {_person isEqualTo player}
            || {_fromName != "" && {_fromName == name player}};
        private _byPlayer = _mine || _isPlayerMessage || {!isNull _person && {isPlayer _person}}
            || {_fromName != "" && {(allPlayers findIf { name _x == _fromName }) >= 0}};
        if (_byPlayer) then {
            if (_mine && {_channel >= 0 && _channel <= 5}) then {
                [_channel, _text] remoteExecCall ["A3GM_fnc_chatIn", 2];
            };
        } else {
            if (_channel >= 1 && {_channel <= 3}) then {
                [_channel, _text, [_name, _fromName] select (_name isEqualTo "")] remoteExecCall ["A3GM_fnc_aiChatIn", 2];
            };
        };
        false // anything else would hide or rewrite the message
    }];
    if (!isNil "TFAR_fnc_addEventHandler") then {
        // Global handler (objNull filter), so it survives respawns. args: [unit, radio, type 0 SW / 1 LR, additional, down]
        ["A3GM_tangent", "OnTangent", {
            params ["_unit", "_radio", "_radioType", "_additional", "_down"];
            if (_unit isEqualTo player) then { [_radioType == 1, _down] remoteExecCall ["A3GM_fnc_radioKey", 2] };
        }, objNull] call TFAR_fnc_addEventHandler;
    };
    ["hook installed"] remoteExecCall ["A3GM_fnc_chatAck", 2];
};
A3GM_chatTrace = false; publicVariable "A3GM_chatTrace";  // true: every client describes each chat line it sees (debugging the relay)
[[], A3GM_fnc_chatHook] remoteExec ["spawn", -2, "A3GM_chatHook"];

[] spawn {
    // Antistasi's own server init has to finish first (factions, sides).
    // Commands are taken at once; game actions wait for the campaign (Antistasi loads it when the first player
    // joins), only these work before: chat, the grid convention, the map export, members (queued).
    private _preInit = ["SAY", "GRIDINFO", "MAPEXPORT", "MEMBERS"];
    private _slow = ["MISSION"];  // these wait for the game (up to 15 s): run beside the queue, not in it
    private _run = {
        params ["_id", "_action", "_args", "_fn"];
        private _res = _args call _fn;
        if (isNil "_res" || {!(_res isEqualType [])} || {count _res < 2}) then { _res = [false, "no result"] };
        _res params [["_ok", false, [false]], ["_detail", ""]];
        if !(_detail isEqualType "") then { _detail = str _detail };
        diag_log text format ["A3GM|done|%1|%2|%3|%4", _id call A3GM_fnc_clean, _action,
            ["fail", "ok"] select _ok, _detail call A3GM_fnc_clean];
    };
    private _readyLogged = false;
    diag_log text "A3GM|listening";
    while { true } do {
        if (!_readyLogged && {missionNamespace getVariable ["serverInitDone", false]}) then {
            _readyLogged = true;
            call A3GM_fnc_betterRadios;
            diag_log text "A3GM|ready";
        };
        private _raw = "a3gm" callExtension "poll";
        if (_raw isEqualTo "") then {
            sleep 0.1;  // commands are picked up within 0.1 s; the extension call is cheap
        } else {
            private _cmd = parseSimpleArray _raw;
            _cmd params [["_id", "?", [""]], ["_action", "", [""]], ["_args", [], [[]]]];
            _action = toUpper _action;
            private _fn = A3GM_actions getOrDefault [_action, {}];
            if !(_action in A3GM_actions) then { _fn = { [false, "unknown action"] } } else {
                if (!_readyLogged && {!(_action in _preInit)}) then {
                    _fn = { [false, "the campaign hasn't started yet: it loads when the first player joins"] };
                };
            };
            if (_action in _slow) then { [_id, _action, _args, _fn] spawn _run } else { [_id, _action, _args, _fn] call _run };
        };
    };
};

diag_log text "A3GM|installed";
