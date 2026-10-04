import os
import re
import shutil
import subprocess
from string import Template

import local
import workshop


def mod_param(name, mods):
    return ' -{}="{}" '.format(name, ";".join(mods))


def env_defined(key):
    return key in os.environ and len(os.environ[key]) > 0


CONFIG_FILE = os.environ["ARMA_CONFIG"]
KEYS = "/arma3/keys"

if env_defined("CLEAR_KEYS") and os.environ["CLEAR_KEYS"] == "true" and os.path.isdir(KEYS):
    shutil.rmtree(KEYS)
if not os.path.isdir(KEYS):
    if os.path.exists(KEYS):
        os.remove(KEYS)
    os.makedirs(KEYS)

if os.environ.get("SKIP_INSTALL", "false") in ["", "false"]:
    raw_bin_check = os.environ.get("ARMA_BINARY", "./arma3server_x64").strip()
    if not os.path.exists(raw_bin_check):
        print("\n=======================================================", flush=True)
        print("Downloading Arma 3 Dedicated Server files (AppID 233780)...", flush=True)
        print("=======================================================\n", flush=True)
        steamcmd = ["+app_update", "233780"]
        if env_defined("STEAM_BRANCH"):
            steamcmd.extend(["-beta", os.environ["STEAM_BRANCH"]])
        if env_defined("STEAM_BRANCH_PASSWORD"):
            steamcmd.extend(["-betapassword", os.environ["STEAM_BRANCH_PASSWORD"]])
        steamcmd.extend(["validate"])
        if env_defined("STEAM_ADDITIONAL_DEPOT"):
            for depot in os.environ["STEAM_ADDITIONAL_DEPOT"].split("|"):
                depot_parts = depot.split(",")
                steamcmd.extend(
                    ["+download_depot", "233780", depot_parts[0], depot_parts[1]]
                )
        res = workshop.run_steamcmd(steamcmd)
        if res != 0:
            print(f"\n[!] FATAL: SteamCMD server installation exited with code {res}", flush=True)
            print("[!] If Steam Guard was prompted, logon denied, or rate-limited:", flush=True)
            print("[!]   1. Stop the server: ./scripts/manage.sh stop", flush=True)
            print("[!]   2. Authenticate cleanly: ./scripts/manage.sh steam-login", flush=True)
            print("[!] Halting startup to avoid repeated failed login requests.\n", flush=True)
            import sys
            sys.exit(1)
    else:
        print(f"Arma 3 server binary '{raw_bin_check}' already present. Skipping base server install.", flush=True)



if env_defined("STEAM_ADDITIONAL_DEPOT"):
    for depot in os.environ["STEAM_ADDITIONAL_DEPOT"].split("|"):
        depot_parts = depot.split(",")
        depot_dir = (
            f"/steamcmd/linux32/steamapps/content/app_233780/depot_{depot_parts[0]}/"
        )
        for file in os.listdir(depot_dir):
            shutil.copytree(depot_dir + file, "/arma3/", dirs_exist_ok=True)
            print(f"Moved {file} to /arma3")

# Mods

mods = []

if os.environ["MODS_PRESET"] != "":
    mods.extend(workshop.preset(os.environ["MODS_PRESET"]))

if os.environ["MODS_LOCAL"] == "true" and os.path.exists("mods"):
    mods.extend(local.mods("mods"))

binary = os.environ["ARMA_BINARY"]

raw_bin = binary.strip()
if not os.path.exists(raw_bin):
    print("\n=======================================================", flush=True)
    print(f"FATAL ERROR: Arma 3 server binary '{raw_bin}' not found in /arma3!", flush=True)
    print("This indicates SteamCMD failed to download the server files.", flush=True)
    print("Please verify your STEAM_USER and STEAM_PASSWORD in .env.", flush=True)
    print("If your account has Steam Guard enabled, please run:", flush=True)
    print("  ./scripts/manage.sh steam-login", flush=True)
    print("=======================================================\n", flush=True)
    import sys
    sys.exit(1)

launch = "{} -limitFPS={} -world={} {} {}".format(
    binary,
    os.environ["ARMA_LIMITFPS"],
    os.environ["ARMA_WORLD"],
    os.environ["ARMA_PARAMS"],
    mod_param("mod", mods),
)

if os.environ["ARMA_CDLC"] != "":
    for cdlc in os.environ["ARMA_CDLC"].split(";"):
        launch += " -mod={}".format(cdlc)

clients = int(os.environ["HEADLESS_CLIENTS"])
print("Headless Clients:", clients)

# Render the server config to /tmp, filling secrets from the environment so
# configs/main.cfg can be committed with placeholders only
with open("/arma3/configs/{}".format(CONFIG_FILE)) as config:
    data = config.read()
for secret in ["ARMA_PASSWORD", "ARMA_PASSWORD_ADMIN", "ARMA_PASSWORD_COMMAND"]:
    data = data.replace("${" + secret + "}", os.environ.get(secret, ""))

regex = r"(.+?)(?:\s+)?=(?:\s+)?(.+?)(?:$|\/|;)"

config_values = {}

matches = re.finditer(regex, data, re.MULTILINE)
for matchNum, match in enumerate(matches, start=1):
    config_values[match.group(1).lower()] = match.group(2)

if clients != 0:
    if "headlessclients[]" not in config_values:
        data += '\nheadlessclients[] = {"127.0.0.1"};\n'
    if "localclient[]" not in config_values:
        data += '\nlocalclient[] = {"127.0.0.1"};\n'

with open("/tmp/arma3.cfg", "w") as tmp_config:
    tmp_config.write(data)
launch += ' -config="/tmp/arma3.cfg"'

if clients != 0:
    client_launch = launch
    client_launch += " -client -connect=127.0.0.1 -port={}".format(os.environ["PORT"])
    hc_password = ""
    if "password" in config_values:
        hc_password = " -password={}".format(config_values["password"])

    for i in range(0, clients):
        raw_pattern = os.environ.get("HEADLESS_CLIENTS_PROFILE", "$profile-hc-$i")
        if "$" not in raw_pattern:
            raw_pattern = "$profile-hc-$i"
        hc_template = Template(raw_pattern)
        hc_name = hc_template.substitute(
            profile=os.environ["ARMA_PROFILE"], i=i, ii=i + 1
        )

        # Separate profile dir per HC: a shared one gives every HC the same
        # identity (server drops the earlier one) and contends on cache_lock
        hc_args = ' -name="{}" -profiles="/arma3/configs/profiles/{}"'.format(
            hc_name, hc_name
        )
        print("LAUNCHING ARMA CLIENT {} WITH".format(i), client_launch + hc_args)
        # Relaunch HCs that exit so the server gets its AI offload back
        # (Antistasi re-registers reconnecting HCs)
        subprocess.Popen(
            "while true; do {}; echo \"HC {} exited with code $?, relaunching in 15s\"; sleep 15; done".format(
                client_launch + hc_password + hc_args, i
            ),
            shell=True,
        )

launch += ' -port={} -name="{}" -profiles="/arma3/configs/profiles"'.format(
    os.environ["PORT"], os.environ["ARMA_PROFILE"]
)

if os.path.exists("servermods"):
    launch += mod_param("serverMod", local.mods("servermods"))

print("LAUNCHING ARMA SERVER WITH", launch, flush=True)
os.system(launch)
