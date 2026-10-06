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
