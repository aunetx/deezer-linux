#!/usr/bin/env python3
"""DE-agnostic window check through AT-SPI (works on GNOME, KDE, XFCE...).

Prints one line per top-level frame of every accessible app whose name
contains "deezer":  <app>\t<frame title>\t<showing:yes|no>
The app must run with --force-renderer-accessibility.
"""
import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

desktop = Atspi.get_desktop(0)
for i in range(desktop.get_child_count()):
    app = desktop.get_child_at_index(i)
    if not app or "deezer" not in (app.get_name() or "").lower():
        continue
    for j in range(app.get_child_count()):
        frame = app.get_child_at_index(j)
        if not frame:
            continue
        showing = frame.get_state_set().contains(Atspi.StateType.SHOWING)
        print(f"{app.get_name()}\t{frame.get_name()}\t{'yes' if showing else 'no'}")
