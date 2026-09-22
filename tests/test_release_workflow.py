"""Manual releases use disposable runners and publish only a complete build."""
import importlib.util
from pathlib import Path
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

    def test_manual_workflow_builds_without_write_access_and_publishes_after_success(self):
        raw = (ROOT / ".github/workflows/release.yml").read_text()
        workflow = yaml.load(raw, Loader=yaml.BaseLoader)
        self.assertEqual(set(workflow["on"]), {"workflow_dispatch"})
        self.assertEqual(set(workflow["on"]["workflow_dispatch"]["inputs"]), {"platforms", "publish"})
        self.assertEqual(workflow["permissions"], {"contents": "read"})
        self.assertNotIn("self-hosted", raw)
        self.assertNotIn("secrets.", raw)
        self.assertEqual(workflow["concurrency"]["cancel-in-progress"], "false")
        jobs = workflow["jobs"]
        self.assertNotIn("permissions", jobs["build"])
        self.assertEqual(set(jobs["release"]["needs"]), {"plan", "build"})
        self.assertNotIn("if", jobs["release"])
        self.assertEqual(jobs["release"]["permissions"], {"contents": "write"})
        for job in jobs.values():
            self.assertNotIn("continue-on-error", job)
            for step in job["steps"]:
                if "uses" in step:
                    self.assertRegex(step["uses"], r"^[\w-]+/[\w-]+@[0-9a-f]{40}$")
                if "run" in step:
                    self.assertNotIn("${{ inputs.", step["run"])
                self.assertNotIn("continue-on-error", step)


if __name__ == "__main__":
    unittest.main()
