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
    };
    [true, format ["%1 for %2 near grid %3", _class, name _target, mapGridPosition _pos]]
};

// Friendly mortar mission on enemies near a player, never within 200 m of any player.
// args: [player name or "", rounds 1-6]
A3GM_fnc_mortar = {
    params [["_name", "", [""]], ["_rounds", 4, [0]]];
    _rounds = 1 max (round _rounds min 6);
    private _target = [_name] call A3GM_fnc_target;
    if (isNull _target) exitWith { [false, "no player"] };
    private _players = call A3GM_fnc_players;
    private _hostile = call A3GM_fnc_hostileSides;
    private _enemies = (_target nearEntities [["CAManBase", "LandVehicle"], 800]) select {
        alive _x && {side group _x in _hostile} && {!isPlayer _x} &&
        { private _e = _x; (_players findIf { _x distance2D _e < 200 }) == -1 }
    };
    if (_enemies isEqualTo []) exitWith { [false, "no enemies 200-800 m from players"] };
    private _aim = getPosATL (selectRandom _enemies);
    [_aim, _rounds] spawn {
        params ["_aim", "_rounds"];
        sleep 10;
        for "_i" from 1 to _rounds do {
            private _p = _aim getPos [random 35, random 360];
            _p set [2, 150];
            private _shell = createVehicle ["Sh_82mm_AMOS", _p, [], 0, "CAN_COLLIDE"];
            _shell setVelocity [0, 0, -80];
            sleep (2 + random 2);
        };
    };
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
// 200 m of any player (danger close) or off the map.
A3GM_fnc_airstrike = {
    params [["_grid", "", [""]], ["_name", "", [""]]];
    _grid = (_grid splitString " ,.-") joinString "";
    private _pos = _grid call A3GM_fnc_gridPos;
    if (_pos isEqualType "") exitWith { [false, _pos] };
    private _close = (call A3GM_fnc_players) select { _x distance2D _pos < 200 };
    if (_close isNotEqualTo []) exitWith {
        [false, format ["danger close: %1 within 200 m of grid %2", (_close apply { name _x }) joinString ", ", _grid]] };

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

// The available classes from a list, the given side's own first (I_ independent, B_ west, O_ east)
A3GM_fnc_sideClasses = {
    params ["_classes", "_side"];
    private _prefix = ["I_", "B_", "O_"] select (([independent, west, east] find _side) max 0);
    private _ok = _classes select { isClass (configFile >> "CfgVehicles" >> _x) };
    (_ok select { (_x select [0, 2]) == _prefix }) + (_ok select { (_x select [0, 2]) != _prefix })
};

// The player a support asset is for; "@<grid>" makes a stand-in casualty there (a wounded rebel, removed after
// 20 min) so the flights can be tested on an empty server
A3GM_fnc_supportTarget = {
    params ["_name"];
    private _players = call A3GM_fnc_players;
    private _idx = _players findIf { name _x == _name };
    if (_idx >= 0) exitWith { _players select _idx };
    if ((_name select [0, 1]) != "@") exitWith { objNull };
    private _pos = (_name select [1]) call A3GM_fnc_gridPos;
    if (_pos isEqualType "") exitWith { objNull };
    private _grp = createGroup [missionNamespace getVariable ["teamPlayer", independent], true];
    private _u = _grp createUnit ["I_G_Soldier_F", _pos, [], 0, "NONE"];
    _u setDamage 0.5;
    _u disableAI "PATH";
    _u setVariable ["A3GM_standin", true];  // boards a landed helicopter by itself (it can't walk to it)
    [_u] spawn { sleep 1200; deleteVehicle (_this select 0) };
    diag_log text format ["A3GM|test|stand-in at %1", mapGridPosition _u];
    _u
};

// Support assets by id, so a caller can cancel ("Overlord, cancel the pickup")
A3GM_supportAssets = createHashMap;
A3GM_fnc_cancelled = { params ["_id"]; (A3GM_supportAssets getOrDefault [_id, [false]]) select 0 };
// args: [id]
A3GM_fnc_cancel = {
    params [["_id", "", [""]]];
    private _entry = A3GM_supportAssets getOrDefault [_id, []];
    if (_entry isEqualTo []) exitWith { [false, "nothing to cancel"] };
    _entry set [0, true];
    { _x setVariable ["A3GM_cancel", true] } forEach (_entry select 1);
    { if (alive _x && {_x isKindOf "Air"}) then { [_x, getPos _x] spawn A3GM_fnc_medevacLeave } } forEach (_entry select 1);
    [true, format ["cancelled %1", _id]]
};

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
    private _lz = [_center, 0, _radius, 12, 0, 0.35, 0, [], [_center, _center]] call BIS_fnc_findSafePos;
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
    _grp move _lz;
    _heli flyInHeight 70;
    private _end = time + _timeout;
    private _diag = [_heli, _lz] spawn {  // flight diagnostics every 15 s (A3GM|diag|...)
        params ["_heli", "_lz"];
        while { alive _heli } do {
            private _grp = group driver _heli;
            diag_log text format ["A3GM|diag|heli %1 at %2 dist %3 alt %4 speed %5 ground %6 leader %7 (%8) cmd %9 wps %10 ready %11",
                typeOf _heli, mapGridPosition _heli, round (_heli distance2D _lz), round ((getPosATL _heli) select 2),
                round speed _heli, isTouchingGround _heli, name leader _grp, assignedVehicleRole (leader _grp),
                currentCommand driver _heli, count waypoints _grp, unitReady driver _heli];
            sleep 15;
        };
    };
    waitUntil { sleep 1; !alive _heli || {!alive driver _heli} || {time > _end} || {_heli distance2D _lz < 250}
        || {_heli getVariable ["A3GM_cancel", false]} };
    if (alive _heli && {alive driver _heli} && {time <= _end}) then {
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
    private _down = alive _heli && {alive driver _heli} && {isTouchingGround _heli || {((getPosATL _heli) select 2) < 1.5}};
    if (_down) then {
        // Parked: the pilot can't lift off (a "GET IN" landing climbs out again when someone outside the crew
        // walks up), and anyone may board
        driver _heli disableAI "MOVE";
        _heli lock 0;
        _heli lockCargo false;
        _heli setVariable ["A3GM_parked", true];
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
        if (_target getVariable ["A3GM_standin", false] && {vehicle _target != _heli} && {_target distance2D _heli < 300}) then {
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

A3GM_fnc_medevac = {
    params [["_id", "", [""]], ["_name", "", [""]], ["_mode", "auto", [""]]];
    private _target = [_name] call A3GM_fnc_supportTarget;
    if (isNull _target) exitWith { [false, "no such player"] };
    private _class = [A3GM_medevacHelis, side group _target] call A3GM_fnc_sideClasses param [0, ""];
    if (_class == "") exitWith { [false, "no medevac helicopter available"] };
    private _hq = markerPos "Synd_HQ";
    if (_hq isEqualTo [0, 0, 0]) then { _hq = _target getPos [3000, random 360] };
    _mode = toLower _mode;
    if (_mode == "auto") then { _mode = ["extract", "revive"] select ((_target call A3GM_fnc_condition) != "fit") };
    if (_mode == "extract" && {_target distance2D _hq < 400}) exitWith { [false, "you're already at HQ"] };

    // Launch from HQ if it's within 6 km, else 3 km out on the HQ side
    private _start = if (_target distance2D _hq < 6000) then { _hq } else { _target getPos [3000, _target getDir _hq] };
    _start = [_start select 0, _start select 1, 150];
    private _side = side group _target;
    private _heli = createVehicle [_class, _start, [], 0, "FLY"];
    _heli setPosATL _start;
    _heli setDir (_start getDir _target);
    _heli setVelocityModelSpace [0, 40, 0];
    private _grp = createGroup [_side, true];
    createVehicleCrew _heli;
    (crew _heli) joinSilent _grp;
    _grp setBehaviour "CARELESS";
    _grp setCombatMode "BLUE";  // a medevac doesn't pick fights
    _heli lockCargo false;
    private _eta = round ((_start distance2D _target) / 55 + 40);
    A3GM_supportAssets set [_id, [false, [_heli]]];
    [_id, "launched", _target, format ["%1 %2 eta %3", _class, _mode, _eta]] call A3GM_fnc_medevacLog;

    [_id, _target, _heli, _mode, _hq] spawn {
        params ["_id", "_target", "_heli", "_mode", "_hq"];
        private _lz = [getPos _target] call A3GM_fnc_medevacLZ;
        private _smoke = createVehicle ["SmokeShellGreen", _lz, [], 0, "CAN_COLLIDE"];
        [_id, "landing", _target, mapGridPosition _lz] call A3GM_fnc_medevacLog;
        if !([_heli, _lz] call A3GM_fnc_medevacLand) exitWith {
            [_id, "failed", _target, ["could not land", "lost"] select (!alive _heli)] call A3GM_fnc_medevacLog;
            [_heli, _lz] call A3GM_fnc_medevacLeave;
        };
        [_id, "landed", _target, mapGridPosition _heli] call A3GM_fnc_medevacLog;

        if (_mode == "revive") exitWith {
            sleep 8;  // the medic gets out to them
            private _treated = (call A3GM_fnc_players) select { _x distance2D _heli < 60 && {(_x call A3GM_fnc_condition) != "fit"} };
            if (_target distance2D _heli < 120) then { _treated pushBackUnique _target };
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
            !alive _heli || {!alive _target} || {vehicle _target == _heli} || {time > _end}
        };
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
        if !([_heli, _hqLz, 600] call A3GM_fnc_medevacLand) exitWith {
            [_id, "failed", _target, ["could not land at HQ", "lost"] select (!alive _heli)] call A3GM_fnc_medevacLog;
            [_heli, _lz] call A3GM_fnc_medevacLeave;
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
    params ["_target", "_side"];
    private _class = [A3GM_medevacHelis, _side] call A3GM_fnc_sideClasses param [0, ""];
    if (_class == "") exitWith { objNull };
    private _hq = [_target] call A3GM_fnc_rebelHQ;
    private _start = if (_target distance2D _hq < 6000) then { _hq } else { _target getPos [3000, _target getDir _hq] };
    _start = [_start select 0, _start select 1, 150];
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

// A rebel squad from Antistasi's rebel templates (vanilla guerrillas if they're missing)
A3GM_fnc_rebelSquad = {
    params ["_side", "_pos", ["_n", 6]];
    private _grp = createGroup [_side, true];
    private _isReb = _side == (missionNamespace getVariable ["teamPlayer", independent]);
    private _reb = if (_isReb) then { missionNamespace getVariable ["A3A_faction_reb", createHashMap] } else { createHashMap };
    private _prefix = ["I_G_", "B_", "O_"] select (([independent, west, east] find _side) max 0);
    private _types = ["unitSL", "unitMG", "unitRifle", "unitLAT", "unitMedic", "unitRifle", "unitGL", "unitRifle"]
        apply { _reb getOrDefault [_x, ""] } select [0, _n];
    {
        private _u = objNull;
        if (_x isNotEqualTo "" && {!isNil "A3A_fnc_createUnit"}) then {
            _u = [_grp, _x, _pos, [], 5, "NONE"] call A3A_fnc_createUnit;
        };
        if (isNil "_u" || {isNull _u}) then {
            _u = _grp createUnit [_prefix + (["Soldier_SL_F", "Soldier_AR_F", "Soldier_F", "Soldier_LAT_F", "medic_F",
                "Soldier_F", "Soldier_GL_F", "Soldier_F"] select (_forEachIndex min 7)), _pos, [], 5, "NONE"];
        };
    } forEach _types;
    _grp setBehaviour "AWARE";
    _grp setCombatMode "RED";
    _grp
};

// The squad sticks with the player for 15 minutes, then is removed once no player is near
A3GM_fnc_backupEscort = {
    params ["_asset", "_id", "_target", "_grp", ["_vehicles", []]];
    if (_vehicles isEqualType objNull) then { _vehicles = [_vehicles] };
    private _end = time + 900;
    while { time < _end && {({ alive _x } count units _grp) > 0} } do {
        if (alive _target) then { _grp move (_target getPos [15, random 360]) };
        sleep 20;
    };
    [_asset, _id, ["done", "lost"] select (({ alive _x } count units _grp) == 0), _target, ""] call A3GM_fnc_supportLog;
    waitUntil { sleep 10; ((call A3GM_fnc_players) findIf { _x distance2D (leader _grp) < 1200 }) < 0 || {({ alive _x } count units _grp) == 0} };
    { deleteVehicle _x } forEach units _grp;
    { if (!isNull _x && {(crew _x) findIf { isPlayer _x } < 0}) then { deleteVehicle _x } } forEach _vehicles;
    deleteGroup _grp;
};

// BACKUP: a rebel squad, by helicopter or by road (random; "air" / "road" to choose). args: [id, player name, how]
A3GM_fnc_backup = {
    params [["_id", "", [""]], ["_name", "", [""]], ["_how", "", [""]]];
    private _target = [_name] call A3GM_fnc_supportTarget;
    if (isNull _target) exitWith { [false, "no such player"] };
    private _side = side group _target;
    private _hq = [_target] call A3GM_fnc_rebelHQ;
    private _reb = missionNamespace getVariable ["A3A_faction_reb", createHashMap];
    // the rebels' own vehicles when the caller is a rebel, else that side's light vehicles
    private _cars = if (_side == (missionNamespace getVariable ["teamPlayer", independent])) then {
        ((_reb getOrDefault ["vehiclesLightArmed", []]) + (_reb getOrDefault ["vehiclesLightUnarmed", []])
            + ["I_G_Offroad_01_armed_F", "I_G_Offroad_01_F"]) select { _x isEqualType "" && {isClass (configFile >> "CfgVehicles" >> _x)} }
    } else {
        [["B_G_Offroad_01_armed_F", "B_MRAP_01_hmg_F", "O_G_Offroad_01_armed_F", "O_MRAP_02_hmg_F", "I_MRAP_03_hmg_F"], _side]
            call A3GM_fnc_sideClasses
    };
    // Candidate roads 1.2-1.6 km out, the HQ side first. Some roads lead nowhere (a fenced airfield, a dead end):
    // the vehicle is moved to the next one if it doesn't get going, and flown in after the last.
    private _roads = [];
    {
        private _a = _x;
        {
            private _r = [_target getPos [_x, (_target getDir _hq) + _a], 300] call BIS_fnc_nearestRoad;
            if (!isNull _r && {(_roads findIf { _x distance2D _r < 300 }) < 0}) then { _roads pushBack _r };
        } forEach [1500, 1200];
    } forEach [0, 45, -45, 90, -90, 180];
    private _road = _roads param [0, objNull];
    private _byAir = ((random 1 < 0.5 && {_how != "road"}) || {_how == "air"} || {_cars isEqualTo []} || {isNull _road})
        && {([A3GM_medevacHelis, _side] call A3GM_fnc_sideClasses) isNotEqualTo []};
    if (!_byAir && {_cars isEqualTo [] || {isNull _road}}) exitWith { [false, "no transport for backup"] };

    if (_byAir) exitWith {
        private _heli = [_target, _side] call A3GM_fnc_spawnHeli;
        private _squad = [_side, getPos _heli, 6] call A3GM_fnc_rebelSquad;
        { _x moveInCargo _heli } forEach units _squad;
        private _eta = round ((_heli distance2D _target) / 55 + 40);
        ["backup", _id, "launched", _target, format ["helicopter %1 eta %2", count units _squad, _eta]] call A3GM_fnc_supportLog;
        [_id, _target, _heli, _squad] spawn {
            params ["_id", "_target", "_heli", "_squad"];
            private _lz = [_target getPos [120, random 360], 150] call A3GM_fnc_medevacLZ;
            createVehicle ["SmokeShellGreen", _lz, [], 0, "CAN_COLLIDE"];
            if !([_heli, _lz] call A3GM_fnc_medevacLand) exitWith {
                ["backup", _id, "lost", _target, "helicopter"] call A3GM_fnc_supportLog;
                [_heli, _lz] call A3GM_fnc_medevacLeave;
            };
            [_heli] call A3GM_fnc_heliUnload;
            ["backup", _id, "arrived", _target, mapGridPosition _lz] call A3GM_fnc_supportLog;
            [_heli, _lz] call A3GM_fnc_medevacLeave;
            ["backup", _id, _target, _squad] call A3GM_fnc_backupEscort;
        };
        [true, format ["helicopter %1 %2", 6, mapGridPosition _target]]
    };

    private _class = selectRandom _cars;
    private _spawn = getPos _road;
    private _car = createVehicle [_class, _spawn, [], 0, "NONE"];
    _car setDir (_spawn getDir _target);
    private _squad = [_side, _spawn getPos [8, 0], [5, 6] select ((_car emptyPositions "cargo") >= 5)] call A3GM_fnc_rebelSquad;
    private _units = units _squad;
    (_units select 0) moveInDriver _car;
    if (_car emptyPositions "gunner" > 0 && {count _units > 1}) then { (_units select 1) moveInGunner _car };
    { if (vehicle _x == _x) then { _x moveInCargo _car } } forEach _units;
    // the rest ride in a second, unarmed vehicle (an armed technical seats few)
    private _left = _units select { vehicle _x == _x };
    private _car2 = objNull;
    if (_left isNotEqualTo []) then {
        private _unarmed = ((_reb getOrDefault ["vehiclesLightUnarmed", []]) + (_reb getOrDefault ["vehiclesTruck", []])
            + ["I_G_Offroad_01_F", "I_G_Van_01_transport_F"]) select { _x isEqualType "" && {isClass (configFile >> "CfgVehicles" >> _x)} };
        if (_unarmed isNotEqualTo []) then {
            _car2 = createVehicle [selectRandom _unarmed, _spawn getPos [15, (_spawn getDir _target) + 180], [], 5, "NONE"];
            _car2 setDir (_spawn getDir _target);
            (_left select 0) moveInDriver _car2;
            { if (vehicle _x == _x) then { _x moveInCargo _car2 } } forEach _left;
        };
    };
    { if (vehicle _x == _x) then { deleteVehicle _x } } forEach _units;  // still no seat: don't leave them walking
    _squad setBehaviour "SAFE";
    private _eta = round ((_car distance2D _target) / 12 + 20);
    ["backup", _id, "launched", _target, format ["%1 %2 eta %3", getText (configFile >> "CfgVehicles" >> _class >> "displayName"),
        count units _squad, _eta]] call A3GM_fnc_supportLog;
    [_id, _target, _car, _squad, _car2, _roads] spawn {
        params ["_id", "_target", "_car", "_squad", "_car2", "_roads"];
        sleep 2;  // seated first: a move order given at spawn gets dropped
        _squad selectLeader (driver _car);  // a leader in the back seat stops the driver
        private _wp = _squad addWaypoint [getPos _target, 20];
        _wp setWaypointType "MOVE";
        _wp setWaypointSpeed "FULL";
        _squad setCurrentWaypoint _wp;
        // Not moving after 15 s: no route from this road. Try the next one, then fly them in.
        private _rolling = false;
        {
            private _from = getPos _car;
            sleep 15;
            if (_car distance2D _from > 15 || {!alive _car}) exitWith { _rolling = true };
            private _p = getPos _x;
            private _dir = _p getDir _target;
            _car setDir _dir; _car setPos _p;
            if (!isNull _car2) then { _car2 setDir _dir; _car2 setPos (_p getPos [15, _dir + 180]) };
            _wp setWaypointPosition [getPos _target, 20];
            _squad setCurrentWaypoint _wp;
            driver _car doMove (getPos _target);
            diag_log text format ["A3GM|diag|backup %1 no route from there: trying the road at %2", _id, mapGridPosition _p];
        } forEach (_roads select [1, 4]);
        if (!_rolling && {alive _car} && {_car distance2D _target > 400}) then {
            private _from = getPos _car;
            sleep 15;
            _rolling = _car distance2D _from > 15;
        };
        if (!_rolling && {alive _car} && {_car distance2D _target > 400}) exitWith {
            private _heli = [_target, side _squad] call A3GM_fnc_spawnHeli;
            if (isNull _heli) exitWith { ["backup", _id, "lost", _target, "no route"] call A3GM_fnc_supportLog };
            { unassignVehicle _x; moveOut _x; _x moveInCargo _heli } forEach units _squad;
            { if (!isNull _x) then { deleteVehicle _x } } forEach [_car, _car2];
            diag_log text format ["A3GM|diag|backup %1 no road route: flying them in", _id];
            private _lz = [_target getPos [120, random 360], 150] call A3GM_fnc_medevacLZ;
            if !([_heli, _lz] call A3GM_fnc_medevacLand) exitWith {
                ["backup", _id, "lost", _target, "helicopter"] call A3GM_fnc_supportLog;
                [_heli, _lz] call A3GM_fnc_medevacLeave;
            };
            [_heli] call A3GM_fnc_heliUnload;
            ["backup", _id, "arrived", _target, mapGridPosition _lz] call A3GM_fnc_supportLog;
            [_heli, _lz] call A3GM_fnc_medevacLeave;
            ["backup", _id, _target, _squad] call A3GM_fnc_backupEscort;
        };
        private _end = time + 420;
        private _next = 0;
        waitUntil {
            sleep 3;
            if (time > _next) then {
                _next = time + 15;
                if (alive driver _car && {leader _squad != driver _car}) then { _squad selectLeader (driver _car) };
                if (speed _car < 2 && {_car distance2D _target > 150}) then {  // stalled: follow the player, nudge the driver
                    _wp setWaypointPosition [getPos _target, 20];
                    _squad setCurrentWaypoint _wp;
                    driver _car doMove (getPos _target);
                };
                diag_log text format ["A3GM|diag|car %1 at %2 dist %3 speed %4 leader %5 (%6) cmd %7 ready %8 behaviour %9 path %10 move %11 canMove %12 fuel %13 dmg %14 locked %15 engine %16 local %17",
                    typeOf _car, mapGridPosition _car, round (_car distance2D _target), round speed _car, name leader _squad,
                    assignedVehicleRole (leader _squad), currentCommand driver _car, unitReady driver _car, behaviour driver _car,
                    (driver _car) checkAIFeature "PATH", (driver _car) checkAIFeature "MOVE", canMove _car, fuel _car,
                    damage _car, locked _car, isEngineOn _car, local driver _car];
            };
            !alive _car || {time > _end} || {_car distance2D _target < 150} || {({ alive _x } count units _squad) == 0}
        };
        if (({ alive _x } count units _squad) == 0) exitWith { ["backup", _id, "lost", _target, "vehicle"] call A3GM_fnc_supportLog };
        // the crew-served weapon stays manned; everyone else gets out and fights
        { if (_x != gunner _car && {_x != driver _car}) then { unassignVehicle _x; moveOut _x } } forEach units _squad;
        if (!isNull _car2) then { _car2 setVariable ["A3GM_extra", true] };
        _squad setBehaviour "AWARE";
        // "arrived" only when they're really there; held up far out, they come on foot
        ["backup", _id, ["stuck", "arrived"] select (_car distance2D _target < 400), _target, mapGridPosition _car] call A3GM_fnc_supportLog;
        ["backup", _id, _target, _squad, [_car, _car2]] call A3GM_fnc_backupEscort;
    };
    [true, format ["vehicle %1 %2", { alive _x } count units _squad, mapGridPosition _target]]
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
    ["uav", _id, "launched", _target, format ["%1 eta %2", getText (configFile >> "CfgVehicles" >> _class >> "displayName"),
        round ((_uav distance2D _target) / 60)]] call A3GM_fnc_supportLog;

    [_id, _target, _uav, _grp] spawn {
        params ["_id", "_target", "_uav", "_grp"];
        private _center = getPos _target;
        waitUntil { sleep 3; !alive _uav || {_uav distance2D _center < 900} };
        if (alive _uav) then { ["uav", _id, "onstation", _target, mapGridPosition _center] call A3GM_fnc_supportLog };
        private _hostile = call A3GM_fnc_hostileSides;
        private _end = time + 900;
        while { alive _uav && {time < _end} } do {
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
            diag_log text format ["A3GM|diag|uav %1 at %2: %3 enemy groups within 2 km, %4 known",
                _id, mapGridPosition _uav, { side _x in _hostile && {(leader _x) distance2D _uav < 2000} } count allGroups, count _seen];
            sleep 15;
        };
        ["uav", _id, ["rtb", "lost"] select (!alive _uav), _target, ""] call A3GM_fnc_supportLog;
        if (alive _uav) then { [_uav, getPos _uav] call A3GM_fnc_medevacLeave };
    };
    [true, format ["%1 over %2", _class, mapGridPosition _target]]
};

// TRANSPORT: a helicopter picks the player (and whoever boards with them) up and flies them to a grid, lands,
// unloads and leaves. args: [id, player name, grid]
A3GM_fnc_transport = {
    params [["_id", "", [""]], ["_name", "", [""]], ["_grid", "", [""]]];
    private _target = [_name] call A3GM_fnc_supportTarget;
    if (isNull _target) exitWith { [false, "no such player"] };
    private _dest = _grid call A3GM_fnc_gridPos;
    if (_dest isEqualType "") exitWith { [false, _dest] };
    if (_target distance2D _dest < 500) exitWith { [false, "you're already there"] };
    private _heli = [_target, side group _target] call A3GM_fnc_spawnHeli;
    if (isNull _heli) exitWith { [false, "no helicopter available"] };
    A3GM_supportAssets set [_id, [false, [_heli]]];
    private _eta = round ((_heli distance2D _target) / 55 + 40);
    ["transport", _id, "launched", _target, format ["%1 eta %2", mapGridPosition _dest, _eta]] call A3GM_fnc_supportLog;
    [_id, _target, _heli, _dest] spawn {
        params ["_id", "_target", "_heli", "_dest"];
        private _lz = [getPos _target, 150] call A3GM_fnc_medevacLZ;
        createVehicle ["SmokeShellGreen", _lz, [], 0, "CAN_COLLIDE"];
        ["transport", _id, "landing", _target, mapGridPosition _lz] call A3GM_fnc_supportLog;
        if !([_heli, _lz] call A3GM_fnc_medevacLand) exitWith {
            ["transport", _id, "failed", _target, ["could not land", "lost"] select (!alive _heli)] call A3GM_fnc_supportLog;
            [_heli, _lz] call A3GM_fnc_medevacLeave;
        };
        // the caller first, then everyone close by who's coming (players and their AI squadmates)
        private _aboard = [_heli, _target] call A3GM_fnc_heliBoard;
        if (!alive _heli || {vehicle _target != _heli}) exitWith {
            ["transport", _id, "failed", _target, ["nobody boarded", "lost"] select (!alive _heli)] call A3GM_fnc_supportLog;
            [_heli, _lz] call A3GM_fnc_medevacLeave;
        };
        ["transport", _id, "wheelsup", _target, format ["%1 %2", mapGridPosition _dest, _aboard]] call A3GM_fnc_supportLog;
        _heli land "NONE";
        private _destLz = [_dest, 200] call A3GM_fnc_medevacLZ;
        if !([_heli, _destLz, 900] call A3GM_fnc_medevacLand) exitWith {
            ["transport", _id, "failed", _target, ["could not land at the destination", "lost"] select (!alive _heli)] call A3GM_fnc_supportLog;
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

// Occupant infantry hunting a player from 500-700 m out. args: [player name or "", size 2-8]
A3GM_fnc_qrf = {
    params [["_name", "", [""]], ["_size", 4, [0]]];
    _size = 2 max (round _size min 8);
    private _target = [_name] call A3GM_fnc_target;
    if (isNull _target) exitWith { [false, "no player"] };

    // Every man class in the occupant faction's "unit*" entries.
    private _faction = missionNamespace getVariable ["A3A_faction_occ", createHashMap];
    private _pool = [];
    {
        if ((toLower _x) find "unit" == 0) then {
            private _v = _y;
            if (_v isEqualType "") then { _v = [_v] };
            if (_v isEqualType []) then {
                {
                    if (_x isEqualType "" && {_x isKindOf "CAManBase"}) then { _pool pushBackUnique _x };
                } forEach _v;
            };
        };
    } forEach _faction;
    if (_pool isEqualTo []) exitWith { [false, "no occupant unit classes (A3A_faction_occ)"] };

    private _players = call A3GM_fnc_players;
    private _pos = [];
    for "_i" from 1 to 20 do {
        private _p = _target getPos [500 + random 200, random 360];
        if (!surfaceIsWater _p && {(_players findIf { _x distance2D _p < 400 }) == -1}) exitWith { _pos = _p };
    };
    if (_pos isEqualTo []) exitWith { [false, "no spawn position on land"] };

    private _side = if (isNil "Occupants") then { west } else { Occupants };
    private _grp = createGroup [_side, true];
    for "_i" from 1 to _size do {
        private _unit = _grp createUnit [selectRandom _pool, _pos, [], 10, "FORM"];
        if (!isNil "A3A_fnc_NATOinit") then { [_unit] call A3A_fnc_NATOinit };
    };
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
    [true, format ["%1 men at grid %2 hunting %3", _size, mapGridPosition _pos, name _target]]
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

// The map's grid convention, for the Game Master's targeting: mapGridPosition at known positions
A3GM_fnc_gridInfo = {
    private _probe = [[50, 50], [1050, 50], [50, 1050], [worldSize - 50, worldSize - 50]];
    [true, format ["%1 size %2 %3", worldName, worldSize,
        (_probe apply { format ["%1,%2=%3", _x select 0, _x select 1, mapGridPosition _x] }) joinString " "]]
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
    ["CANCEL", A3GM_fnc_cancel],
    ["GRIDINFO", A3GM_fnc_gridInfo]
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
A3GM_chatTrace = true; publicVariable "A3GM_chatTrace";  // TODO: off once chat relay is confirmed
[[], A3GM_fnc_chatHook] remoteExec ["spawn", -2, "A3GM_chatHook"];

[] spawn {
    // Antistasi's own server init has to finish first (factions, sides).
    waitUntil { sleep 2; missionNamespace getVariable ["serverInitDone", false] };
    call A3GM_fnc_betterRadios;
    diag_log text "A3GM|ready";
    while { true } do {
        private _raw = "a3gm" callExtension "poll";
        if (_raw isEqualTo "") then {
            sleep 0.1;  // commands are picked up within 0.1 s; the extension call is cheap
        } else {
            private _cmd = parseSimpleArray _raw;
            _cmd params [["_id", "?", [""]], ["_action", "", [""]], ["_args", [], [[]]]];
            _action = toUpper _action;
            private _fn = A3GM_actions getOrDefault [_action, {}];
            private _res = [false, "unknown action"];
            if (_action in A3GM_actions) then {
                _res = _args call _fn;
                if (!(_res isEqualType []) || {count _res < 2}) then { _res = [false, "no result"] };
            };
            _res params [["_ok", false, [false]], ["_detail", ""]];
            if !(_detail isEqualType "") then { _detail = str _detail };
            diag_log text format ["A3GM|done|%1|%2|%3|%4", _id call A3GM_fnc_clean, _action,
                ["fail", "ok"] select _ok, _detail call A3GM_fnc_clean];
        };
    };
};

diag_log text "A3GM|installed";
