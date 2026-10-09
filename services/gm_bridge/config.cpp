class CfgPatches {
    class a3gm {
        name = "A3 Game Master bridge (server)";
        units[] = {};
        weapons[] = {};
        requiredVersion = 2.0;
        requiredAddons[] = {};
        author = "ArmaA";
    };
};

class CfgFunctions {
    class A3GM {
        tag = "A3GM";
        class main {
            file = "\a3gm\functions";
            class init { postInit = 1; };
        };
    };
};
