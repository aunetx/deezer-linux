#!/usr/bin/env python3
"""Check that the installed desktop entry links the app's window, MPRIS player
and notifications to one launcher (taskbar / dock grouping, media controls and
notification icons).

usage: desktop_probe.py [--class C] [--mpris-entry D] [--notify-entry N] [--app-id ID]

One id must name everything: the launcher's desktop file is "<id>.desktop", and
the window class (X11 WM_CLASS, Wayland app_id), the entry's StartupWMClass, the
MPRIS DesktopEntry and the notification "desktop-entry" hint are all "<id>".
The id is the launcher's file name (dev.aunetx.deezer; deezer-desktop_deezer-desktop
in a snap, where snapd names the file), unless --app-id gives it.

Some shells match a window through StartupWMClass (GNOME, KDE task manager), but
others look the id up as a desktop file id (KWin icons, COSMIC, waybar, portals,
notification and MPRIS lookups): a window linked through StartupWMClass alone fails.

Prints KEY=VALUE lines, then "FAIL <reason>" / "WARN <reason>" lines.
Background: #156 (COSMIC dock icon), #189 (GNOME media controls icon), #229 (KDE duplicate entry).
"""
import argparse
import configparser
import glob
import os
import shutil
import subprocess


def data_dirs():
    home = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    dirs = [home] + (os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share").split(":")
    dirs += [os.path.expanduser("~/.local/share/flatpak/exports/share"), "/var/lib/flatpak/exports/share",
             "/var/lib/snapd/desktop"]
    seen, out = set(), []
    for d in dirs:
        if d and d not in seen:
            seen.add(d)
            out.append(d)
    return out


def read_entry(path):
    cp = configparser.ConfigParser(interpolation=None, strict=False)
    cp.optionxform = str
    try:
        cp.read(path, encoding="utf-8")
        return dict(cp["Desktop Entry"])
    except (configparser.Error, KeyError, UnicodeDecodeError):
        return None


def installed_entries():
    """{desktop id: (path, entry)} for every visible entry, first data dir wins (XDG precedence)."""
    out = {}
    for d in data_dirs():
        base = os.path.join(d, "applications")
        for path in sorted(glob.glob(os.path.join(base, "**", "*.desktop"), recursive=True)):
            did = os.path.relpath(path, base).replace("/", "-")
            if did not in out:
                entry = read_entry(path)
                if entry is not None:
                    out[did] = (path, entry)
    return out


def is_app_entry(did, entry):
    text = " ".join([did, entry.get("Exec", ""), entry.get("TryExec", ""), entry.get("Name", "")]).lower()
    return "deezer" in text and entry.get("Type", "Application") == "Application"


def resolve_icon(icon):
    if not icon:
        return ""
    if os.path.isabs(icon):
        return icon if os.access(icon, os.R_OK) else ""
    for d in data_dirs():
        for pattern in (f"icons/hicolor/*/apps/{icon}.*", f"icons/*/*/apps/{icon}.*", f"pixmaps/{icon}.*"):
            hits = [h for h in glob.glob(os.path.join(d, pattern)) if os.access(h, os.R_OK)]
            if hits:
                return sorted(hits)[-1]
    return ""


def links_window(did, entry, wm_class):
    """How a shell can map the window to this entry: "file-name", "StartupWMClass" or ""."""
    if did == f"{wm_class}.desktop":
        return "file-name"
    return "StartupWMClass" if entry.get("StartupWMClass") == wm_class else ""


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--class", dest="wm_class", default="")
    p.add_argument("--mpris-entry", default="")
    p.add_argument("--notify-entry", default="")
    p.add_argument("--app-id", default="", help="expected id (default: the launcher's file name)")
    a = p.parse_args()

    entries = installed_entries()
    mine = {did: v for did, v in entries.items() if is_app_entry(did, v[1])}
    fails, warns = [], []
    print(f"DESKTOP_IDS={','.join(sorted(mine)) or 'none'}")
    if not mine:
        print("FAIL no installed desktop entry launches the app")
        return
    # The launcher users click: the one that handles deezer:// links, else the first.
    did = next((d for d, (_, e) in mine.items() if "x-scheme-handler/deezer" in e.get("MimeType", "")), sorted(mine)[0])
    path, entry = mine[did]
    app_id = a.app_id or did.removesuffix(".desktop")
    print(f"DESKTOP_ID={did}")
    print(f"DESKTOP_WMCLASS={entry.get('StartupWMClass', '')}")
    print(f"DESKTOP_ICON={entry.get('Icon', '')}")
    icon_file = resolve_icon(entry.get("Icon", ""))
    print(f"DESKTOP_ICON_FILE={icon_file or 'none'}")
    if not icon_file:
        fails.append(f"desktop entry icon '{entry.get('Icon', '')}' is not installed in any icon theme")
    if entry.get("StartupWMClass") != app_id:
        fails.append(f"StartupWMClass '{entry.get('StartupWMClass', '')}' != app id '{app_id}'")
    if "x-scheme-handler/deezer" not in entry.get("MimeType", ""):
        fails.append("desktop entry does not declare x-scheme-handler/deezer (deep links, browser login)")
    elif shutil.which("xdg-mime"):
        handler = subprocess.run(["xdg-mime", "query", "default", "x-scheme-handler/deezer"],
                                 capture_output=True, text=True).stdout.strip()
        print(f"DEEPLINK_HANDLER={handler or 'none'}")
        if handler not in mine:
            warns.append(f"deezer:// is handled by '{handler or 'nothing'}', not by the app")

    if a.wm_class:
        links = {d: links_window(d, e, a.wm_class) for d, (_, e) in mine.items()}
        linked = sorted(d for d, how in links.items() if how)
        print(f"TASKBAR_LINK={','.join(linked) or 'none'}")
        print(f"TASKBAR_LINK_BY={','.join(sorted({links[d] for d in linked})) or 'none'}")
        if not linked:
            fails.append(f"window class '{a.wm_class}' matches no desktop entry (no taskbar icon / grouping)")
        elif "file-name" not in links.values():
            fails.append(f"window '{a.wm_class}' links to {', '.join(linked)} through StartupWMClass only:"
                         f" shells that look up '{a.wm_class}.desktop' show a generic icon (#156, #229)")
    # GNOME's media controls (#189) and notification icons resolve the app through these ids.
    for label, value, what in (("MPRIS_LINK", a.mpris_entry, "MPRIS DesktopEntry"),
                               ("NOTIFY_LINK", a.notify_entry, "notification desktop-entry hint")):
        if not value:
            continue
        linked = entries.get(f"{value}.desktop")
        print(f"{label}={value}.desktop" if linked else f"{label}=none")
        if linked and label == "NOTIFY_LINK":
            print(f"NOTIFY_ICON_FILE={resolve_icon(linked[1].get('Icon', '')) or 'none'}")
        if not linked:
            fails.append(f"{what} '{value}' names no installed desktop file (installed: {', '.join(sorted(mine))}):"
                         " shells show a generic icon (#189)")
        elif value != app_id:
            fails.append(f"{what} '{value}' names {value}.desktop, not the launcher {did}")
    for f in fails:
        print(f"FAIL {f}")
    for w in warns:
        print(f"WARN {w}")


if __name__ == "__main__":
    main()
