#!/usr/bin/env python3
"""Record desktop notifications (org.freedesktop.Notifications.Notify).

If nobody owns org.freedesktop.Notifications (headless guests), this acts as a
minimal notification server. Otherwise (GNOME, KDE, XFCE...), it watches the
calls as a bus monitor, so the real server still shows them.

Every Notify call is written as one JSON line to $NOTIFY_LOG (and stdout):
  {"app_name", "app_icon", "summary", "desktop_entry", "image": "data WxH" | "path ..." | ""}
"""
import json
import os
import sys

from gi.repository import Gio, GLib

NAME = "org.freedesktop.Notifications"
XML = """<node><interface name="org.freedesktop.Notifications">
<method name="Notify"><arg type="s" direction="in"/><arg type="u" direction="in"/><arg type="s" direction="in"/>
<arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="as" direction="in"/>
<arg type="a{sv}" direction="in"/><arg type="i" direction="in"/><arg type="u" direction="out"/></method>
<method name="CloseNotification"><arg type="u" direction="in"/></method>
<method name="GetCapabilities"><arg type="as" direction="out"/></method>
<method name="GetServerInformation"><arg type="s" direction="out"/><arg type="s" direction="out"/>
<arg type="s" direction="out"/><arg type="s" direction="out"/></method>
<signal name="NotificationClosed"><arg type="u"/><arg type="u"/></signal>
<signal name="ActionInvoked"><arg type="u"/><arg type="s"/></signal>
</interface></node>"""
log_path = os.environ.get("NOTIFY_LOG")
counter = {"id": 0}


def record(args):
    app_name, _, app_icon, summary, _, _, hints, _ = args
    image = ""
    for key in ("image-data", "image_data", "icon_data"):
        if key in hints:
            w, h = hints[key][0], hints[key][1]
            image = f"data {w}x{h}"
    for key in ("image-path", "image_path"):
        if not image and key in hints:
            image = "path " + hints[key]
    line = json.dumps({"app_name": app_name, "app_icon": app_icon, "summary": summary,
                       "desktop_entry": hints.get("desktop-entry", ""), "image": image})
    print(line, flush=True)
    if log_path:
        with open(log_path, "a") as f:
            f.write(line + "\n")


def serve(conn):
    def on_call(conn, sender, path, iface, method, params, inv):
        if method == "Notify":
            record(params.unpack())
            counter["id"] += 1
            inv.return_value(GLib.Variant("(u)", (counter["id"],)))
        elif method == "GetCapabilities":
            inv.return_value(GLib.Variant("(as)", (["body", "icon-static", "persistence", "actions"],)))
        elif method == "GetServerInformation":
            inv.return_value(GLib.Variant("(ssss)", ("deezer-linux-tests", "deezer-linux", "1", "1.2")))
        else:
            inv.return_value(None)

    node = Gio.DBusNodeInfo.new_for_xml(XML)
    conn.register_object("/org/freedesktop/Notifications", node.interfaces[0], on_call, None, None)


def monitor():
    addr = Gio.dbus_address_get_for_bus_sync(Gio.BusType.SESSION, None)
    conn = Gio.DBusConnection.new_for_address_sync(
        addr, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
        None, None)

    def on_message(conn, msg, incoming):
        if (msg.get_message_type() == Gio.DBusMessageType.METHOD_CALL and msg.get_member() == "Notify"
                and msg.get_interface() == NAME):
            GLib.idle_add(record, msg.get_body().unpack())
        return None  # a monitor only observes

    conn.add_filter(on_message)
    rule = f"type='method_call',interface='{NAME}',member='Notify'"
    conn.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus.Monitoring",
                   "BecomeMonitor", GLib.Variant("(asu)", ([rule], 0)), None, 0, -1, None)
    print("NOTIFY_MONITOR_READY", flush=True)
    return conn


bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
owner = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner",
                      GLib.Variant("(s)", (NAME,)), None, 0, -1, None).unpack()[0]
if owner:
    keep = monitor()
else:
    Gio.bus_own_name_on_connection(bus, NAME, 0, lambda c, n: print("NOTIFY_SERVER_READY", flush=True),
                                   lambda c, n: sys.exit(1))
    serve(bus)
GLib.MainLoop().run()
