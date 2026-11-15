"""The test tooling itself: redaction, desktop linking rules, matrix, scripts."""
import glob
import importlib.util
import os
import re
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

    def test_startup_wm_class_only_is_a_known_issue(self):
        # What the .deb installs: GNOME links it, shells that look up "<app_id>.desktop" do not (#156).
        self.install("deezer-desktop.desktop", "dev.aunetx.deezer")
        out = self.run_probe("--class", "dev.aunetx.deezer")
        self.assertIn("TASKBAR_LINK=deezer-desktop.desktop", out)
        self.assertIn("TASKBAR_LINK_BY=StartupWMClass", out)
        self.assertIn("FAIL [desktop-id] window 'dev.aunetx.deezer'", out)
        self.assertNotIn("matches no desktop entry", out)

    def test_window_links_through_desktop_id(self):
        self.install("dev.aunetx.deezer.desktop", "dev.aunetx.deezer")  # what the Flatpak exports
        out = self.run_probe("--class", "dev.aunetx.deezer")
        self.assertIn("TASKBAR_LINK=dev.aunetx.deezer.desktop", out)
        self.assertIn("TASKBAR_LINK_BY=file-name", out)
        self.assertNotIn("[desktop-id]", out)

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
        self.assertIn("FAIL [desktop-id] MPRIS DesktopEntry 'deezer-desktop'", out)
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


class Determinism(unittest.TestCase):
    """Runs wait for signals with a deadline, never for a fixed time."""

    def test_no_fixed_sleeps(self):
        files = [os.path.join(TESTS, "run.sh")] + glob.glob(os.path.join(TESTS, "lib", "**", "*.*"), recursive=True)
        for path in files:
            if not path.endswith((".sh", ".py")):
                continue
            with open(path, encoding="utf-8") as f:
                for n, line in enumerate(f, 1):
                    code = line.split("#", 1)[0] if path.endswith(".sh") else line
                    if not re.search(r"\bsleep\b|time\.sleep\(", code):
                        continue
                    with self.subTest(where=f"{os.path.relpath(path, TESTS)}:{n}"):
                        # Allowed: the poll interval of a wait with a deadline, and holding for debugging.
                        self.assertTrue("# poll interval" in line or "sleep infinity" in line, line.strip())

    def bash(self, script):
        return subprocess.run(["bash", "-c", f'. "{TESTS}/lib/common.sh"; {script}'], capture_output=True, text=True)

    def test_wait_until(self):
        self.assertEqual(self.bash("wait_until 5 true").returncode, 0)
        self.assertEqual(self.bash("wait_until 1 false").returncode, 1)
        self.assertEqual(self.bash("f=$(mktemp -u); (sleep 1; touch $f) & wait_until 5 test -e $f; r=$?; rm -f $f; exit $r")
                         .returncode, 0)

    def test_smoke_waits(self):
        # wait_for / holds_for from smoke.sh, extracted so they run without a display.
        script = textwrap.dedent(f"""\
            OUT=$(mktemp -d); source <(sed -n '/^usec()/,/^in_log()/p' "{GUEST}/smoke.sh")
            wait_for up 2 true; echo "up $?"
            wait_for never 1 false; echo "never $?"
            holds_for hidden 1 false; echo "hidden $?"
            holds_for shown 1 true; echo "shown $?"
            cat "$OUT/waits.log"; rm -r "$OUT"
            """)
        out = subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=True).stdout
        for line in ("up 0", "never 1", "hidden 0", "shown 1", "never timeout 1s", "hidden held 1s", "shown broken after"):
            self.assertIn(line, out)

    def test_verdict_known(self):
        with tempfile.TemporaryDirectory() as d:
            for result, code in (("pass", 0), ("known", 0), ("fail", 1)):
                with self.subTest(result=result):
                    with open(os.path.join(d, "result.env"), "w") as f:
                        f.write(f"RESULT={result}\nKNOWN_ISSUES=[desktop-id] x\nFAILURES=\n")
                    r = self.bash(f'verdict "{d}"')
                    self.assertEqual(r.returncode, code)
                    self.assertIn({"pass": "PASS", "known": "KNOWN", "fail": "FAIL"}[result], r.stdout)

    def test_known_issue_ids_are_used(self):
        with open(os.path.join(GUEST, "known-issues.txt"), encoding="utf-8") as f:
            ids = [line.split()[0] for line in f if line.strip() and not line.startswith("#")]
        self.assertTrue(ids)
        sources = ""
        for path in glob.glob(os.path.join(GUEST, "*.py")) + glob.glob(os.path.join(GUEST, "*.sh")):
            with open(path, encoding="utf-8") as f:
                sources += f.read()
        for known in ids:
            with self.subTest(id=known):
                self.assertRegex(known, r"^[a-z0-9-]+$")
                self.assertIn(f"[{known}]", sources, "a known issue that no check reports: remove it")

    @unittest.skipUnless(os.path.isfile(os.path.join(TESTS, "..", "app", "build", "main.js")), "needs make prepare")
    def test_window_show_fallback(self):
        # smoke.sh SHOW_FALLBACK mirrors the app's fallback that shows the window without ready-to-show.
        with open(os.path.join(TESTS, "..", "app", "build", "main.js"), encoding="utf-8") as f:
            self.assertRegex(f.read(), r"isVisible\(\)[^;]*?show\(\)\);?\s*\},\s*1e4\)")
        with open(os.path.join(GUEST, "smoke.sh"), encoding="utf-8") as f:
            self.assertIn("SHOW_FALLBACK=10\n", f.read())


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
