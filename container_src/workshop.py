import os
import re
import subprocess
import urllib.request

import keys

WORKSHOP = "steamapps/workshop/content/107410/"
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_9_3) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/35.0.1916.47 Safari/537.36"  # noqa: E501


def env_defined(key):
    return key in os.environ and len(os.environ[key].strip()) > 0


def lowercase_dir(path):
    """Recursively rename files and directories to lowercase for Linux compatibility."""
    for root, dirs, files in os.walk(path, topdown=False):
        for name in files:
            src = os.path.join(root, name)
            dst = os.path.join(root, name.lower())
            if src != dst and not os.path.exists(dst):
                os.rename(src, dst)
        for name in dirs:
            src = os.path.join(root, name)
            dst = os.path.join(root, name.lower())
            if src != dst and not os.path.exists(dst):
                os.rename(src, dst)


def is_mod_downloaded(mod_id):
    path = os.path.join(WORKSHOP, mod_id)
    if os.path.isdir(path) and len(os.listdir(path)) > 0:
        return True
    return False


def run_steamcmd(commands):
    """Run SteamCMD commands as STEAM_USER, preferring the cached session.

    Logging in with the password always starts a fresh login (a Steam Guard
    prompt on 2FA accounts) and discards the session cached by
    `manage.sh steam-login`, so log in with the username alone first and only
    fall back to the password when no usable session is cached.
    """
    base = ["/steamcmd/steamcmd.sh", "+@sSteamCmdForcePlatformType", "linux"]
    user = os.environ["STEAM_USER"]
    if env_defined("STEAM_GUARD_CODE"):
        code = os.environ["STEAM_GUARD_CODE"].strip()
        login = ["+set_steam_guard_code", code, "+force_install_dir", "/arma3",
                 "+login", user, os.environ["STEAM_PASSWORD"], code]
        return subprocess.call(base + login + commands + ["+quit"])

    cached = ["+force_install_dir", "/arma3", "+login", user]
    res = subprocess.call(base + cached + commands + ["+quit"], stdin=subprocess.DEVNULL)
    if res == 0:
        return res
    print(f"\n[!] Cached Steam login unavailable (SteamCMD exited with code {res}); "
          "falling back to password login.", flush=True)
    print("[!] To avoid Steam Guard prompts here, run: ./scripts/manage.sh steam-login <code>\n", flush=True)
    password = ["+force_install_dir", "/arma3", "+login", user, os.environ["STEAM_PASSWORD"]]
    return subprocess.call(base + password + commands + ["+quit"])


def download(mods):
    missing_mods = [m for m in mods if not is_mod_downloaded(m)]
    for m in mods:
        if is_mod_downloaded(m):
            print(f"Mod {m} is already downloaded and present. Skipping download.", flush=True)

    if not missing_mods:
        print("All workshop mods are already downloaded and present.", flush=True)
        return

    print(f"\n=======================================================", flush=True)
    print(f"Downloading {len(missing_mods)} Workshop Mod(s) in a single session: {', '.join(missing_mods)}...", flush=True)
    print("If prompted, please confirm login ONCE on your Steam Mobile app.", flush=True)
    print(f"=======================================================\n", flush=True)

    commands = []
    for mod_id in missing_mods:
        commands.extend(["+workshop_download_item", "107410", mod_id, "validate"])

    res = run_steamcmd(commands)
    if res != 0:
        print(f"\n[!] WARNING: SteamCMD workshop download exited with code {res}", flush=True)
        raise RuntimeError(f"SteamCMD workshop download exited with code {res}")



def preset(mod_file):
    if mod_file.startswith("http"):
        req = urllib.request.Request(
            mod_file,
            headers={"User-Agent": USER_AGENT},
        )
        remote = urllib.request.urlopen(req)
        with open("preset.html", "wb") as f:
            f.write(remote.read())
        mod_file = "preset.html"
    mods = []
    moddirs = []
    with open(mod_file) as f:
        html = f.read()
        regex = r"filedetails\/\?id=(\d+)\""
        matches = re.finditer(regex, html, re.MULTILINE)
        for _, match in enumerate(matches, start=1):
            mods.append(match.group(1))
            moddir = WORKSHOP + match.group(1)
            moddirs.append(moddir)
        try:
            download(mods)
        except RuntimeError as e:
            print(f"[!] Workshop preset download error: {e}", flush=True)
            import sys
            sys.exit(1)
        for moddir in moddirs:
            if os.path.exists(moddir):
                lowercase_dir(moddir)
                keys.copy(moddir)
    return moddirs

