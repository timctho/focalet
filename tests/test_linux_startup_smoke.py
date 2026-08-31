from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).parents[1] / "scripts" / "smoke-linux-release.sh"


class LinuxStartupSmokeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="zommi-linux-smoke-test-")
        self.package = Path(self.temporary.name)
        sleep = shutil.which("sleep")
        assert sleep
        (self.package / "zommi-core-host").symlink_to(sleep)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write_application(self, *, error: str = "") -> None:
        application = self.package / "zommi"
        lines = ["#!/usr/bin/env bash\n", "set -eu\n"]
        if error:
            lines.append(f"printf '%s\\n' {shlex.quote(error)}\n")
        lines.extend(
            [
                '"$(dirname "$0")/zommi-core-host" 60 &\n',
                "child=$!\n",
                "trap 'kill -TERM \"$child\" 2>/dev/null || true; wait \"$child\" 2>/dev/null || true; exit 0' TERM INT\n",
                'wait "$child"\n',
            ]
        )
        application.write_text("".join(lines), encoding="utf-8")
        application.chmod(0o755)

    def _run(self, *, display: bool = True) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        if display:
            environment["DISPLAY"] = ":99"
        else:
            environment.pop("DISPLAY", None)
            environment.pop("WAYLAND_DISPLAY", None)
        return subprocess.run(
            [str(SCRIPT), str(self.package)],
            text=True,
            capture_output=True,
            timeout=30,
            check=False,
            env=environment,
        )

    def test_flutter_and_exact_core_survive_and_stop(self) -> None:
        self._write_application()
        completed = self._run()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads(completed.stdout)
        self.assertTrue(result["flutterStarted"])
        self.assertTrue(result["rustCoreStarted"])
        self.assertTrue(result["cleanShutdown"])

    def test_unhandled_flutter_exception_fails(self) -> None:
        self._write_application(error="Unhandled Exception: startup failed")
        completed = self._run()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("unhandled startup exception", completed.stderr)

    def test_display_is_required(self) -> None:
        self._write_application()
        completed = self._run(display=False)
        self.assertEqual(completed.returncode, 2)
        self.assertIn("requires a live DISPLAY", completed.stderr)


if __name__ == "__main__":
    unittest.main()
