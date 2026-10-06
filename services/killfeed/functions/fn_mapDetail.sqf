// A3KF map detail export, drawn into Arma-style map tiles by the telemetry bridge.
// Runs once per mission start in the scheduler, so it never holds up a frame.
//   A3MAP|1|dstart|worldName|surfaceGrid|treeGrid
//   A3MAP|1|sk|code|surfaceName                     ground type legend (one-char codes)
//   A3MAP|1|s|row|part|codes                        ground type: surfaceGrid rows south to north,
//                                                   256 cells per part
//   A3MAP|1|tr|row|part|hex                         trees per cell (treeGrid, 2 hex chars, max 255)
//   A3MAP|1|rd|type;width;bx;by;ex;ey;bridge/...    road segments, batched
//   A3MAP|1|bd|x;y;w;l;dir;kind/...                 building footprints, batched
//   A3MAP|1|dend|roads|buildings
if (!isServer) exitWith {};

[] spawn {
    private _size = worldSize;
    private _surfaceGrid = 1024;
    private _treeGrid = 256;
    private _codes = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" splitString "";

    sleep 30; // let the mission settle first
    diag_log text format ["A3MAP|1|dstart|%1|%2|%3", worldName, _surfaceGrid, _treeGrid];

    // --- Ground type grid ---
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

    // --- Tree density grid ---
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

    // --- Roads and buildings, one 1 km cell at a time. Each object is reported by the cell its
    // position falls in, so overlapping queries never duplicate it. ---
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
