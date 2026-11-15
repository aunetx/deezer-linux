"""The test tooling itself: redaction, desktop linking rules, matrix, scripts."""
import glob
import importlib.util
import os
import shlex
import subprocess
import tempfile
import textwrap
import unittest

from helpers import GUEST, TESTS


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(GUEST, f"{name}.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ARL = "a" * 40 + "0123456789abcdef" * 6  # same shape as a real ARL, not a real one
SID = "fr" + "0123456789abcdef" * 2
JWT = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJlc2lnbmF0dXJl"


class Redaction(unittest.TestCase):
    """Lines the app really logs at debug level (8.0.10)."""

    def setUp(self):
        self.redact = load("redact")

    def clean(self, text):
        return self.redact.scrub(text, [ARL])

    def test_autolog_cookies(self):
        out = self.clean(f"Autolog cookies found: {{ arl: '{ARL}', sid: '{SID}', refreshToken: 'r{'x' * 30}' }}")
        for secret in (ARL, SID, "x" * 30):
            self.assertNotIn(secret, out)

    def test_autolog_result(self):
        out = self.clean(f"User autolog result: {ARL} {SID} {JWT} refresh{'y' * 30}")
        self.assertEqual(out, "User autolog result: [REDACTED]")

    def test_deep_link(self):
        out = self.redact.scrub(f'DeepLink: Trying to login with arl token from path "/autolog/{ARL}".', [])
        self.assertNotIn(ARL, out)
        self.assertIn("/autolog/[REDACTED", out)

    def test_cookie_header_and_jwt(self):
        out = self.redact.scrub(f"cookie: arl={ARL}; sid={SID}; jwt={JWT}", [])
        for secret in (ARL, SID, JWT):
            self.assertNotIn(secret, out)

    def test_keeps_ordinary_lines(self):
        line = "Checking login status via userAutolog; cached JWT: Error: expired"
        self.assertEqual(self.redact.scrub(line, []), line)

    def test_tree(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "app.log"), "w") as f:
                f.write(f"deezer://www.deezer.com/autolog/{ARL}\n")
            with open(os.path.join(d, "shot.png"), "wb") as f:
                f.write(b"\x89PNG\xff\xfe")
            subprocess.run(["python3", os.path.join(GUEST, "redact.py"), d, ARL], check=True)
            with open(os.path.join(d, "app.log")) as f:
                self.assertNotIn(ARL, f.read())


class DesktopLinking(unittest.TestCase):
    """How shells map windows, MPRIS players and notifications to a launcher."""

    def setUp(self):
        self.probe = load("desktop_probe")
        self.tmp = tempfile.TemporaryDirectory()
        self.apps = os.path.join(self.tmp.name, "applications")
        os.makedirs(self.apps)

    def tearDown(self):
        self.tmp.cleanup()

    def install(self, name, wm_class, icon="deezer-desktop"):
        with open(os.path.join(self.apps, name), "w") as f:
            f.write(textwrap.dedent(f"""\
                [Desktop Entry]
                Type=Application
                Name=Deezer
                Exec=/opt/deezer-desktop/deezer-desktop %U
                Icon={icon}
                StartupWMClass={wm_class}
                MimeType=x-scheme-handler/deezer;
                """))

    def run_probe(self, *args):
        env = dict(os.environ, XDG_DATA_HOME=self.tmp.name, XDG_DATA_DIRS="/nonexistent", HOME=self.tmp.name)
        out = subprocess.run(["python3", os.path.join(GUEST, "desktop_probe.py"), *args], env=env,
                             capture_output=True, text=True, check=True).stdout
        return out

    def test_window_links_through_startup_wm_class(self):
        self.install("deezer-desktop.desktop", "dev.aunetx.deezer")  # what the .deb installs
        out = self.run_probe("--class", "dev.aunetx.deezer")
        self.assertIn("TASKBAR_LINK=deezer-desktop.desktop", out)
        self.assertNotIn("window class", out)

    def test_window_links_through_desktop_id(self):
        self.install("dev.aunetx.deezer.desktop", "dev.aunetx.deezer")  # what the Flatpak exports
        self.assertIn("TASKBAR_LINK=dev.aunetx.deezer.desktop", self.run_probe("--class", "dev.aunetx.deezer"))

    def test_old_class_does_not_link(self):
        # Before c093311, StartupWMClass=deezer-desktop never matched the dev.aunetx.deezer window.
        self.install("deezer-desktop.desktop", "deezer-desktop")
        out = self.run_probe("--class", "dev.aunetx.deezer")
        self.assertIn("TASKBAR_LINK=none", out)
        self.assertIn("FAIL window class", out)
        self.assertIn("FAIL StartupWMClass", out)

    def test_mpris_entry_must_name_an_installed_file(self):
        self.install("dev.aunetx.deezer.desktop", "dev.aunetx.deezer")
        out = self.run_probe("--mpris-entry", "deezer-desktop")
        self.assertIn("MPRIS_LINK=none", out)
        self.assertIn("FAIL MPRIS DesktopEntry 'deezer-desktop'", out)
        self.assertIn("MPRIS_LINK=dev.aunetx.deezer.desktop", self.run_probe("--mpris-entry", "dev.aunetx.deezer"))

    def test_notification_icon_comes_from_the_linked_entry(self):
        self.install("dev.aunetx.deezer.desktop", "dev.aunetx.deezer", icon="/usr/share/pixmaps/does-not-exist.png")
        out = self.run_probe("--notify-entry", "dev.aunetx.deezer")
        self.assertIn("NOTIFY_LINK=dev.aunetx.deezer.desktop", out)
        self.assertIn("NOTIFY_ICON_FILE=none", out)

    def test_missing_icon_fails(self):
        self.install("deezer-desktop.desktop", "dev.aunetx.deezer", icon="not-installed")
        self.assertIn("FAIL desktop entry icon", self.run_probe())

    def test_icon_in_hicolor(self):
        self.install("deezer-desktop.desktop", "dev.aunetx.deezer")
        icon_dir = os.path.join(self.tmp.name, "icons", "hicolor", "256x256", "apps")
        os.makedirs(icon_dir)
        open(os.path.join(icon_dir, "deezer-desktop.png"), "wb").close()
        self.assertIn("DESKTOP_ICON_FILE=" + icon_dir, self.run_probe())


