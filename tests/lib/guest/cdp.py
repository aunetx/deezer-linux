#!/usr/bin/env python3
"""Evaluate JavaScript in the app's main page over the Chrome DevTools Protocol.

usage: cdp.py <port> eval '<expression>'     prints the JSON value (promises are awaited)
       cdp.py <port> url                      prints the main page URL

The app must be started with --remote-debugging-port=<port>. Stdlib only, so it
runs in every guest. The client sends no Origin header, so Chromium accepts it
without --remote-allow-origins.
"""
import base64
import json
import os
import socket
import struct
import sys
import time
import urllib.request


def targets(port):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=5) as r:
        return json.load(r)


def main_page(port):
    pages = [t for t in targets(port) if t.get("type") == "page"]
    for t in pages:  # the Deezer web app, not the titlebar or devtools
        if "deezer.com" in t.get("url", "") or t.get("url", "").startswith("file:"):
            return t
    if not pages:
        raise SystemExit("no page target")
    return pages[0]


class WebSocket:
    def __init__(self, url):
        host_port, path = url[len("ws://"):].split("/", 1)
        host, port = host_port.split(":")
        self.sock = socket.create_connection((host, int(port)), timeout=30)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f"GET /{path} HTTP/1.1\r\nHost: {host_port}\r\nUpgrade: websocket\r\n"
                           f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
                           "Sec-WebSocket-Version: 13\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("websocket handshake failed")
            head += chunk
        if b" 101 " not in head.split(b"\r\n", 1)[0]:
            raise ConnectionError(head.split(b"\r\n", 1)[0].decode())
        self.buf = head.split(b"\r\n\r\n", 1)[1]

    def send(self, text):
        data, mask = text.encode(), os.urandom(4)
        n = len(data)
        header = struct.pack("!B", 0x81) + (struct.pack("!B", 0x80 | n) if n < 126 else
                                             struct.pack("!BH", 0x80 | 126, n) if n < 65536 else
                                             struct.pack("!BQ", 0x80 | 127, n))
        self.sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("websocket closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def recv(self):
        message = b""
        while True:
            b1, b2 = self._read(2)
            n = b2 & 0x7F
            if n == 126:
                n = struct.unpack("!H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack("!Q", self._read(8))[0]
            payload = self._read(n)
            message += payload
            if b1 & 0x80:
                return message.decode()


def evaluate(port, expression):
    ws = WebSocket(main_page(port)["webSocketDebuggerUrl"])
    ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate", "params": {
        "expression": expression, "awaitPromise": True, "returnByValue": True, "userGesture": True}}))
    while True:
        reply = json.loads(ws.recv())
        if reply.get("id") == 1:
            break
    result = reply.get("result", {})
    if "exceptionDetails" in result:
        raise SystemExit("exception: " + json.dumps(result["exceptionDetails"].get("exception", {})
                                                    .get("description", result["exceptionDetails"])))
    return result.get("result", {}).get("value")


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    port, op = sys.argv[1], sys.argv[2]
    deadline = time.time() + 15
    while True:  # the endpoint comes up a moment after the window
        try:
            if op == "url":
                print(main_page(port).get("url", ""))
            elif op == "eval":
                print(json.dumps(evaluate(port, sys.argv[3])))
            else:
                sys.exit(__doc__)
            return
        except (OSError, ConnectionError) as e:
            if time.time() > deadline:
                sys.exit(f"cdp: {e}")
            time.sleep(0.5)  # poll interval


if __name__ == "__main__":
    main()
