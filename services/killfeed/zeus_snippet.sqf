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
A3KF_mapGrid = 1024;
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
if (!isServer) exitWith {};
[] spawn {
    private _size = worldSize;
    private _surfaceGrid = 1024;
    private _treeGrid = 256;
    private _codes = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" splitString "";
    sleep 30;
    diag_log text format ["A3MAP|1|dstart|%1|%2|%3", worldName, _surfaceGrid, _treeGrid];
    private _legend = createHashMap;
    private _step = _size / _surfaceGrid;
    for "_r" from 0 to _surfaceGrid - 1 do {
        private _y = (_r + 0.5) * _step;
        for "_part" from 0 to (_surfaceGrid / 256) - 1 do {
            private _cells = [];
            for "_c" from _part * 256 to _part * 256 + 255 do {
                private _surface = surfaceType [(_c + 0.5) * _step, _y];
                private _code = _legend getOrDefault [_surface, ""];
                if (_code == "") then {
                    _code = _codes param [count _legend, "?"];
                    _legend set [_surface, _code];
                    diag_log text format ["A3MAP|1|sk|%1|%2", _code, (_surface splitString "|") joinString "/"];
                };
                _cells pushBack _code;
            };
            diag_log text format ["A3MAP|1|s|%1|%2|%3", _r, _part, _cells joinString ""];
        };
    };
    private _digits = "0123456789abcdef" splitString "";
    private _hex = [];
    { private _hi = _x; { _hex pushBack (_hi + _x) } forEach _digits } forEach _digits;
    private _tstep = _size / _treeGrid;
    private _tradius = _tstep * 0.5;
    for "_r" from 0 to _treeGrid - 1 do {
        private _y = (_r + 0.5) * _tstep;
        private _cells = [];
        for "_c" from 0 to _treeGrid - 1 do {
            private _n = count nearestTerrainObjects [[(_c + 0.5) * _tstep, _y], ["TREE", "SMALL TREE"], _tradius, false, true];
            _cells pushBack (_hex select (_n min 255));
        };
        diag_log text format ["A3MAP|1|tr|%1|0|%2", _r, _cells joinString ""];
    };
    private _cell = 1000;
    private _cellCount = ceil (_size / _cell);
    private _radius = _cell * 0.75;
    private _kinds = [
        [["BUILDING", "HOUSE"], 0],
        [["CHURCH", "CHAPEL"], 1],
        [["BUNKER", "FORTRESS", "VIEW-TOWER"], 2],
        [["FUELSTATION"], 3],
        [["HOSPITAL"], 4],
        [["LIGHTHOUSE", "TRANSMITTER", "WATERTOWER", "POWERWIND"], 5],
        [["RUIN"], 6]
    ];
    private _roadCount = 0;
    private _buildingCount = 0;
    private _r1 = { round (_this * 10) / 10 };
    for "_cy" from 0 to _cellCount - 1 do {
        for "_cx" from 0 to _cellCount - 1 do {
            private _x0 = _cx * _cell;
            private _y0 = _cy * _cell;
            private _center = [_x0 + _cell / 2, _y0 + _cell / 2];
            private _inCell = {
                private _p = getPosWorld _this;
                (_p select 0) >= _x0 && {(_p select 0) < _x0 + _cell} && {(_p select 1) >= _y0} && {(_p select 1) < _y0 + _cell}
            };
            private _batch = [];
            {
                if (_x call _inCell) then {
                    (getRoadInfo _x) params ["_type", "_width", "", "", "", "", "_beg", "_end", ["_bridge", false]];
                    if (!isNil "_beg" && {count _beg >= 2}) then {
                        _batch pushBack format ["%1;%2;%3;%4;%5;%6;%7", _type, _width call _r1,
                            round (_beg select 0), round (_beg select 1), round (_end select 0), round (_end select 1),
                            [0, 1] select _bridge];
                        _roadCount = _roadCount + 1;
                        if (count _batch >= 14) then {
                            diag_log text ("A3MAP|1|rd|" + (_batch joinString "/"));
                            _batch = [];
                        };
                    };
                };
            } forEach (_center nearRoads _radius);
            if (count _batch > 0) then { diag_log text ("A3MAP|1|rd|" + (_batch joinString "/")) };
            _batch = [];
            {
                _x params ["_types", "_kind"];
                {
                    if (_x call _inCell) then {
                        (boundingBoxReal _x) params ["_min", "_max"];
                        private _w = (_max select 0) - (_min select 0);
                        private _l = (_max select 1) - (_min select 1);
                        if (_w * _l >= 6 && {_w < 200} && {_l < 200}) then {
                            private _mid = _x modelToWorldWorld [((_min select 0) + (_max select 0)) / 2, ((_min select 1) + (_max select 1)) / 2, 0];
                            _batch pushBack format ["%1;%2;%3;%4;%5;%6", round (_mid select 0), round (_mid select 1),
                                _w call _r1, _l call _r1, round (getDir _x), _kind];
                            _buildingCount = _buildingCount + 1;
                            if (count _batch >= 20) then {
                                diag_log text ("A3MAP|1|bd|" + (_batch joinString "/"));
                                _batch = [];
                            };
                        };
                    };
                } forEach nearestTerrainObjects [_center, _types, _radius, false, true];
            } forEach _kinds;
            if (count _batch > 0) then { diag_log text ("A3MAP|1|bd|" + (_batch joinString "/")) };
        };
    };
    diag_log text format ["A3MAP|1|dend|%1|%2", _roadCount, _buildingCount];
};
