import os

import keys


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


def mods(d):
    mods = []
    if not os.path.exists(d):
        return mods

    # Find mod folders
    for m in os.listdir(d):
        moddir = os.path.join(d, m)
        if os.path.isdir(moddir):
            lowercase_dir(moddir)
            mods.append(moddir)
            keys.copy(moddir)

    return mods

