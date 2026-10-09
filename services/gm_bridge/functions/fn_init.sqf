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

A3GM_actions = createHashMapFromArray [
    ["SAY", A3GM_fnc_say],
    ["AIRDROP", A3GM_fnc_airdrop],
    ["MORTAR", A3GM_fnc_mortar],
    ["WEATHER", A3GM_fnc_weather],
    ["QRF", A3GM_fnc_qrf],
    ["STATUS", A3GM_fnc_status],
    ["INTEL", A3GM_fnc_intel],
    ["MISSION", A3GM_fnc_mission],
    ["SITREP", A3GM_fnc_sitrep]
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
//   A3AICHAT|channel|side|speaker|text
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
    diag_log text format ["A3AICHAT|%1|%2|%3|%4", _channel, side group (allPlayers select _idx),
        (_speaker select [0, 60]) call A3GM_fnc_clean, _text call A3GM_fnc_clean];
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
