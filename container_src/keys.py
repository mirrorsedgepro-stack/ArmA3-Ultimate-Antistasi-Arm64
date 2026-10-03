import glob
import os
import shutil


def copy(moddir):
    keys = glob.glob(os.path.join(moddir, "**/*.bikey"), recursive=True)
    keys.extend(glob.glob(os.path.join(moddir, "**/*.BIKEY"), recursive=True))
    seen = set()
    unique_keys = []
    for k in keys:
        if k not in seen:
            seen.add(k)
            unique_keys.append(k)

    if len(unique_keys) > 0:
        for key in unique_keys:
            if not os.path.isdir(key):
                dest_file = os.path.join("/arma3/keys", os.path.basename(key).lower())
                shutil.copy2(key, dest_file)
                print(f"Copied bikey: {os.path.basename(key)} -> /arma3/keys/", flush=True)
    else:
        print(f"Warning: No bikey found in {moddir}", flush=True)


if __name__ == "__main__":
    for moddir in glob.glob("/arma3/steamapps/workshop/content/107410/*"):
        copy(moddir)

