#!/usr/bin/env python3
"""Shared Deezer session helper. Never prints the secret itself.

usage: session.py check                 (reads the ARL from $DEEZER_ARL_VALUE)
       session.py import-firefox <file> (writes DEEZER_ARL=... from a Firefox profile)
"""
import glob
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import urllib.request

GW = "https://www.deezer.com/ajax/gw-light.php?method=deezer.getUserData&input=3&api_version=1.0&api_token="


def check():
    arl = os.environ.get("DEEZER_ARL_VALUE", "")
    if not arl:
        sys.exit("no ARL in the session file")
    req = urllib.request.Request(GW, headers={"Cookie": f"arl={arl}", "User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=20) as r:
        data = json.load(r).get("results", {})
    user = data.get("USER", {})
    if not user.get("USER_ID"):
        sys.exit("session is NOT valid (logged out, expired or wrong ARL)")
    print(f"session is valid: user {user['USER_ID']} ({user.get('BLOG_NAME', '?')}), "
          f"offer: {data.get('OFFER_NAME') or 'unknown'}")


def import_firefox(dest):
    home = os.path.expanduser("~")
    roots = [".mozilla/firefox", "snap/firefox/common/.mozilla/firefox", ".var/app/org.mozilla.firefox/.mozilla/firefox"]
    dbs = [p for r in roots for p in glob.glob(os.path.join(home, r, "*", "cookies.sqlite"))]
    best = None
    for db in dbs:
        with tempfile.TemporaryDirectory() as tmp:  # the live database is locked while Firefox runs
            copy = os.path.join(tmp, "cookies.sqlite")
            shutil.copy(db, copy)
            for ext in ("-wal", "-shm"):
                if os.path.exists(db + ext):
                    shutil.copy(db + ext, copy + ext)
            row = sqlite3.connect(copy).execute(
                "SELECT value, lastAccessed FROM moz_cookies WHERE name = 'arl' AND host LIKE '%deezer.com' "
                "ORDER BY lastAccessed DESC LIMIT 1").fetchone()
        if row and (best is None or row[1] > best[1]):
            best = row
    if not best:
        sys.exit(f"no deezer.com 'arl' cookie in {len(dbs)} Firefox profile(s): log in on deezer.com first")
    fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write("# Deezer session used by tests/run.sh --login. Never commit or share this file.\n")
        f.write(f"DEEZER_ARL={best[0]}\n")


if __name__ == "__main__":
    if sys.argv[1:2] == ["check"]:
        check()
    elif sys.argv[1:2] == ["import-firefox"] and len(sys.argv) == 3:
        import_firefox(sys.argv[2])
    else:
        sys.exit(__doc__)
