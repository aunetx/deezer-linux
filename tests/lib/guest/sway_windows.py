#!/usr/bin/env python3
"""Reads `swaymsg -t get_tree` on stdin and prints one line per visible app window:
<con id>\t<app_id or X11 class>\t<title>\t<xdg_shell|xwayland>"""
import json
import sys


def walk(node):
    yield node
    for child in node.get("nodes", []) + node.get("floating_nodes", []):
        yield from walk(child)


for n in walk(json.load(sys.stdin)):
    props = n.get("window_properties") or {}
    cls = n.get("app_id") or props.get("class") or ""
    if n.get("pid") and n.get("visible") and "eezer" in f"{n.get('name')}{cls}{props.get('instance', '')}":
        print(f"{n['id']}\t{cls}\t{n.get('name')}\t{n.get('shell')}")
