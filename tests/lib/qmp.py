#!/usr/bin/env python3
"""Minimal QEMU Machine Protocol client.

usage: qmp.py <socket> screendump <out.png>
       qmp.py <socket> sendkey <key> [key...]    keys pressed together, e.g. ctrl alt t
       qmp.py <socket> type "<text>"
       qmp.py <socket> quit
<socket> is a unix socket path or host:port.
"""
import json
import os
import socket
import struct
import sys
import zlib


def connect(addr):
    if "/" in addr:
        s = socket.socket(socket.AF_UNIX)
        s.connect(addr)
    else:
        host, _, port = addr.rpartition(":")
        s = socket.create_connection((host or "127.0.0.1", int(port)))
    f = s.makefile("rw")
    json.loads(f.readline())  # greeting
    cmd(f, "qmp_capabilities")
    return f


def cmd(f, name, **args):
    f.write(json.dumps({"execute": name, "arguments": args}) + "\n")
    f.flush()
    while True:
        reply = json.loads(f.readline())
        if "return" in reply or "error" in reply:
            return reply


def ppm_to_png(src, dst):
    data = open(src, "rb").read()
    magic, w, h, _, px = data.split(maxsplit=4)
    assert magic == b"P6"
    w, h = int(w), int(h)
    raw = b"".join(b"\0" + px[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(tag, body):
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body))

    with open(dst, "wb") as out:
        out.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                  + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


KEYS = {" ": ["spc"], "\n": ["ret"], "-": ["minus"], ".": ["dot"], "/": ["slash"], "_": ["shift", "minus"],
        ":": ["shift", "semicolon"], "=": ["equal"]}


def main():
    addr, op, *args = sys.argv[1:]
    f = connect(addr)
    if op == "screendump":
        out = os.path.abspath(args[0])
        if "error" in cmd(f, "screendump", filename=out, format="png"):  # QEMU < 7.1: PPM only
            cmd(f, "screendump", filename=out + ".ppm")
            ppm_to_png(out + ".ppm", out)
            os.remove(out + ".ppm")
    elif op == "sendkey":
        cmd(f, "send-key", keys=[{"type": "qcode", "data": k} for k in args])
    elif op == "type":
        for ch in args[0]:
            keys = KEYS.get(ch) or (["shift", ch.lower()] if ch.isupper() else [ch])
            cmd(f, "send-key", keys=[{"type": "qcode", "data": k} for k in keys])
    elif op == "quit":
        try:
            cmd(f, "quit")
        except (ConnectionResetError, json.JSONDecodeError):
            pass
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
