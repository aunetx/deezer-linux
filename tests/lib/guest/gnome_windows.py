#!/usr/bin/env python3
"""GNOME Shell window check through org.gnome.Shell.Introspect.GetWindows.

Unlike AT-SPI, this is the compositor's own view: a window is listed only once it
is mapped, and it carries the Wayland app_id / X11 WM_CLASS ("wm-class") and the
desktop file the shell matched it to ("app-id", e.g. deezer-desktop.desktop, or
"window:N" when nothing matched). GNOME only answers callers on its allowlist
unless gnome-shell runs with --unsafe-mode (the test VM seed tests/vm/seeds/ubuntu-gnome.yaml
enables it; a host session is used as is).

Prints one line per visible app window:
  <window id>\t<wm-class>\t<title>\t<wayland|x11>\t<shell app-id>
Exit status 2 when the API is not available (access denied, not GNOME).
"""
import sys


def rows(windows):
    """Lines for the app windows in a GetWindows reply ({id: {property: value}})."""
    for wid, props in windows.items():
        wm_class, app_id = props.get("wm-class", ""), props.get("app-id", "")
        names = f"{wm_class} {app_id} {props.get('sandboxed-app-id', '')}".lower()
        if props.get("is-hidden") or "deezer" not in names:
            continue
        shell = "x11" if props.get("client-type") == 1 else "wayland"  # MetaWindowClientType
        yield f"{wid}\t{wm_class}\t{props.get('title', '')}\t{shell}\t{app_id}"


def main():
    from gi.repository import Gio, GLib

    try:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        reply = bus.call_sync("org.gnome.Shell", "/org/gnome/Shell/Introspect", "org.gnome.Shell.Introspect",
                              "GetWindows", None, GLib.VariantType("(a{ta{sv}})"), 0, 5000, None)
    except GLib.Error as e:
        print(e.message, file=sys.stderr)
        sys.exit(2)
    for line in rows(reply.unpack()[0]):
        print(line)


if __name__ == "__main__":
    main()
