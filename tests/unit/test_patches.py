"""Patches: every one is tracked by the smoke test, and documented fixes stay in."""
import json
import os
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest

from helpers import added_lines, patch_markers, patch_names


class Markers(unittest.TestCase):
    """patch-markers.txt is what the smoke test looks for in the running app.asar."""

    def test_every_patch_has_a_marker(self):
        self.assertEqual(sorted(patch_markers()), patch_names())

    def test_marker_is_added_by_its_patch(self):
        for name, marker in patch_markers().items():
            with self.subTest(patch=name):
                self.assertIn(marker, added_lines(name))


class DocumentedFixes(unittest.TestCase):
    def test_mpris_follows_the_page(self):
        # #250: metadata out of sync after launch. 8.x polls the page's player instead of waiting for events.
        code = added_lines("05-provide-metadata-mpris")
        self.assertIn("getCurrentSong()", code)
        self.assertRegex(code, r"setInterval\(update, \d+\)")
        self.assertIn('identity: "Deezer"', code)

    def test_sync_theme_reads_the_portal(self):
        # #238: Chromium ignores the portal color-scheme in Flatpak; the main process reads it.
        code = added_lines("15-sync-theme")
        self.assertIn('"org.freedesktop.portal.Settings"', code)
        self.assertIn('"org.freedesktop.appearance"', code)
        self.assertIn('"SettingChanged"', code)
        self.assertIn("nativeTheme.themeSource", code)

    def test_log_level_defaults_to_warn(self):
        # Deezer TOS: no track URLs in logs unless the user asks for it.
        self.assertRegex(added_lines("06-control-log-level"), r'DZ_LOG_LEVEL \|\|\s*"warn"')

    def test_injected_css_is_scoped_to_deezer(self):
        # 8.x loads the hosted web app: injections must not run on other origins.
        for name in ("07-improve-responsiveness", "08-hide-offline-banner", "09-disable-animations",
                     "12-adjust-volume-on-wheel"):
            with self.subTest(patch=name):
                self.assertIn("startsWith(`https://${this.domain}/`)", added_lines(name))

    def test_custom_theme_runs_in_an_isolated_world(self):
        self.assertIn("executeJavaScriptInIsolatedWorld", added_lines("16-custom-theme"))


@unittest.skipUnless(shutil.which("node"), "node is not installed")
class KernelVersion(unittest.TestCase):
    """Patch 04: the API rejects non-semver kernels (5.15.14-200.fc35.x86_64), so send 6.4.0."""

    def release(self, kernel, argv=(), env=None):
        body = added_lines("04-remove-os-information")
        body = body[body.index("var __module_os"):body.index("module.exports = __module_os;")]
        script = textwrap.dedent(f"""
            const fakeOs = {{ release: () => {json.dumps(kernel)} }};
            const require = () => fakeOs;
            const process = {{ argv: {json.dumps(["electron", "."] + list(argv))}, env: {json.dumps(env or {})} }};
            {body}
            console.log(__module_os.release());
        """)
        with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
            f.write(script)
        try:
            return subprocess.run(["node", f.name], capture_output=True, text=True, check=True).stdout.strip()
        finally:
            os.unlink(f.name)

    def test_hidden_by_default(self):
        self.assertEqual(self.release("5.15.14-200.fc35.x86_64"), "6.4.0")

    def test_keep_kernel_flag_keeps_semver_part(self):
        self.assertEqual(self.release("5.15.14-200.fc35.x86_64", ["--keep-kernel"]), "5.15.14")

    def test_keep_kernel_env(self):
        self.assertEqual(self.release("6.8.0-45-generic", env={"DZ_KEEP_KERNEL": "yes"}), "6.8.0")

    def test_keep_kernel_without_semver(self):
        self.assertEqual(self.release("6.8-rc1", ["--keep-kernel"]), "6.4.0")


if __name__ == "__main__":
    unittest.main()
