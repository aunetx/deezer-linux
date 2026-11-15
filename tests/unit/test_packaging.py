"""Packaging metadata that past fixes depend on (no build needed)."""
import re
import unittest

from helpers import desktop_entry, package_append, read, version_tuple, added_lines


class DesktopIdentity(unittest.TestCase):
    """c093311: one id everywhere, or shells cannot link the window to its launcher."""

    def setUp(self):
        self.pkg = package_append()
        self.app_id = self.pkg["build"]["appId"]

    def test_app_id(self):
        self.assertEqual(self.app_id, "dev.aunetx.deezer")

    def test_desktop_name_is_app_id(self):
        # Electron derives the Wayland app_id and the X11 WM_CLASS from desktopName.
        self.assertEqual(self.pkg["desktopName"], f"{self.app_id}.desktop")

    def test_builder_entry_startup_wm_class(self):
        self.assertEqual(self.pkg["build"]["linux"]["desktop"]["entry"]["StartupWMClass"], self.app_id)

    def test_repo_desktop_file(self):
        entry = desktop_entry("dev.aunetx.deezer.desktop")
        self.assertEqual(entry["StartupWMClass"], self.app_id)
        self.assertEqual(entry["Icon"], self.app_id)
        self.assertIn("x-scheme-handler/deezer", entry["MimeType"])  # deep links / browser login

    def test_builder_entry_handles_deep_links(self):
        self.assertIn("x-scheme-handler/deezer", self.pkg["build"]["linux"]["desktop"]["entry"]["MimeType"])

    def test_notifications_declared(self):
        self.assertEqual(self.pkg["build"]["linux"]["desktop"]["entry"].get("X-GNOME-UsesNotifications"), "true")


class FlatpakPermissions(unittest.TestCase):
    def setUp(self):
        self.args = package_append()["build"]["flatpak"]["finishArgs"]

    def test_session_bus(self):
        # #270 / #271: desktop integration needs the whole session bus.
        self.assertIn("--socket=session-bus", self.args)

    def test_owns_the_mpris_name(self):
        # The sandbox may only own the name patch 05 registers.
        name = re.search(r'name: "([^"]+)"', added_lines("05-provide-metadata-mpris")).group(1)
        self.assertIn(f"--own-name=org.mpris.MediaPlayer2.{name}", self.args)

    def test_tray_and_notifications(self):
        self.assertIn("--talk-name=org.kde.StatusNotifierWatcher", self.args)
        self.assertIn("--talk-name=org.freedesktop.Notifications", self.args)

    def test_temp_dir_visible_to_the_host(self):
        # Chromium hands the tray host a temp file path: it must not be the sandbox's private /tmp.
        self.assertIn("--env=TMPDIR=/var/tmp", self.args)


class Snap(unittest.TestCase):
    def test_tray_icon_temp_dir(self):
        # a9aad21: GNOME showed "..." because the icon was written to the snap's private /tmp.
        yaml = read("snapcraft.yaml")
        self.assertRegex(yaml, r"(?m)^\s+TMPDIR:\s*\$XDG_RUNTIME_DIR\s*$")


class Electron(unittest.TestCase):
    def test_version_with_working_tray(self):
        # c093311: tray broken on 43.0; 30855b2: 44.3 needed for the snap tray icon.
        spec = package_append()["devDependencies"]["electron"]
        self.assertGreaterEqual(version_tuple(spec), (44, 3, 0), spec)


if __name__ == "__main__":
    unittest.main()
