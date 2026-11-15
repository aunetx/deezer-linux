#!/usr/bin/env python3
"""Fake org.freedesktop.portal.Settings (color-scheme only), for --sync-theme.

Logs every call as "PORTAL_<Method> <namespace> <key>" to stdout and $PORTAL_LOG.
SIGUSR1 flips dark <-> light and emits SettingChanged.
COLOR_SCHEME sets the initial value (0 = default, 1 = dark, 2 = light).
"""
import os
import signal
import sys

from gi.repository import Gio, GLib

XML = """<node><interface name="org.freedesktop.portal.Settings">
<method name="Read"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
<method name="ReadOne"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
<method name="ReadAll"><arg type="as" direction="in"/><arg type="a{sa{sv}}" direction="out"/></method>
<signal name="SettingChanged"><arg type="s"/><arg type="s"/><arg type="v"/></signal>
<property name="version" type="u" access="read"/></interface></node>"""

NS, KEY = "org.freedesktop.appearance", "color-scheme"
state = {"scheme": int(os.environ.get("COLOR_SCHEME", "1")), "conn": None}


def out(msg):
    print(msg, flush=True)
    if os.environ.get("PORTAL_LOG"):
        with open(os.environ["PORTAL_LOG"], "a") as f:
            f.write(msg + "\n")


def on_call(conn, sender, path, iface, method, params, inv):
    if method == "ReadAll":
        out("PORTAL_ReadAll")
        value = {NS: {KEY: GLib.Variant("u", state["scheme"])}}
        return inv.return_value(GLib.Variant("(a{sa{sv}})", (value,)))
    ns, key = params.unpack()
    out(f"PORTAL_{method} {ns} {key}")
    if (ns, key) == (NS, KEY):
        v = GLib.Variant("u", state["scheme"])
        # Read() wraps the value in an extra variant (legacy API), ReadOne() does not.
        return inv.return_value(GLib.Variant("(v)", (GLib.Variant("v", v) if method == "Read" else v,)))
    inv.return_dbus_error("org.freedesktop.portal.Error.NotFound", "not found")


def flip(*_):
    state["scheme"] = 2 if state["scheme"] == 1 else 1
    out(f"PORTAL_FLIP {state['scheme']}")
    state["conn"].emit_signal(None, "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings",
                              "SettingChanged", GLib.Variant("(ssv)", (NS, KEY, GLib.Variant("u", state["scheme"]))))
    return True


def on_bus(conn, name):
    state["conn"] = conn
    node = Gio.DBusNodeInfo.new_for_xml(XML)
    conn.register_object("/org/freedesktop/portal/desktop", node.interfaces[0], on_call,
                         lambda *_: GLib.Variant("u", 2), None)


GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR1, flip)
Gio.bus_own_name(Gio.BusType.SESSION, "org.freedesktop.portal.Desktop", 0, on_bus,
                 lambda c, n: out("PORTAL_READY"), lambda c, n: sys.exit(1))
GLib.MainLoop().run()
