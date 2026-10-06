if (!isServer) exitWith {};
if (!isNil "A3KF_ehId") then {
    removeMissionEventHandler ["EntityKilled", A3KF_ehId];
};
A3KF_ehId = addMissionEventHandler ["EntityKilled", {
    params ["_unit", "_killer", "_instigator"];
    private _isMan = _unit isKindOf "CAManBase";
    if (!_isMan && {!(_unit isKindOf "AllVehicles")}) exitWith {};
    if (isNull _instigator) then {
        _instigator = _unit getVariable ["ace_medical_lastInstigator", objNull];
    };
    if (isNull _instigator && {!isNull _killer}) then {
        _instigator = (UAVControl vehicle _killer) param [0, objNull];
    };
    if (isNull _instigator) then {
        _instigator = _killer;
    };
    private _hasKiller = !isNull _instigator && {_instigator != _unit} && {!(_instigator in crew _unit)};
    if (!_isMan && {!(_hasKiller && {isPlayer _instigator})}) exitWith {};
    private _clean = { (_this splitString "|") joinString "/" };
    private _sideName = {
        switch (_this) do {
            case west: { "WEST" };
            case east: { "EAST" };
            case resistance: { "GUER" };
            case civilian: { "CIV" };
            default { "" };
        }
    };
    private _victim = if (_isMan) then { name _unit } else { getText (configFile >> "CfgVehicles" >> typeOf _unit >> "displayName") };
    private _vSide = if (_isMan) then { side group _unit } else { side _unit };
    private _kName = "";
    private _kSide = "";
    private _kPlayer = false;
    private _weapon = "";
    private _dist = -1;
    if (_hasKiller) then {
        _kName = name _instigator;
        _kSide = (side group _instigator) call _sideName;
        _kPlayer = isPlayer _instigator;
        private _veh = vehicle _instigator;
        _weapon = if (_veh != _instigator) then {
            getText (configFile >> "CfgVehicles" >> typeOf _veh >> "displayName")
        } else {
            getText (configFile >> "CfgWeapons" >> currentWeapon _instigator >> "displayName")
        };
        _dist = round (_unit distance _instigator);
    };
    diag_log text format [
        "A3KF|1|%1|%2|%3|%4|%5|%6|%7|%8|%9",
        ["veh", "man"] select _isMan,
        _victim call _clean,
        _vSide call _sideName,
        _isMan && {isPlayer _unit},
        _kName call _clean,
        _kSide,
        _kPlayer,
        _weapon call _clean,
        _dist
    ];
}];
diag_log text "A3KF|installed";
if (!isServer) exitWith {};
A3KF_mapGrid = 512;
[] spawn {
    private _clean = { (_this splitString "|") joinString "/" };
    private _sideName = {
        switch (_this) do {
            case west: { "WEST" };
            case east: { "EAST" };
            case resistance: { "GUER" };
            case civilian: { "CIV" };
            default { "" };
        }
    };
    private _size = worldSize;
    private _n = A3KF_mapGrid;
    private _step = _size / _n;
    diag_log text format ["A3MAP|1|world|%1|%2|%3", worldName, _size, _n];
    private _digits = "0123456789abcdef" splitString "";
    private _hex = [];
    { private _hi = _x; { _hex pushBack (_hi + _x) } forEach _digits } forEach _digits;
    for "_r" from 0 to _n - 1 do {
        private _y = (_r + 0.5) * _step;
        for "_part" from 0 to (_n / 256) - 1 do {
            private _cells = [];
            for "_c" from _part * 256 to _part * 256 + 255 do {
                private _h = getTerrainHeightASL [(_c + 0.5) * _step, _y];
                _cells pushBack (_hex select ([0, 1 + (254 min round (_h / 1.5))] select (_h > 0)));
            };
            diag_log text format ["A3MAP|1|t|%1|%2|%3", _r, _part, _cells joinString ""];
        };
    };
    {
        private _type = getText (_x >> "type");
        if (_type in ["NameCityCapital", "NameCity", "NameVillage", "NameLocal", "Airport"]) then {
            private _name = getText (_x >> "name");
            if (_name select [0, 1] == "$") then { _name = localize (_name select [1]) };
            private _pos = getArray (_x >> "position");
            if (_name != "" && {count _pos >= 2}) then {
                diag_log text format ["A3MAP|1|town|%1|%2|%3|%4", _name call _clean, _type, round ((_pos select 0)), round ((_pos select 1))];
            };
        };
    } forEach ("true" configClasses (configFile >> "CfgWorlds" >> worldName >> "Names"));
    waitUntil { sleep 5; !isNil "serverInitDone" && {!isNil "sidesX"} };
    private _kinds = [
        ["airportsX", "airbase"], ["milbases", "milbase"], ["outposts", "outpost"], ["seaports", "seaport"],
        ["factories", "factory"], ["resourcesX", "resource"], ["citiesX", "city"]
    ];
    private _lastSides = createHashMap;
    private _lastHq = [];
    private _nextZones = 0;
    private _tick = 0;
    while { true } do {
        if (time >= _nextZones) then {
            _nextZones = time + 30;
            {
                _x params ["_var", "_kind"];
                {
                    private _side = (sidesX getVariable [_x, sideUnknown]) call _sideName;
                    if ((_lastSides getOrDefault [_x, "-"]) != _side) then {
                        _lastSides set [_x, _side];
                        private _pos = getMarkerPos _x;
                        diag_log text format ["A3MAP|1|zone|%1|%2|%3|%4|%5", _x call _clean, _kind, round ((_pos select 0)), round ((_pos select 1)), _side];
                    };
                } forEach (missionNamespace getVariable [_var, []]);
            } forEach _kinds;
            private _hq = markerPos "Synd_HQ";
            private _hqRounded = [round ((_hq select 0)), round ((_hq select 1))];
            if (!(_hqRounded isEqualTo _lastHq)) then {
                _lastHq = _hqRounded;
                diag_log text format ["A3MAP|1|hq|%1|%2", (_hqRounded select 0), (_hqRounded select 1)];
            };
        };
        private _players = (allPlayers - entities "HeadlessClient_F") select { alive _x };
        _tick = _tick + 1;
        diag_log text format ["A3MAP|1|tick|%1|%2", _tick, count _players];
        {
            private _veh = vehicle _x;
            private _vehName = if (_veh != _x) then { getText (configFile >> "CfgVehicles" >> typeOf _veh >> "displayName") } else { "" };
            private _pos = getPosWorld _veh;
            diag_log text format [
                "A3MAP|1|p|%1|%2|%3|%4|%5|%6|%7",
                _tick, name _x call _clean, round ((_pos select 0)), round ((_pos select 1)), round (getDir _veh),
                _vehName call _clean, (side group _x) call _sideName
            ];
        } forEach _players;
        sleep ([60, 15] select (count _players > 0));
    };
};
