class CfgPatches {
    class a3kf {
        name = "A3 Kill Feed (server)";
        units[] = {};
        weapons[] = {};
        requiredVersion = 2.0;
        requiredAddons[] = {};
        author = "ArmaA";
    };
};

class CfgFunctions {
    class A3KF {
        tag = "A3KF";
        class main {
            file = "\a3kf\functions";
            class init { postInit = 1; };
        };
    };
};
