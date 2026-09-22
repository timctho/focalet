"""Manual releases use disposable runners and publish only a complete build."""
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("release_workflow", ROOT / "scripts/release_workflow.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseWorkflowTests(unittest.TestCase):
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
