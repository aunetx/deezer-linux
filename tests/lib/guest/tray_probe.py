#!/usr/bin/env python3
"""Describe the tray icons registered with org.kde.StatusNotifierWatcher.

Works with the stub watcher and with real tray hosts (KDE, GNOME AppIndicator,
waybar...). For every item, prints one JSON line:
  {"item", "id", "title", "status", "icon_name", "icon_theme_path", "pixmap", "icon": "<how it resolves>" | ""}

"icon" is resolved the way a tray host outside the app's sandbox would do it:
a pixmap, then IconName inside IconThemePath, then the XDG icon theme. An empty
value means the host shows a placeholder (the "..." icon of #a9aad21: a snap
writing the icon into its private /tmp).
"""
import glob
import json
import os
import sys

from gi.repository import Gio, GLib

ITEM_IFACE = "org.kde.StatusNotifierItem"


def call(bus, dest, path, iface, method, args=None, sig=None):
    return bus.call_sync(dest, path, iface, method, args, GLib.VariantType(sig) if sig else None,
                         0, 3000, None).unpack()


def resolve_icon(name, theme_path, pixmap):
    if pixmap:
        return "pixmap " + "x".join(map(str, pixmap[0][:2]))
    if not name:
        return ""
    if os.path.isabs(name):
        return "file " + name if os.access(name, os.R_OK) else ""
    dirs = [theme_path] if theme_path else []
    data_dirs = os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(":")
    dirs += [os.path.join(d, "icons") for d in [os.path.expanduser("~/.local/share")] + data_dirs]
    dirs += ["/usr/share/pixmaps"]
    for d in dirs:
        for ext in ("png", "svg", "xpm"):
            hits = glob.glob(os.path.join(d, f"{name}.{ext}")) + glob.glob(os.path.join(d, "**", f"{name}.{ext}"),
                                                                              recursive=True)
            hits = [h for h in hits if os.access(h, os.R_OK)]
            if hits:
                return "file " + hits[0]
    return ""


def main():
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    try:
        items = call(bus, "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.freedesktop.DBus.Properties",
                     "Get", GLib.Variant("(ss)", ("org.kde.StatusNotifierWatcher", "RegisteredStatusNotifierItems")))[0]
    except GLib.Error as e:
        sys.exit(f"no StatusNotifierWatcher: {e.message}")
    for item in items:
        # "<bus name><object path>", or a bare bus name (default path /StatusNotifierItem)
        dest, slash, path = item.partition("/")
        path = "/" + path if slash else "/StatusNotifierItem"
        try:
            props = call(bus, dest, path, "org.freedesktop.DBus.Properties", "GetAll",
                         GLib.Variant("(s)", (ITEM_IFACE,)))[0]
        except GLib.Error:
            try:  # some items only register the Ayatana interface name
                props = call(bus, dest, path, "org.freedesktop.DBus.Properties", "GetAll",
                             GLib.Variant("(s)", ("org.freedesktop.StatusNotifierItem",)))[0]
            except GLib.Error as e:
                print(json.dumps({"item": item, "error": e.message}))
                continue
        pixmap = [(w, h) for w, h, data in props.get("IconPixmap", []) if w and h and data]
        print(json.dumps({
            "item": item, "id": props.get("Id", ""), "title": props.get("Title", ""),
            "status": props.get("Status", ""), "icon_name": props.get("IconName", ""),
            "icon_theme_path": props.get("IconThemePath", ""), "pixmap": pixmap,
            "icon": resolve_icon(props.get("IconName", ""), props.get("IconThemePath", ""), pixmap),
        }))


if __name__ == "__main__":
    main()
