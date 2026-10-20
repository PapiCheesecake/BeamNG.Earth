#!/usr/bin/env python3
"""Build the BeamMP client mod zip (Resources/Client/) from mod/beamng_earth.

    python beammp/build_client_zip.py          -> beammp/dist/BeamNG_Earth_<version>_MP.zip

The version in the name is this folder's VERSION (1.5.2-beta -> 152): players need the BeamNG.Earth .exe of exactly
that version (see BEAMMP.md).
"""
import os
import re
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD = os.path.join(ROOT, "mod", "beamng_earth")
SKIP = {"__pycache__", ".DS_Store"}


def short_version():
    with open(os.path.join(ROOT, "VERSION"), encoding="utf-8") as f:
        v = f.read().strip()
    m = re.match(r"(\d+)\.(\d+)\.(\d+)", v)
    return v, ("".join(m.groups()) if m else v)


def main():
    full, short = short_version()
    out_dir = os.path.join(ROOT, "beammp", "dist")
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, f"BeamNG_Earth_{short}_MP.zip")
    n = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for base, dirs, files in os.walk(MOD):
            dirs[:] = sorted(d for d in dirs if d not in SKIP)
            for name in sorted(files):
                if name in SKIP or name.endswith(".pyc"):
                    continue
                path = os.path.join(base, name)
                z.write(path, os.path.relpath(path, MOD).replace(os.sep, "/"))
                n += 1
    print(f"{out}: {n} files (BeamNG.Earth {full}: players need the {full} .exe)")


if __name__ == "__main__":
    main()
