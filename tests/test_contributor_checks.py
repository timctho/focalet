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
    def test_windows_suite_exercises_uninstall_powershell(self):
        with patch.object(checks.os, 'name', 'nt'), \
                patch.object(checks, 'check_rust'), \
                patch.object(checks, 'check_flutter'), \
                patch.object(checks, 'check_capture'), \
                patch.object(checks, 'run') as run:
            checks.check_windows()
        run.assert_any_call(
            sys.executable, '-m', 'unittest', 'discover', '-s', 'tests',
            '-p', 'test_windows_relay_reset.py', '-v',
        )

    def test_runner_isolates_real_runtime_configuration_and_personal_state(self):
        inherited = {
            "PATH": "/toolchains",
            "HOME": "/personal",
            "FOCALET_CODEX_COMMAND": "/personal/codex",
            "FOCALET_OPENCLAW_GATEWAY_URL": "ws://127.0.0.1:9999",
            "FOCALET_CORE_STATE_PATH": "/personal/chat.json",
            "FOCALET_TEST_CHROMIUM": "/tools/chrome",
        }
        environment = checks.isolated_runtime_environment("/isolated", inherited)
        self.assertEqual(environment["FOCALET_RUNTIME_DISCOVERY_MODE"], "configured-only")
        self.assertNotIn("FOCALET_CODEX_COMMAND", environment)
        self.assertNotIn("FOCALET_OPENCLAW_GATEWAY_URL", environment)
        self.assertEqual(environment["FOCALET_CORE_STATE_PATH"], "/isolated/binding.json")
        self.assertEqual(environment["HOME"], inherited["HOME"])
        self.assertEqual(environment["FOCALET_TEST_CHROMIUM"], "/tools/chrome")
        self.assertEqual(inherited["FOCALET_CORE_STATE_PATH"], "/personal/chat.json")

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
            if name in {"contracts", "windows", "macos"}:
                self.assertEqual(job["needs"], "documentation")
                self.assertEqual(job["if"], "needs.documentation.outputs.desktop_required == 'true'")
            for step in job["steps"]:
                if "uses" in step:
                    self.assertRegex(step["uses"], r"^[\w-]+/[\w-]+@[0-9a-f]{40}$")
                    if step["uses"].startswith("actions/checkout@"):
                        self.assertEqual(step["with"]["persist-credentials"], "false")
        gate = workflow["jobs"]["required"]
        self.assertEqual(set(gate["needs"]), {"documentation", "contracts", "windows", "macos", "capture_windows", "capture_unix"})
        self.assertEqual(gate["if"], "always()")
        command = gate["steps"][0]["run"]
        capture_job = workflow["jobs"]["capture_windows"]
        self.assertEqual(capture_job["if"], "needs.documentation.outputs.capture_required == 'true'")
        # Exercise the gate across both product scopes, including unknown scope,
        # failed/cancelled jobs and jobs incorrectly skipped or run.
        for desktop, capture, linux, windows, macos, capture_result, capture_unix in itertools.product(
            ["true", "false", ""], ["true", "false", ""],
            *([["success", "failure", "skipped", "cancelled"]] * 5),
        ):
            environment = {
                "DOCS_RESULT": "success", "DESKTOP_REQUIRED": desktop, "CAPTURE_REQUIRED": capture,
                "LINUX_RESULT": linux, "WINDOWS_RESULT": windows, "MACOS_RESULT": macos,
                "CAPTURE_RESULT": capture_result, "CAPTURE_UNIX_RESULT": capture_unix,
            }
            result = subprocess.run(["bash", "-c", command], env=environment, capture_output=True)
            expected = (
                ((desktop == "true" and linux == windows == macos == "success")
                 or (desktop == "false" and linux == windows == macos == "skipped"))
                and ((capture == "true" and capture_result == capture_unix == "success")
                     or (capture == "false" and capture_result == capture_unix == "skipped"))
            )
            self.assertEqual(result.returncode == 0, expected, environment)
        for docs in ["failure", "skipped", "cancelled", ""]:
            result = subprocess.run(["bash", "-c", command], env={
                "DOCS_RESULT": docs, "DESKTOP_REQUIRED": "true", "CAPTURE_REQUIRED": "true",
                "LINUX_RESULT": "success", "WINDOWS_RESULT": "success", "MACOS_RESULT": "success",
                "CAPTURE_RESULT": "success", "CAPTURE_UNIX_RESULT": "success",
            }, capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def test_native_release_workflow_is_explicitly_operator_invoked(self):
        workflow = yaml.load(
            (ROOT / ".github/workflows/ci.yml").read_text(), Loader=yaml.BaseLoader
        )
        self.assertEqual(set(workflow["on"]), {"workflow_dispatch"})

    def test_runner_preserves_arguments_and_propagates_failure(self):
        with tempfile.TemporaryDirectory(prefix="focalet check ") as directory:
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
        with tempfile.TemporaryDirectory(prefix="focalet shell checks ") as directory:
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
