from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

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

    def test_explicit_windows_preview_includes_only_the_accepted_installer(self):
        paths, manifest = publish.collect_assets(self.metadata[:1], self.commit, windows_only=True)
        self.assertEqual([p.name for p in paths], ["Zommi-Setup-x64.exe"])
        self.assertEqual([a["platform"] for a in manifest["assets"]], ["windows"])
        for invalid in ([], self.metadata[1:], self.metadata):
            with self.subTest(metadata=invalid), self.assertRaisesRegex(ValueError, "exactly the Windows"):
                publish.collect_assets(invalid, self.commit, windows_only=True)

    def test_source_repository_with_matching_commit_and_tag_is_accepted(self):
        # This guard needs source identity, not a public-only visibility gate.
        with patch.object(publish, "gh", side_effect=[
            json.dumps({"sha": self.commit}),
            json.dumps([[], [{"name": "v0.1.0-preview.5", "commit": {"sha": self.commit}}]]),
        ]) as gh:
            publish.verify_destination("timctho/zommi", self.commit, "v0.1.0-preview.5")
        self.assertEqual(gh.call_args_list[0].args,
                         ("api", f"repos/timctho/zommi/commits/{self.commit}"))

    def test_release_cannot_use_a_tag_or_source_for_different_binaries(self):
        with patch.object(publish, "gh", return_value=json.dumps({"sha": "b" * 40})):
            with self.assertRaisesRegex(ValueError, "exact installer source"):
                publish.verify_destination("timctho/zommi", self.commit, "v0.1.0-preview.5")
        with patch.object(publish, "gh", side_effect=[
            json.dumps({"sha": self.commit}),
            json.dumps([[{"name": "v0.1.0-preview.5", "commit": {"sha": "b" * 40}}]]),
        ]):
            with self.assertRaisesRegex(ValueError, "tag points to a different"):
                publish.verify_destination("timctho/zommi", self.commit, "v0.1.0-preview.5")

    def run_windows_publication(self, *, tamper_digest=False):
        calls, uploaded = [], {}
        output = self.root / "release"

        def github(*args):
            calls.append(args)
            if args[:2] == ("api", "--paginate"):
                return "[[]]"
            if args[0] == "api":
                return json.dumps({"sha": self.commit})
            if args[:2] == ("release", "upload"):
                for path in args[5:-1]:
                    p = Path(path)
                    uploaded[p.name] = "sha256:" + hashlib.sha256(p.read_bytes()).hexdigest()
                if tamper_digest:
                    uploaded["Zommi-Setup-x64.exe"] = "sha256:" + "0" * 64
            if args[:2] == ("release", "view"):
                if "assets" in args:
                    return json.dumps({"assets": [{"name": n, "digest": h} for n, h in uploaded.items()]})
                return "https://github.com/timctho/zommi/releases/tag/v0.1.0-preview.5"
            return ""

        argv = ["publish_release.py", "--tag", "v0.1.0-preview.5",
                "--expected-commit", self.commit, "--metadata", str(self.metadata[0]),
                "--windows-only", "--output", str(output), "--publish"]
        with patch("sys.argv", argv), patch("builtins.print"), patch.object(publish, "gh", side_effect=github), \
                patch.object(publish.subprocess, "run", return_value=SimpleNamespace(returncode=1)):
            if tamper_digest:
                with self.assertRaisesRegex(ValueError, "digests differ"):
                    publish.main()
            else:
                self.assertEqual(publish.main(), 0)
        return calls, output

    def test_windows_publication_uses_source_repo_and_exact_commit(self):
        calls, output = self.run_windows_publication()
        for operation in ("create", "edit"):
            call = next(c for c in calls if c[:2] == ("release", operation))
            self.assertEqual(call[call.index("--repo") + 1], "timctho/zommi")
            self.assertEqual(call[call.index("--target") + 1], self.commit)
        self.assertNotIn("Mac:", (output / "release-notes.md").read_text())
        self.assertIn("timctho/zommi/releases/download/", (output / "release-notes.md").read_text())
        self.assertFalse(any("--visibility" in c for c in calls))

    def test_upload_digest_mismatch_leaves_the_release_unpublished(self):
        calls, _ = self.run_windows_publication(tamper_digest=True)
        self.assertFalse(any(c[:2] == ("release", "edit") for c in calls))

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
