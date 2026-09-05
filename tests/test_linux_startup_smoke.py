from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import textwrap
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

    def _write_orphaning_application(self, *, terminate_core: bool) -> None:
        application = self.package / "zommi"
        application.write_text(
            f"#!{sys.executable}\n"
            + textwrap.dedent(
                f"""\
                import os
                from pathlib import Path
                import signal
                import subprocess

                package = Path(__file__).parent
                core = subprocess.Popen([str(package / "zommi-core-host"), "60"])
                (package / "core.pid").write_text(str(core.pid))

                def stop(signum, frame):
                    if {terminate_core!r}:
                        core.terminate()
                    os._exit(0)

                signal.signal(signal.SIGTERM, stop)
                signal.signal(signal.SIGINT, stop)
                while True:
                    signal.pause()
                """
            ),
            encoding="utf-8",
        )
        application.chmod(0o755)

    def _run_with_subreaper(self) -> subprocess.CompletedProcess[str]:
        wrapper = textwrap.dedent(
            """\
            import ctypes
            import os
            from pathlib import Path
            import signal
            import subprocess
            import sys

            library = ctypes.CDLL(None, use_errno=True)
            if library.prctl(36, 1, 0, 0, 0) != 0:
                raise OSError(ctypes.get_errno(), "Could not become a subreaper")
            try:
                completed = subprocess.run(
                    sys.argv[1:], capture_output=True, text=True, timeout=25
                )
                sys.stdout.write(completed.stdout)
                sys.stderr.write(completed.stderr)
                core_pid = (Path(sys.argv[2]) / "core.pid").read_text()
                core_status = Path(f"/proc/{core_pid}/stat").read_text()
                core_state = core_status.rsplit(") ", 1)[1].split()[0]
                print(f"adoptedCoreState={core_state}", file=sys.stderr)
                sys.exit(completed.returncode)
            finally:
                children = Path(f"/proc/{os.getpid()}/task/{os.getpid()}/children")
                for child_pid in children.read_text().split():
                    try:
                        os.kill(int(child_pid), signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                while True:
                    try:
                        os.waitpid(-1, 0)
                    except ChildProcessError:
                        break
            """
        )
        return subprocess.run(
            [sys.executable, "-c", wrapper, str(SCRIPT), str(self.package)],
            text=True,
            capture_output=True,
            timeout=30,
            check=False,
            env={**os.environ, "DISPLAY": ":99"},
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

    def test_exited_unreaped_core_counts_as_stopped(self) -> None:
        self._write_orphaning_application(terminate_core=True)
        completed = self._run_with_subreaper()
        self.assertIn("adoptedCoreState=Z", completed.stderr)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertTrue(json.loads(completed.stdout)["cleanShutdown"])

    def test_live_orphan_core_fails_shutdown(self) -> None:
        self._write_orphaning_application(terminate_core=False)
        completed = self._run_with_subreaper()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("Rust core remained after Flutter stopped", completed.stderr)

    def test_display_is_required(self) -> None:
        self._write_application()
        completed = self._run(display=False)
        self.assertEqual(completed.returncode, 2)
        self.assertIn("requires a live DISPLAY", completed.stderr)


if __name__ == "__main__":
    unittest.main()
