#!/usr/bin/env python3
"""Build the A3GM Game Master bridge server addon into servermods/@a3gm.

  servermods/@a3gm/addons/a3gm.pbo   config + SQF action handlers
  servermods/@a3gm/a3gm_x64.so       the callExtension spool reader (a3gm.c)

The .so is x86_64 Linux. With --compile it is rebuilt from a3gm.c in a Debian trixie amd64
container (same libc as the server's FEX RootFS; needs QEMU binfmt, see scripts/setup_binfmt.sh).
Loaded automatically at the next server start, like every @ folder in servermods/.
"""

import hashlib
import os
import shutil
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PREFIX = "a3gm"
FILES = ["config.cpp", "functions/fn_init.sqf"]
MOD = os.path.join(ROOT, "servermods", "@a3gm")
SO = os.path.join(HERE, "a3gm_x64.so")


def pack_pbo(path, prefix, files):
    def entry(name, size, method=0, timestamp=0):
        return name.encode() + b"\0" + struct.pack("<5I", method, 0, 0, timestamp, size)

    now = int(time.time())
    header = entry("", 0, method=0x56657273)  # "Vers" header entry
    header += b"prefix\0" + prefix.encode() + b"\0\0"
    blobs = []
    for rel in files:
        with open(os.path.join(HERE, rel), "rb") as f:
            data = f.read().replace(b"\r\n", b"\n")
        header += entry(rel.replace("/", "\\"), len(data), timestamp=now)
        blobs.append(data)
    header += entry("", 0)  # end of file table
    body = header + b"".join(blobs)
    body += b"\0" + hashlib.sha1(body).digest()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(body)


def compile_so():
    script = (
        "apt-get update -qq >/dev/null && apt-get install -y -qq gcc libc6-dev >/dev/null && "
        "gcc -O2 -Wall -Wextra -shared -fPIC -fvisibility=hidden -o a3gm_x64.so a3gm.c && "
        f"chown {os.getuid()}:{os.getgid()} a3gm_x64.so"
    )
    subprocess.run(
        ["docker", "run", "--rm", "--platform", "linux/amd64", "-v", f"{HERE}:/src", "-w", "/src",
         "debian:trixie-slim", "sh", "-c", script],
        check=True,
    )


def main():
    if "--compile" in sys.argv or not os.path.exists(SO):
        compile_so()
    pbo = os.path.join(MOD, "addons", "a3gm.pbo")
    pack_pbo(pbo, PREFIX, FILES)
    shutil.copy2(SO, os.path.join(MOD, "a3gm_x64.so"))
    print(f"wrote {os.path.relpath(pbo, ROOT)} ({os.path.getsize(pbo)} bytes)")
    print(f"wrote {os.path.relpath(os.path.join(MOD, 'a3gm_x64.so'), ROOT)}")


if __name__ == "__main__":
    main()
