#!/usr/bin/env python3
"""Minimal org.kde.StatusNotifierWatcher stub.

Stands in for a tray host (GNOME AppIndicator, KDE, waybar...) on headless
sessions. Every RegisterStatusNotifierItem call is logged as
"SNI_REGISTERED <item>" to stdout and to $SNI_LOG.
"""
import os
import sys

from gi.repository import Gio, GLib

XML = """<node><interface name="org.kde.StatusNotifierWatcher">
<method name="RegisterStatusNotifierItem"><arg type="s" direction="in"/></method>
<method name="RegisterStatusNotifierHost"><arg type="s" direction="in"/></method>
<property name="RegisteredStatusNotifierItems" type="as" access="read"/>
<property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
<property name="ProtocolVersion" type="i" access="read"/>
<signal name="StatusNotifierItemRegistered"><arg type="s"/></signal>
<signal name="StatusNotifierItemUnregistered"><arg type="s"/></signal>
<signal name="StatusNotifierHostRegistered"/>
</interface></node>"""

items = []
log_path = os.environ.get("SNI_LOG")


def out(msg):
    print(msg, flush=True)
    if log_path:
        with open(log_path, "a") as f:
            f.write(msg + "\n")


def on_call(conn, sender, path, iface, method, params, inv):
    if method == "RegisterStatusNotifierItem":
        svc = params.unpack()[0]
        entry = f"{sender}{svc}" if svc.startswith("/") else svc
        items.append(entry)
        out(f"SNI_REGISTERED {entry}")
        conn.emit_signal(None, path, iface, "StatusNotifierItemRegistered",
                         GLib.Variant("(s)", (entry,)))
    inv.return_value(None)


def on_get(conn, sender, path, iface, prop):
    return {
        "RegisteredStatusNotifierItems": GLib.Variant("as", items),
        "IsStatusNotifierHostRegistered": GLib.Variant("b", True),
        "ProtocolVersion": GLib.Variant("i", 0),
    }[prop]


def on_bus(conn, name):
    node = Gio.DBusNodeInfo.new_for_xml(XML)
    conn.register_object("/StatusNotifierWatcher", node.interfaces[0], on_call, on_get, None)


Gio.bus_own_name(Gio.BusType.SESSION, "org.kde.StatusNotifierWatcher", 0, on_bus,
                 lambda c, n: out("SNI_WATCHER_READY"),
                 lambda c, n: (out("SNI_WATCHER_LOST"), sys.exit(1)))
GLib.MainLoop().run()
