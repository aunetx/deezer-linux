#!/usr/bin/env python3
"""Check that every patch in patch-markers.txt is present in the app.asar the
running app actually loaded (found through /proc/<pid>/fd, so it works for deb,
rpm, AppImage, flatpak, snap and nix alike).

usage: asar_probe.py <patch-markers.txt> [app.asar]
Prints ASAR=<path>, PATCHES=<applied>/<total>, then "FAIL <reason>" lines.
"""
import glob
import os
import sys


def markers(path):
    out = []
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if line and not line.startswith("#"):
            name, marker = line.split(None, 1)
            out.append((name, marker.encode()))
    return out


def running_asars():
    for fd in glob.glob("/proc/[0-9]*/fd/*"):
        try:
            target = os.readlink(fd)
        except OSError:
            continue
        if target.endswith("/app.asar"):
            yield fd, target


def main():
    found = [(sys.argv[2], sys.argv[2])] if len(sys.argv) > 2 else list(running_asars())
    if not found:
        print("ASAR=none")
        print("FAIL app.asar not found among the app's open files")
        return
    fd, target = found[0]
    with open(fd, "rb") as f:  # /proc/<pid>/fd/<n> also reaches into flatpak/snap mounts
        data = f.read()
    expected = markers(sys.argv[1])
    missing = [name for name, m in expected if m not in data]
    print(f"ASAR={target}")
    print(f"PATCHES={len(expected) - len(missing)}/{len(expected)}")
    for name in missing:
        print(f"FAIL patch {name} is not applied in app.asar")


if __name__ == "__main__":
    main()
