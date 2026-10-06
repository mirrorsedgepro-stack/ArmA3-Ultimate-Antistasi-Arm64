#!/usr/bin/env python3
"""Build the A3KF kill-feed server addon and the Zeus "Execute Code" snippet.

  servermods/@a3kf/addons/a3kf.pbo   loaded automatically at the next server start
  services/killfeed/zeus_snippet.sqf paste into Zeus > Execute Code (target: Server)
                                     to enable it on the running server now

The PBO is uncompressed and unsigned: server-only mods are not signature-checked.
"""

import hashlib
import os
import re
import struct
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PREFIX = "a3kf"
FILES = ["config.cpp", "functions/fn_init.sqf"]
OUT_PBO = os.path.join(ROOT, "servermods", "@a3kf", "addons", "a3kf.pbo")
OUT_SNIPPET = os.path.join(HERE, "zeus_snippet.sqf")


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


def zeus_snippet(sqf):
    """Zeus compiles without the preprocessor, so drop // comments and blank lines."""
    out = []
    for line in sqf.splitlines():
        # strip // comments that are not inside a string literal
        in_str, cut = None, None
        for i, ch in enumerate(line):
            if in_str:
                if ch == in_str:
                    in_str = None
            elif ch in "\"'":
                in_str = ch
            elif line.startswith("//", i):
                cut = i
                break
        line = (line[:cut] if cut is not None else line).rstrip()
        if line.strip():
            out.append(line)
    return "\n".join(out) + "\n"


def main():
    pack_pbo(OUT_PBO, PREFIX, FILES)
    with open(os.path.join(HERE, "functions", "fn_init.sqf")) as f:
        snippet = zeus_snippet(f.read())
    with open(OUT_SNIPPET, "w") as f:
        f.write(snippet)
    print(f"wrote {os.path.relpath(OUT_PBO, ROOT)} ({os.path.getsize(OUT_PBO)} bytes)")
    print(f"wrote {os.path.relpath(OUT_SNIPPET, ROOT)} ({len(snippet)} chars)")


if __name__ == "__main__":
    main()
