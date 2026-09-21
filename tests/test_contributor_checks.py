"""Keep incoming PRs verifiable without access to a maintainer's machine."""

import importlib.util
import itertools
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("checks", ROOT / "scripts/check.py")
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)


class ContributorChecksTests(unittest.TestCase):
    def test_runner_isolates_real_runtime_configuration_and_personal_state(self):
        inherited = {
            "PATH": "/toolchains",
            "HOME": "/personal",
            "ZOMMI_CODEX_COMMAND": "/personal/codex",
            "ZOMMI_OPENCLAW_GATEWAY_URL": "ws://127.0.0.1:9999",
            "ZOMMI_CORE_STATE_PATH": "/personal/chat.json",
            "ZOMMI_TEST_CHROMIUM": "/tools/chrome",
        }
        environment = checks.isolated_runtime_environment("/isolated", inherited)
        self.assertEqual(environment["ZOMMI_RUNTIME_DISCOVERY_MODE"], "configured-only")
        self.assertNotIn("ZOMMI_CODEX_COMMAND", environment)
        self.assertNotIn("ZOMMI_OPENCLAW_GATEWAY_URL", environment)
        self.assertEqual(environment["ZOMMI_CORE_STATE_PATH"], "/isolated/binding.json")
        self.assertEqual(environment["HOME"], inherited["HOME"])
        self.assertEqual(environment["ZOMMI_TEST_CHROMIUM"], "/tools/chrome")
        self.assertEqual(inherited["ZOMMI_CORE_STATE_PATH"], "/personal/chat.json")

    def test_external_prs_get_all_platforms_without_secrets_or_persistent_runners(
        self,
    ):
        path = ROOT / ".github/workflows/checks.yml"
        raw = path.read_text()
        workflow = yaml.load(raw, Loader=yaml.BaseLoader)
        self.assertIn("pull_request", workflow["on"])
        self.assertNotIn("pull_request_target", workflow["on"])
        self.assertNotIn("paths", workflow["on"]["pull_request"] or {})
        self.assertEqual(workflow["permissions"], {"contents": "read"})
        self.assertNotIn("secrets.", raw)
        self.assertNotIn("self-hosted", raw)
        for name, job in workflow["jobs"].items():
            self.assertNotIn("permissions", job)
            if name != "required":
                self.assertNotIn("if", job, "A fork must not silently skip a platform")
            for step in job["steps"]:
                if "uses" in step:
                    self.assertRegex(step["uses"], r"^[\w-]+/[\w-]+@[0-9a-f]{40}$")
                    if step["uses"].startswith("actions/checkout@"):
                        self.assertEqual(step["with"]["persist-credentials"], "false")
        gate = workflow["jobs"]["required"]
        self.assertEqual(set(gate["needs"]), {"contracts", "windows", "macos"})
        self.assertEqual(gate["if"], "always()")
        command = gate["steps"][0]["run"]
        for linux, windows, macos in itertools.product(
            ["success", "failure", "skipped", "cancelled"], repeat=3
        ):
            result = subprocess.run(
                ["bash", "-c", command],
                env={
                    "LINUX_RESULT": linux,
                    "WINDOWS_RESULT": windows,
                    "MACOS_RESULT": macos,
                },
                capture_output=True,
            )
            self.assertEqual(
                result.returncode == 0, linux == windows == macos == "success"
            )

    def test_native_release_workflow_is_explicitly_operator_invoked(self):
        workflow = yaml.load(
            (ROOT / ".github/workflows/ci.yml").read_text(), Loader=yaml.BaseLoader
        )
        self.assertEqual(set(workflow["on"]), {"workflow_dispatch"})

    def test_runner_preserves_arguments_and_propagates_failure(self):
        with tempfile.TemporaryDirectory(prefix="zommi check ") as directory:
            script = Path(directory, "failure script.py")
            script.write_text(
                "import sys\nassert sys.argv[1] == 'argument with spaces'\nsys.exit(23)\n"
            )
            with self.assertRaises(subprocess.CalledProcessError) as caught:
                checks.run(sys.executable, script, "argument with spaces")
            self.assertEqual(caught.exception.returncode, 23)

    def test_missing_tool_reports_the_prerequisite(self):
        with patch.object(checks.shutil, "which", return_value=None):
            with self.assertRaisesRegex(RuntimeError, "Missing flutter.*CONTRIBUTING"):
                checks.run("flutter", "test")

    def test_shell_syntax_error_after_the_first_script_fails_checks(self):
        with tempfile.TemporaryDirectory(prefix="zommi shell checks ") as directory:
            root = Path(directory)
            scripts = root / "scripts"
            scripts.mkdir()
            (scripts / "a.sh").write_text("true\n")
            invalid = scripts / "b.sh"
            invalid.write_text("if then\n")
            with self.assertRaises(subprocess.CalledProcessError):
                checks.check_shell_scripts(root)
            invalid.write_text("true\n")
            checks.check_shell_scripts(root)


if __name__ == "__main__":
    unittest.main()
