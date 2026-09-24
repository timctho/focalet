"""The committed app version determines tags, native versions and channel."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import assemble_release
import build_installer
from release_version import read_version


class ReleaseVersionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.pubspec = self.root / "src/Zommi.Flutter/pubspec.yaml"
        self.pubspec.parent.mkdir(parents=True)

    def version(self, value):
        self.pubspec.write_text(f"name: fixture\nversion: {value}\n")
        return read_version(self.pubspec)

    def test_preview_build_metadata_and_stable_versions(self):
        self.assertEqual(self.version("0.1.0-preview.8+17"), {
            "version": "0.1.0", "releaseVersion": "0.1.0-preview.8",
            "tag": "v0.1.0-preview.8", "prerelease": True, "buildNumber": "17",
        })
        stable = self.version("2.3.4+18")
        self.assertEqual(stable["tag"], "v2.3.4")
        self.assertFalse(stable["prerelease"])
        self.assertEqual(self.version("2.3.4")["buildNumber"], "1")
        self.assertEqual(self.version("0.1.0-preview.8+99")["tag"], "v0.1.0-preview.8")

    def test_invalid_and_ambiguous_versions_fail_before_any_release(self):
        for value in ("v0.1.0", "01.2.3", "0.1.0-", "0.1.0-preview..8", "0.1.0-preview.08",
                      "0.1.0+x", "0.1.0+01", "0.1.0;echo", "0.1.0\nversion: 9.9.9"):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "pubspec.yaml"):
                self.version(value)
        self.pubspec.write_text("name: fixture\n")
        with self.assertRaises(ValueError):
            read_version(self.pubspec)

    def test_native_package_version_tracks_source_instead_of_a_constant(self):
        self.version("2.3.4-preview.2+19")
        package = self.root / "package"
        package.mkdir()
        with patch.object(assemble_release, "REPOSITORY", self.root):
            assemble_release._write_manifest(
                package, target_platform="linux", architecture="x64", commit="a" * 40,
                entrypoint="zommi", core_host="zommi-core-host", capture_host="zommi-linux-capture",
                signing={"status": "unsigned", "mechanism": "none"},
            )
        manifest = json.loads((package / "release-manifest.json").read_text())
        self.assertEqual(manifest["version"], "2.3.4")
        self.assertEqual(manifest["releaseTag"], "v2.3.4-preview.2")

    def test_installer_uses_packaged_source_tag_and_rejects_relabelling(self):
        package = self.root / "package"
        package.mkdir()
        tag = "v2.3.4-preview.2"
        manifest = {"version": "2.3.4", "releaseTag": tag, "architecture": "x64",
                    "platform": "linux", "signing": {"status": "unsigned"}}
        (package / "release-manifest.json").write_text(json.dumps(manifest))
        output = self.root / "installers"
        output.mkdir()
        asset = output / "Zommi-Ubuntu-amd64.deb"
        asset.write_bytes(b"verified installer fixture")
        argv = ["build_installer.py", str(package), "--expected-commit", "a" * 40, "--output", str(output)]
        with patch("sys.argv", argv), patch.object(build_installer, "verify_package"), \
                patch.object(build_installer, "ubuntu_installer", return_value=asset) as build, \
                patch("builtins.print"):
            self.assertEqual(build_installer.main(), 0)
        self.assertEqual(build.call_args.args[-1], tag)
        metadata = json.loads(asset.with_name(asset.name + ".release.json").read_text())
        self.assertEqual(metadata["releaseTag"], tag)
        with patch("sys.argv", argv + ["--release-tag", "v2.3.4-preview.3"]), \
                patch.object(build_installer, "verify_package") as verify:
            with self.assertRaisesRegex(ValueError, "packaged source version"):
                build_installer.main()
            verify.assert_not_called()


if __name__ == "__main__":
    unittest.main()
