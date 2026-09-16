from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "publish_release", Path(__file__).parents[1] / "scripts/publish_release.py"
)
publish = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publish)


class PublicReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.commit = "a" * 40
        self.metadata = []
        for (platform, architecture), name in publish.ASSETS.items():
            asset = self.root / name
            asset.write_bytes(f"{platform}-{architecture}".encode())
            metadata = self.root / (name + ".release.json")
            metadata.write_text(json.dumps({
                "product": "Zommi", "version": "0.1.0", "gitCommit": self.commit,
                "platform": platform, "architecture": architecture, "file": name,
                "sha256": hashlib.sha256(asset.read_bytes()).hexdigest(),
                "applicationSigning": {"status": "unsigned"}, "installerSigning": "unsigned",
            }))
            self.metadata.append(metadata)

    def test_all_installers_share_a_source_revision_and_public_manifest(self):
        paths, manifest = publish.collect_assets(self.metadata, self.commit)
        self.assertEqual(len(paths), 3)
        self.assertEqual(manifest["gitCommit"], self.commit)
        self.assertEqual({item["file"] for item in manifest["assets"]}, set(publish.ASSETS.values()))
        self.assertNotIn(str(self.root), json.dumps(manifest))

    def test_tampered_installer_is_rejected(self):
        (self.root / "Zommi-Setup-x64.exe").write_bytes(b"changed after acceptance")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            publish.collect_assets(self.metadata, self.commit)

    def test_mixed_revisions_are_rejected(self):
        path = self.metadata[1]
        value = json.loads(path.read_text())
        value["gitCommit"] = "b" * 40
        path.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError, "source revision"):
            publish.collect_assets(self.metadata, self.commit)

    def test_partial_platform_release_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "needs Windows"):
            publish.collect_assets(self.metadata[:1], self.commit)

    def test_duplicate_platform_and_unexpected_files_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "duplicate"):
            publish.collect_assets(self.metadata + self.metadata[:1], self.commit)
        path = self.metadata[0]
        value = json.loads(path.read_text())
        value["file"] = "../private-source.zip"
        path.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError, "filename"):
            publish.collect_assets(self.metadata, self.commit)


if __name__ == "__main__":
    unittest.main()
