"""Only version changes or manual dispatches build a complete release."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("release_workflow", ROOT / "scripts/release_workflow.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseWorkflowTests(unittest.TestCase):
    def test_plan_and_publication_derive_identity_without_user_tag_or_channel(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pubspec = root / "src/Zommi.Flutter/pubspec.yaml"
            pubspec.parent.mkdir(parents=True)
            output = root / "outputs"
            environment = {
                "GITHUB_EVENT_NAME": "workflow_dispatch",
                "GITHUB_REF": "refs/heads/main", "GITHUB_SHA": "a" * 40,
                "GITHUB_OUTPUT": str(output), "GITHUB_REPOSITORY": "timctho/zommi",
                "RELEASE_PLATFORMS": "windows-ubuntu", "RELEASE_PUBLISH": "true",
                # Old caller values must never override the committed version.
                "RELEASE_TAG": "v9.9.9", "RELEASE_PRERELEASE": "false",
            }
            for version, tag, stable in (("0.1.0-preview.8+1", "v0.1.0-preview.8", False),
                                         ("2.3.4+2", "v2.3.4", True)):
                pubspec.write_text(f"version: {version}\n")
                output.write_text("")
                with patch.object(release, "ROOT", root), patch.dict(release.os.environ, environment, clear=True), \
                        patch.object(release.subprocess, "check_output", return_value="a" * 40), \
                        patch("builtins.print"):
                    with patch("sys.argv", ["release_workflow.py", "plan"]):
                        release.main()
                    self.assertIn(f"tag={tag}\n", output.read_text())
                    self.assertIn(f"prerelease={str(not stable).lower()}\n", output.read_text())
                    with patch("sys.argv", ["release_workflow.py", "release"]), \
                            patch.object(release.subprocess, "run") as publish:
                        release.main()
                    command = publish.call_args.args[0]
                    self.assertEqual(command[command.index("--tag") + 1], tag)
                    self.assertEqual("--stable" in command, stable)
                    self.assertIn("--publish", command)

    def test_dispatch_rejects_other_branches_and_wrong_source_revision(self):
        with patch("sys.argv", ["release_workflow.py", "plan"]):
            with patch.dict(release.os.environ, {"GITHUB_REF": "refs/heads/unreviewed"}):
                with self.assertRaisesRegex(ValueError, "from main"):
                    release.main()
            with patch.dict(release.os.environ, {"GITHUB_REF": "refs/heads/main", "GITHUB_SHA": "b" * 40}), \
                    patch.object(release.subprocess, "check_output", return_value="a" * 40):
                with self.assertRaisesRegex(ValueError, "exact source"):
                    release.main()

    def test_profile_plans_match_publishers_exact_target_sets(self):
        for profile, expected in release.PROFILES.items():
            entries = release.plan(profile, "v0.1.0-preview.8", "0.1.0")["include"]
            self.assertEqual({(x["platform"], x["architecture"]) for x in entries}, expected)
            self.assertTrue(all(x["os"] != "self-hosted" for x in entries))
        with self.assertRaises(ValueError):
            release.plan("not-a-platform", "v0.1.0", "0.1.0")

    def test_workflow_builds_without_write_access_and_publishes_after_success(self):
        raw = (ROOT / ".github/workflows/release.yml").read_text()
        workflow = yaml.load(raw, Loader=yaml.BaseLoader)
        self.assertEqual(set(workflow["on"]), {"push", "workflow_dispatch"})
        self.assertEqual(workflow["on"]["push"], {
            "branches": ["main"], "paths": ["src/Zommi.Flutter/pubspec.yaml"],
        })
        self.assertEqual(set(workflow["on"]["workflow_dispatch"]["inputs"]), {"platforms", "publish"})
        self.assertEqual(workflow["on"]["workflow_dispatch"]["inputs"]["platforms"]["default"], "all")
        self.assertEqual(set(workflow["on"]["workflow_dispatch"]["inputs"]["platforms"]["options"]),
                         set(release.PROFILES))
        self.assertEqual(workflow["permissions"], {"contents": "read"})
        self.assertNotIn("self-hosted", raw)
        self.assertNotIn("secrets.", raw)
        self.assertEqual(workflow["concurrency"]["cancel-in-progress"], "false")
        self.assertIn("github.sha", workflow["concurrency"]["group"])
        jobs = workflow["jobs"]
        self.assertEqual(jobs["build"]["if"], "needs.plan.outputs.build == 'true'")
        self.assertEqual(jobs["plan"]["steps"][0]["with"]["fetch-depth"], "0")
        self.assertNotIn("permissions", jobs["build"])
        self.assertEqual(set(jobs["release"]["needs"]), {"plan", "build"})
        self.assertNotIn("if", jobs["release"])
        self.assertEqual(jobs["release"]["permissions"], {"contents": "write", "actions": "read"})
        steps = jobs["release"]["steps"]
        gate_index = next(i for i, step in enumerate(steps) if "verify_ci_gate.py" in step.get("run", ""))
        publish_index = next(i for i, step in enumerate(steps) if "release_workflow.py release" in step.get("run", ""))
        self.assertLess(gate_index, publish_index)
        gate = steps[gate_index]
        self.assertEqual(gate["if"], "needs.plan.outputs.publish == 'true'")
        self.assertIn('--repository "$GITHUB_REPOSITORY" --commit "$GITHUB_SHA"', gate["run"])
        self.assertEqual(gate["env"]["GH_TOKEN"], "${{ github.token }}")
        self.assertIn("needs.plan.outputs.tag", jobs["release"]["concurrency"]["group"])
        self.assertEqual(jobs["release"]["concurrency"]["cancel-in-progress"], "false")
        for field in ("platforms", "publish"):
            self.assertEqual(jobs["release"]["env"][f"RELEASE_{field.upper()}"],
                             "${{ needs.plan.outputs." + field + " }}")
        for job in jobs.values():
            self.assertNotIn("continue-on-error", job)
            for step in job["steps"]:
                if "uses" in step:
                    self.assertRegex(step["uses"], r"^[\w-]+/[\w-]+@[0-9a-f]{40}$")
                if "run" in step:
                    self.assertNotIn("${{ inputs.", step["run"])
                self.assertNotIn("continue-on-error", step)


class ReleasePushTests(unittest.TestCase):
    """Exercise the event/checkout boundary against real multi-commit history."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.root = self.directory / "repository"
        self.root.mkdir()
        self.git("init", "-q", "-b", "main")
        self.pubspec = self.root / release.VERSION_FILE
        self.pubspec.parent.mkdir(parents=True)
        self.before = self.commit("0.1.0-preview.8+1")
        self.output = self.directory / "outputs"
        self.event_path = self.directory / "event.json"

    def git(self, *arguments):
        return subprocess.check_output(["git", *arguments], cwd=self.root, text=True,
                                       stderr=subprocess.PIPE).strip()

    def commit(self, version, *, description="Test release"):
        self.pubspec.write_text(f"name: zommi\ndescription: {description}\nversion: {version}\n")
        self.git("add", release.VERSION_FILE)
        self.git("-c", "user.name=Release Test", "-c", "user.email=release@example.invalid",
                 "-c", "commit.gpgsign=false",
                 "commit", "-qm", "Update app")
        return self.git("rev-parse", "HEAD")

    def run_plan(self, *, event=None, event_name="push", manual_publish="false"):
        commit = self.git("rev-parse", "HEAD")
        self.event_path.write_text(json.dumps(event if event is not None else {
            "before": self.before, "after": commit,
        }))
        self.output.write_text("")
        environment = {
            "GITHUB_EVENT_NAME": event_name, "GITHUB_EVENT_PATH": str(self.event_path),
            "GITHUB_REF": "refs/heads/main", "GITHUB_SHA": commit,
            "GITHUB_OUTPUT": str(self.output),
            "RELEASE_PLATFORMS": "macos", "RELEASE_PUBLISH": manual_publish,
        }
        with patch.object(release, "ROOT", self.root), \
                patch.dict(release.os.environ, environment), \
                patch("sys.argv", ["release_workflow.py", "plan"]), patch("builtins.print"):
            release.main()
        return dict(line.split("=", 1) for line in self.output.read_text().splitlines())

    def test_version_bump_automatically_publishes_every_platform_and_architecture(self):
        self.commit("0.1.0-preview.9+2")
        outputs = self.run_plan()
        self.assertEqual(outputs["build"], "true")
        self.assertEqual(outputs["publish"], "true")
        self.assertEqual(outputs["platforms"], "all")
        self.assertEqual(outputs["tag"], "v0.1.0-preview.9")
        self.assertEqual(outputs["prerelease"], "true")
        entries = json.loads(outputs["matrix"])["include"]
        self.assertEqual(len(entries), 4)
        self.assertEqual({(item["platform"], item["architecture"], item["os"], item["asset"])
                          for item in entries}, {
            ("windows", "x64", "windows-2025", "Zommi-Setup-x64.exe"),
            ("linux", "x64", "ubuntu-24.04", "Zommi-Ubuntu-amd64.deb"),
            ("macos", "arm64", "macos-15", "Zommi-macOS-arm64.dmg"),
            ("macos", "x64", "macos-15-intel", "Zommi-macOS-x64.dmg"),
        })

    def test_build_number_only_and_other_pubspec_changes_skip(self):
        for version in ("0.1.0-preview.8+2", "0.1.0-preview.8"):
            with self.subTest(version=version):
                self.commit(version)
                self.assertEqual(self.run_plan()["build"], "false")
        self.commit("0.1.0-preview.8+1", description="Only the description changed")
        self.assertEqual(self.run_plan()["build"], "false")

    def test_stable_version_and_next_patch_are_releases(self):
        for version in ("0.1.0+2", "0.1.1+3"):
            with self.subTest(version=version):
                self.commit(version)
                outputs = self.run_plan()
                self.assertEqual(outputs["build"], "true")
                self.assertEqual(outputs["prerelease"], "false")

    def test_multi_commit_push_compares_event_before_not_last_parent(self):
        self.commit("0.1.0-preview.9+2")
        self.commit("0.1.0-preview.9+2", description="Another commit in the same push")
        self.assertEqual(self.run_plan()["build"], "true")

    def test_reverted_bump_within_one_push_does_not_release(self):
        self.commit("0.1.0-preview.9+2")
        self.commit("0.1.0-preview.8+1")
        self.assertEqual(self.run_plan()["build"], "false")

    def test_main_advancing_does_not_change_the_event_checkout_release(self):
        candidate = self.commit("0.1.0-preview.9+2")
        self.commit("0.1.0-preview.10+3")
        self.git("checkout", "--detach", candidate)
        self.assertEqual(self.run_plan()["tag"], "v0.1.0-preview.9")

    def test_manual_build_and_publish_work_without_a_version_bump(self):
        for publish in ("false", "true"):
            with self.subTest(publish=publish):
                outputs = self.run_plan(event_name="workflow_dispatch", manual_publish=publish)
                self.assertEqual(outputs["build"], "true")
                self.assertEqual(outputs["platforms"], "macos")
                self.assertEqual(outputs["publish"], publish)
        with self.assertRaisesRegex(ValueError, "publish switch"):
            self.run_plan(event_name="workflow_dispatch", manual_publish="invalid")

    def test_mismatched_or_missing_push_history_fails_before_any_output(self):
        candidate = self.commit("0.1.0-preview.9+2")
        for before in ("", "0" * 40, "main;echo", None):
            with self.subTest(before=before), self.assertRaisesRegex(ValueError, "existing main"):
                self.run_plan(event={"before": before, "after": candidate})
            self.assertEqual(self.output.read_text(), "")
        with self.assertRaisesRegex(ValueError, "exact source"):
            self.run_plan(event={"before": self.before, "after": "b" * 40})
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_plan(event={"before": "f" * 40, "after": candidate})
        self.assertEqual(self.output.read_text(), "")

    def test_invalid_previous_or_current_version_cannot_authorize_publication(self):
        self.commit("not-a-version")
        with self.assertRaises(ValueError):
            self.run_plan()
        self.before = self.git("rev-parse", "HEAD")
        self.commit("0.1.0-preview.9+2")
        with self.assertRaises(ValueError):
            self.run_plan()
        self.assertEqual(self.output.read_text(), "")

    def test_other_events_cannot_authorize_publication(self):
        with self.assertRaisesRegex(ValueError, "Only main pushes"):
            self.run_plan(event_name="pull_request")


if __name__ == "__main__":
    unittest.main()
