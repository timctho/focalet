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
                "product": "Focalet", "version": "0.1.0", "gitCommit": self.commit,
                "platform": platform, "architecture": architecture, "file": name,
                "sha256": hashlib.sha256(asset.read_bytes()).hexdigest(),
                "applicationSigning": {"status": "unsigned"}, "installerSigning": "unsigned",
            }))
            self.metadata.append(metadata)

    def test_all_installers_share_a_source_revision_and_public_manifest(self):
        paths, manifest = publish.collect_assets(self.metadata, self.commit)
        self.assertEqual(len(paths), len(publish.ASSETS))
        self.assertEqual(manifest["gitCommit"], self.commit)
        self.assertEqual({item["file"] for item in manifest["assets"]}, set(publish.ASSETS.values()))
        self.assertNotIn(str(self.root), json.dumps(manifest))

    def test_tampered_installer_is_rejected(self):
        (self.root / "Focalet-Setup-x64.exe").write_bytes(b"changed after acceptance")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            publish.collect_assets(self.metadata, self.commit)

    def test_selected_platforms_cannot_silently_publish_a_partial_build(self):
        windows_ubuntu = [self.metadata[0], self.metadata[-1]]
        paths, manifest = publish.collect_assets(windows_ubuntu, self.commit, platforms="windows-ubuntu")
        self.assertEqual({item["platform"] for item in manifest["assets"]}, {"windows", "linux"})
        self.assertEqual(len(paths), 2)
        for incomplete in ([], windows_ubuntu[:1], windows_ubuntu[1:], self.metadata):
            with self.assertRaisesRegex(ValueError, "selected platforms"):
                publish.collect_assets(incomplete, self.commit, platforms="windows-ubuntu")

    def test_all_platform_release_requires_both_mac_architectures_windows_and_ubuntu(self):
        paths, manifest = publish.collect_assets(self.metadata, self.commit, platforms="all")
        self.assertEqual(len(paths), 4)
        self.assertEqual({(item["platform"], item["architecture"]) for item in manifest["assets"]}, {
            ("windows", "x64"), ("linux", "x64"), ("macos", "arm64"), ("macos", "x64"),
        })
        for missing in self.metadata:
            with self.subTest(missing=missing.name), self.assertRaisesRegex(ValueError, "selected platforms"):
                publish.collect_assets([item for item in self.metadata if item != missing],
                                       self.commit, platforms="all")

    def test_mac_architecture_profiles_require_exactly_the_selected_installer(self):
        for index, architecture in ((1, "arm64"), (2, "x64")):
            metadata = self.metadata[index]
            profile = f"macos-{architecture}"
            with self.subTest(profile=profile):
                paths, manifest = publish.collect_assets([metadata], self.commit, platforms=profile)
                self.assertEqual([path.name for path in paths], [f"Focalet-macOS-{architecture}.dmg"])
                self.assertEqual([(a["platform"], a["architecture"]) for a in manifest["assets"]],
                                 [("macos", architecture)])
                for invalid in ([], self.metadata[1:3], [self.metadata[3 - index]], self.metadata):
                    with self.assertRaisesRegex(ValueError, "selected platforms"):
                        publish.collect_assets(invalid, self.commit, platforms=profile)
                with self.assertRaisesRegex(ValueError, "selected platforms"):
                    publish.collect_assets([metadata], self.commit, platforms="macos")

    def test_ubuntu_archive_version_must_match_publication_tag(self):
        path = self.metadata[-1]
        value = json.loads(path.read_text())
        value["releaseTag"] = "v0.1.0-preview.8"
        path.write_text(json.dumps(value))
        publish.collect_assets([path], self.commit, platforms="ubuntu", tag="v0.1.0-preview.8")
        with self.assertRaisesRegex(ValueError, "Ubuntu installer version"):
            publish.collect_assets([path], self.commit, platforms="ubuntu", tag="v0.1.0-preview.9")

    def test_windows_and_mac_source_version_cannot_be_relabelled(self):
        for path, profile in ((self.metadata[0], "windows"), (self.metadata[1], None)):
            value = json.loads(path.read_text())
            value["releaseTag"] = "v0.1.0-preview.8"
            path.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, "source version"):
                publish.collect_assets([path], self.commit, platforms=profile, tag="v0.1.0-preview.9")

    def test_stable_and_preview_tag_validation(self):
        publish.validate_tag("v0.1.0", "0.1.0", stable=True)
        publish.validate_tag("v0.1.0-preview.8", "0.1.0")
        for tag, stable in (("v0.2.0", False), ("v0.1.0-preview.8", True),
                            ("v0.1.0;echo bad", False), ("v0.1.0-", False)):
            with self.assertRaises(ValueError):
                publish.validate_tag(tag, "0.1.0", stable=stable)

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
        self.assertEqual([p.name for p in paths], ["Focalet-Setup-x64.exe"])
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
            publish.verify_destination("timctho/focalet", self.commit, "v0.1.0-preview.5")
        self.assertEqual(gh.call_args_list[0].args,
                         ("api", f"repos/timctho/focalet/commits/{self.commit}"))

    def test_preview_digit_boundary_requires_a_patch_bump(self):
        existing = ["v0.1.0-preview.8", "v0.1.0-preview.9", "v0.1.0-preview.11"]
        with self.assertRaisesRegex(ValueError, "Increase the numeric patch"):
            publish.validate_release_order("v0.1.0-preview.12", existing)
        publish.validate_release_order("v0.1.1-preview.1", existing)
        publish.validate_release_order("v0.1.0", existing)

    def test_release_order_handles_resumed_tags_stable_versions_and_unrelated_tags(self):
        publish.validate_release_order("v0.1.1-preview.1", [
            "v0.1.1-preview.1", "macos-test-abcdef-x64", "v0.1.0",
        ])
        publish.validate_release_order("v0.1.10-preview.1", ["v0.1.9-preview.9"])
        publish.validate_release_order("v0.1.1-preview.2", ["v0.1.1-preview.1"])
        for tag, existing in (("v0.1.1-preview.1", "v0.1.1"),
                              ("v0.1.1", "v0.1.2-preview.1")):
            with self.subTest(tag=tag), self.assertRaisesRegex(ValueError, "GitHub can sort"):
                publish.validate_release_order(tag, [existing])

    def test_destination_checks_order_before_publication(self):
        with patch.object(publish, "gh", side_effect=[
            json.dumps({"sha": self.commit}),
            json.dumps([[{"name": "v0.1.0-preview.9", "commit": {"sha": self.commit}}]]),
        ]):
            with self.assertRaisesRegex(ValueError, "GitHub can sort"):
                publish.verify_destination("timctho/focalet", self.commit, "v0.1.0-preview.10")

    def test_release_cannot_use_a_tag_or_source_for_different_binaries(self):
        with patch.object(publish, "gh", return_value=json.dumps({"sha": "b" * 40})):
            with self.assertRaisesRegex(ValueError, "exact installer source"):
                publish.verify_destination("timctho/focalet", self.commit, "v0.1.0-preview.5")
        with patch.object(publish, "gh", side_effect=[
            json.dumps({"sha": self.commit}),
            json.dumps([[{"name": "v0.1.0-preview.5", "commit": {"sha": "b" * 40}}]]),
        ]):
            with self.assertRaisesRegex(ValueError, "tag points to a different"):
                publish.verify_destination("timctho/focalet", self.commit, "v0.1.0-preview.5")

    def run_windows_publication(self, *, tamper_digest=False, stable=False):
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
                    uploaded["Focalet-Setup-x64.exe"] = "sha256:" + "0" * 64
            if args[:2] == ("release", "view"):
                if "assets" in args:
                    return json.dumps({"assets": [{"name": n, "digest": h} for n, h in uploaded.items()]})
                return "https://github.com/timctho/focalet/releases/tag/v0.1.0-preview.5"
            return ""

        argv = ["publish_release.py", "--tag", "v0.1.0" if stable else "v0.1.0-preview.5",
                "--expected-commit", self.commit, "--metadata", str(self.metadata[0]),
                "--windows-only", "--output", str(output), "--publish"]
        if stable:
            argv.append("--stable")
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
            self.assertEqual(call[call.index("--repo") + 1], "timctho/focalet")
            self.assertEqual(call[call.index("--target") + 1], self.commit)
        self.assertNotIn("Mac:", (output / "release-notes.md").read_text())
        self.assertIn("timctho/focalet/releases/download/", (output / "release-notes.md").read_text())
        self.assertFalse(any("--visibility" in c for c in calls))

    def test_upload_digest_mismatch_leaves_the_release_unpublished(self):
        calls, _ = self.run_windows_publication(tamper_digest=True)
        self.assertFalse(any(c[:2] == ("release", "edit") for c in calls))

    def test_stable_publication_is_latest_and_preview_is_not(self):
        for stable in (False, True):
            calls, _ = self.run_windows_publication(stable=stable)
            edit = next(c for c in calls if c[:2] == ("release", "edit"))
            self.assertIn(f"--latest={'true' if stable else 'false'}", edit)
            self.assertIn(f"--prerelease={'false' if stable else 'true'}", edit)

    def test_ubuntu_build_only_prepares_install_instructions_without_github_writes(self):
        metadata = self.metadata[-1]
        value = json.loads(metadata.read_text())
        value["releaseTag"] = "v0.1.0-preview.8"
        metadata.write_text(json.dumps(value))
        output = self.root / "ubuntu-release"
        argv = ["publish_release.py", "--tag", value["releaseTag"], "--expected-commit", self.commit,
                "--platforms", "ubuntu", "--metadata", str(metadata), "--output", str(output)]
        with patch("sys.argv", argv), patch("builtins.print"), patch.object(publish, "gh") as github:
            self.assertEqual(publish.main(), 0)
            github.assert_not_called()
        notes = (output / "release-notes.md").read_text()
        self.assertIn("sudo apt install ./Focalet-Ubuntu-amd64.deb", notes)
        self.assertNotIn("Windows: run Setup", notes)

    def test_published_release_cannot_be_overwritten(self):
        argv = ["publish_release.py", "--tag", "v0.1.0-preview.8", "--expected-commit", self.commit,
                "--windows-only", "--metadata", str(self.metadata[0]),
                "--output", str(self.root / "release"), "--publish"]
        with patch("sys.argv", argv), patch.object(publish, "verify_destination"), \
                patch.object(publish.subprocess, "run", return_value=SimpleNamespace(
                    returncode=0, stdout=json.dumps({"isDraft": False, "assets": []}))), \
                patch.object(publish, "gh") as github:
            with self.assertRaisesRegex(ValueError, "overwrite a published"):
                publish.main()
            github.assert_not_called()

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