class Matrix(unittest.TestCase):
    """Every matrix line names a known distro / profile / session, so typos fail here, not after an hour."""

    def sourced(self, expr):
        return subprocess.run(["bash", "-c", f'. "{TESTS}/lib/common.sh"; . "{TESTS}/lib/vm.sh"; {expr}'],
                              capture_output=True, text=True, check=True).stdout.strip()

    def test_lines(self):
        distros = self.sourced("echo $DISTROS").split()
        profiles = self.sourced("echo $VM_PROFILES").split()
        with open(os.path.join(TESTS, "matrix.txt")) as f:
            lines = f.read().splitlines()
        for line in lines:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            with self.subTest(line=line):
                args = shlex.split(line)
                opts = dict(zip(args, args[1:]))
                self.assertIn(args[0], ("container", "vm", "host"))
                if args[0] == "container":
                    self.assertIn(opts.get("-d", "ubuntu-24.04"), distros)
                if args[0] == "vm":
                    profile = opts.get("-P", "ubuntu-gnome")
                    self.assertIn(profile, profiles)
                    sessions = self.sourced(f"vm_profile_info {profile}").split()[4].split(",")
                    if "-s" in opts:
                        self.assertIn(opts["-s"], sessions)

    def test_profiles_have_seeds(self):
        for profile in self.sourced("echo $VM_PROFILES").split():
            with self.subTest(profile=profile):
                info = self.sourced(f"vm_profile_info {profile}").split()
                seed = info[5] if len(info) > 5 else profile
                self.assertTrue(os.path.isfile(os.path.join(TESTS, "vm", "seeds", f"{seed}.yaml")))


class GuestProbes(unittest.TestCase):
    def test_gnome_windows_rows(self):
        windows = {
            7: {"wm-class": "dev.aunetx.deezer", "app-id": "deezer-desktop.desktop", "title": "Deezer",
                "client-type": 0, "is-hidden": False},
            8: {"wm-class": "deezer-desktop", "app-id": "window:3", "title": "Deezer", "client-type": 1},
            9: {"wm-class": "dev.aunetx.deezer", "title": "hidden", "is-hidden": True},
            10: {"wm-class": "org.gnome.Terminal", "app-id": "org.gnome.Terminal.desktop", "title": "tester"},
        }
        self.assertEqual(list(load("gnome_windows").rows(windows)), [
            "7\tdev.aunetx.deezer\tDeezer\twayland\tdeezer-desktop.desktop",
            "8\tdeezer-desktop\tDeezer\tx11\twindow:3",
        ])

    def test_toplevel_windows_wire_format(self):
        tl = load("toplevel_windows")
        # Events as the compositor sends them for two handles (3, 4), split across reads.
        wire = (tl.message(3, tl.HANDLE_IDENTIFIER, tl.string("a1b2"))
                + tl.message(3, tl.HANDLE_APP_ID, tl.string("dev.aunetx.deezer"))
                + tl.message(3, tl.HANDLE_TITLE, tl.string("Deezer"))
                + tl.message(4, tl.HANDLE_APP_ID, tl.string("com.system76.CosmicTerm"))
                + tl.message(4, tl.HANDLE_TITLE, tl.string("tester@vm")))
        first, rest = tl.split(wire[:21])
        self.assertEqual(first, [(3, tl.HANDLE_IDENTIFIER, tl.string("a1b2"))])
        msgs, rest = tl.split(rest + wire[21:])
        self.assertEqual((len(msgs), rest), (4, b""))
        handles = {3: {"id": "", "app_id": "", "title": ""}, 4: {"id": "", "app_id": "", "title": ""}}
        for obj, op, body in first + msgs:
            tl.update(handles, obj, op, body)
        self.assertEqual(list(tl.rows(handles)), ["a1b2\tdev.aunetx.deezer\tDeezer\tforeign-toplevel"])
        self.assertEqual(len(list(tl.rows(handles, show_all=True))), 2)
        tl.update(handles, 3, tl.HANDLE_CLOSED, b"")
        self.assertEqual(list(tl.rows(handles)), [])

    @unittest.skipUnless(importlib.util.find_spec("gi"), "needs PyGObject")
    def test_notify_monitor_rule_targets_the_server(self):
        rule = load("notify_probe").monitor_rule(":1.42")
        self.assertIn("member='Notify'", rule)
        self.assertTrue(rule.endswith("destination=':1.42'"))


class Scripts(unittest.TestCase):
    def test_shell_syntax(self):
        for path in [os.path.join(TESTS, "run.sh")] + glob.glob(os.path.join(TESTS, "lib", "**", "*.sh"),
                                                                    recursive=True):
            with self.subTest(script=os.path.relpath(path, TESTS)):
                subprocess.run(["bash", "-n", path], check=True)

    def test_python_syntax(self):
        for path in glob.glob(os.path.join(TESTS, "lib", "**", "*.py"), recursive=True):
            with self.subTest(script=os.path.relpath(path, TESTS)):
                with open(path, encoding="utf-8") as f:
                    compile(f.read(), path, "exec")


if __name__ == "__main__":
    unittest.main()
