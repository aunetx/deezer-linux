"""Shared paths and readers for the unit tests (stdlib only)."""
import configparser
import json
import os
import re

TESTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(TESTS)
GUEST = os.path.join(TESTS, "lib", "guest")
PATCHES = os.path.join(REPO, "patches")


def read(*parts):
    with open(os.path.join(REPO, *parts), encoding="utf-8") as f:
        return f.read()


def package_append():
    return json.loads(read("package-append.json"))


def desktop_entry(*parts):
    cp = configparser.ConfigParser(interpolation=None, strict=False)
    cp.optionxform = str
    cp.read_string(read(*parts))
    return dict(cp["Desktop Entry"])


def patch_names():
    return sorted(f[:-len(".patch")] for f in os.listdir(PATCHES) if f.endswith(".patch"))


def added_lines(patch):
    """The lines a patch adds, without the leading '+'."""
    text = read("patches", f"{patch}.patch")
    return "\n".join(l[1:] for l in text.splitlines() if l.startswith("+") and not l.startswith("+++"))


def patch_markers():
    out = {}
    with open(os.path.join(GUEST, "patch-markers.txt"), encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                name, marker = line.split(None, 1)
                out[name] = marker
    return out


def version_tuple(spec):
    return tuple(int(x) for x in re.findall(r"\d+", spec)[:3])
