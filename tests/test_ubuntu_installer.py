"""Exercise actual Debian archives and dpkg in a disposable installation root."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from ubuntu_installer import debian_version, payload_identity, ubuntu_installer


@unittest.skipUnless(shutil.which("dpkg-deb"), "Debian packaging tools required")
class UbuntuInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="focalet-deb-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.package, self.output = self.root / "package", self.root / "output"
        self.package.mkdir()
        self.package.chmod(0o700)
        self.output.mkdir()
        for name in ("focalet", "focalet-bin", "focalet-core-host", "focalet-linux-capture"):
            path = self.package / name
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o755)
        (self.package / "LICENSE").write_text("Apache-2.0 fixture")
        icon = self.package / "data/flutter_assets/assets/branding/app-icon.png"
        icon.parent.mkdir(parents=True)
        icon.write_bytes(b"icon fixture")
        (self.package / "lib").mkdir()
        (self.package / "lib/libsqlite3.so.0").write_bytes(b"library fixture")
        (self.package / "lib/libsqlite3.so").symlink_to("libsqlite3.so.0")
        extension = self.package / 'gnome-extension/focalet@focalet/schemas'
        extension.mkdir(parents=True)
        (extension / 'gschemas.compiled').write_bytes(b'schema fixture')
        self.manifest = {"platform": "linux", "architecture": "x64", "version": "0.1.0", "gitCommit": "a" * 40}

    def build(self, tag="v0.1.0-preview.8"):
        return ubuntu_installer(self.package, self.output, self.manifest, tag)

    def test_archive_retains_bundle_links_modes_and_launcher(self):
        before = payload_identity(self.package)
        asset = self.build()
        extracted = self.root / "extracted"
        subprocess.run(["dpkg-deb", "-x", str(asset), str(extracted)], check=True)
        self.assertEqual(payload_identity(extracted / "opt/focalet"), before)
        self.assertEqual((extracted / "opt/focalet").stat().st_mode & 0o777, 0o755)
        self.assertEqual(self.package.stat().st_mode & 0o777, 0o700)
        self.assertEqual(payload_identity(self.package), before)
        self.assertFalse((extracted / "usr/bin/focalet").is_symlink())
        self.assertIn('exec /opt/focalet/focalet "$@"', (extracted / "usr/bin/focalet").read_text())
        self.assertTrue(os.access(extracted / "usr/bin/focalet", os.X_OK))
        entry = (extracted / "usr/share/applications/com.focalet.desktop.desktop").read_text()
        self.assertIn("Exec=/usr/bin/focalet\n", entry)
        self.assertIn("Icon=focalet\n", entry)
        fields = subprocess.check_output(["dpkg-deb", "-f", str(asset)], text=True)
        for value in ("Architecture: amd64", "Version: 0.1.0~preview.8", "libc6 (>= 2.39)",
                      "libstdc++6 (>= 13.2)", "libgtk-3-0t64", "Ubuntu 24.04 LTS x64"):
            self.assertIn(value, fields)

    def test_dpkg_install_upgrade_and_remove_preserve_user_files(self):
        install = self.root / "system"
        database = install / "var/lib/dpkg"
        database.mkdir(parents=True)
        (database / "status").touch()
        for name in ("updates", "info", "triggers"):
            (database / name).mkdir()
        command = ["dpkg", f"--root={install}", f"--admindir={database}",
                   f"--log={self.root / 'dpkg.log'}", "--force-not-root", "--force-bad-path", "--force-depends"]

        def dpkg(*args):
            result = subprocess.run([*command, *map(str, args)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        dpkg("--install", self.build())
        settings = install / "home/user/.config/focalet/settings.json"
        settings.parent.mkdir(parents=True)
        settings.write_text('{"themeColor":"ocean"}')
        unrelated = install / "opt/focalet/keep-me.txt"
        unrelated.write_text("user file")
        (self.package / "focalet-bin").write_text("#!/bin/sh\n# upgraded\nexit 0\n")
        dpkg("--install", self.build("v0.1.0-preview.9"))
        self.assertIn("upgraded", (install / "opt/focalet/focalet-bin").read_text())
        dpkg("--purge", "focalet")
        for name in ("opt/focalet/focalet", "usr/bin/focalet", "usr/share/applications/com.focalet.desktop.desktop"):
            self.assertFalse((install / name).exists())
        self.assertEqual(unrelated.read_text(), "user file")
        self.assertEqual(settings.read_text(), '{"themeColor":"ocean"}')

    def test_external_links_and_unsupported_architectures_are_rejected(self):
        (self.package / "private").symlink_to(self.root / "secret")
        with self.assertRaisesRegex(ValueError, "symlinks"):
            self.build()
        (self.package / "private").unlink()
        self.manifest["architecture"] = "arm64"
        with self.assertRaisesRegex(ValueError, "x64"):
            self.build()

    def test_preview_versions_upgrade_in_order_and_before_stable(self):
        values = [debian_version("0.1.0", tag, "a" * 40) for tag in
                  ("v0.1.0-preview.8", "v0.1.0-preview.9", "v0.1.0-preview.10", "v0.1.0")]
        for earlier, later in zip(values, values[1:]):
            subprocess.run(["dpkg", "--compare-versions", earlier, "lt", later], check=True)
        for tag in ("v0.2.0", "v0.1.0-", "v0.1.0-x\nBad: value"):
            with self.assertRaises(ValueError):
                debian_version("0.1.0", tag, "a" * 40)


if __name__ == "__main__":
    unittest.main()
