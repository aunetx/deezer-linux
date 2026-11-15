#!/usr/bin/env python3
"""Window check through the ext-foreign-toplevel-list-v1 Wayland protocol.

The compositor's own view of its toplevels, Wayland and Xwayland alike, with
their app_id: offered by COSMIC, sway >= 1.10, Hyprland, niri, labwc and other
wlroots-based compositors (not GNOME or KDE). Pure Python: it speaks the Wayland
wire format directly, so it needs no client library in the guest.

Prints one line per Deezer toplevel (--all: every toplevel), like sway_windows.py:
  <identifier>\t<app_id>\t<title>\tforeign-toplevel
Exit status 2 when the compositor does not offer the protocol.
"""
import os
import socket
import struct
import sys

IFACE = "ext_foreign_toplevel_list_v1"
HANDLE_CLOSED, HANDLE_TITLE, HANDLE_APP_ID, HANDLE_IDENTIFIER = 0, 2, 3, 4  # handle events
HANDLE_FIELDS = {HANDLE_TITLE: "title", HANDLE_APP_ID: "app_id", HANDLE_IDENTIFIER: "id"}


def split(buf):
    """Complete messages in buf as [(object id, opcode, body)], and the unparsed rest."""
    out = []
    while len(buf) >= 8:
        obj, word = struct.unpack_from("=II", buf)
        size = word >> 16
        if size < 8 or len(buf) < size:
            break
        out.append((obj, word & 0xFFFF, buf[8:size]))
        buf = buf[size:]
    return out, buf


def message(obj, opcode, payload=b""):
    return struct.pack("=II", obj, ((8 + len(payload)) << 16) | opcode) + payload


def string(s):
    b = s.encode() + b"\0"
    return struct.pack("=I", len(b)) + b + b"\0" * (-len(b) % 4)


def read_string(body, off=0):
    """The string at off, and the offset after it (strings are padded to 32 bits)."""
    (n,) = struct.unpack_from("=I", body, off)
    return body[off + 4:off + 4 + max(n - 1, 0)].decode(errors="replace"), off + 4 + n + (-n % 4)


def update(handles, obj, opcode, body):
    """Applies one ext_foreign_toplevel_handle_v1 event to handles ({object id: fields})."""
    if opcode == HANDLE_CLOSED:
        handles.pop(obj, None)
    elif opcode in HANDLE_FIELDS:
        handles[obj][HANDLE_FIELDS[opcode]] = read_string(body)[0]


def rows(handles, show_all=False):
    for obj, h in sorted(handles.items()):
        if show_all or "eezer" in h["app_id"] + h["title"]:
            yield f"{h['id'] or obj}\t{h['app_id']}\t{h['title']}\tforeign-toplevel"


class Conn:
    def __init__(self):
        rt = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
        name = os.environ.get("WAYLAND_DISPLAY", "wayland-0")
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(5)
        self.s.connect(name if name.startswith("/") else os.path.join(rt, name))
        self.next_id = 2  # 1 is wl_display
        self.buf = b""

    def new_id(self):
        self.next_id += 1
        return self.next_id - 1

    def send(self, obj, opcode, payload=b""):
        self.s.sendall(message(obj, opcode, payload))

    def events(self):
        while True:
            msgs, self.buf = split(self.buf)
            yield from msgs
            data = self.s.recv(65536)
            if not data:
                return
            self.buf += data


def main():
    try:
        c = Conn()
    except OSError as e:
        sys.exit(f"no Wayland display: {e}")
    registry = c.new_id()
    c.send(1, 1, struct.pack("=I", registry))  # wl_display.get_registry
    sync = c.new_id()
    c.send(1, 0, struct.pack("=I", sync))  # wl_display.sync
    lst, syncs, handles, phase = None, {sync}, {}, 0
    for obj, op, body in c.events():
        if obj == 1 and op == 0:  # wl_display.error
            sys.exit("wayland error")
        if obj == registry and op == 0:  # wl_registry.global(name, interface, version)
            (name,) = struct.unpack_from("=I", body)
            iface, _ = read_string(body, 4)
            if iface == IFACE and lst is None:
                lst = c.new_id()  # wl_registry.bind(name, new_id(interface, version, id))
                c.send(registry, 0, struct.pack("=I", name) + string(iface) + struct.pack("=II", 1, lst))
        elif obj == lst and op == 0:  # ext_foreign_toplevel_list_v1.toplevel(new_id)
            handles[struct.unpack_from("=I", body)[0]] = {"id": "", "app_id": "", "title": ""}
        elif obj in handles:
            update(handles, obj, op, body)
        elif obj in syncs and op == 0:  # wl_callback.done
            syncs.discard(obj)
            if lst is None:
                sys.exit(2)
            phase += 1
            if phase == 3:  # globals, then the toplevels, then their properties
                break
            s = c.new_id()
            syncs.add(s)
            c.send(1, 0, struct.pack("=I", s))
    for row in rows(handles, "--all" in sys.argv):
        print(row)


if __name__ == "__main__":
    main()
