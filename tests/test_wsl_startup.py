"""Cold WSL bootstrap and recovery through the real broker proxy.

Only the WSL executable is simulated. The launcher, Node relay, file locks and
runtime pipes are real; no installed distribution or agent account is touched.
"""
import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOST = Path(os.environ.get('ZOMMI_TEST_CORE_HOST', ROOT / 'target/debug/zommi-core-host'))


@unittest.skipUnless(sys.platform.startswith('linux') and shutil.which('node'), 'Linux fixture host required')
class WslStartupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='zommi wsl startup-')
        self.root = Path(self.temporary.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('ZOMMI_')}
        self.env.update(LOCALAPPDATA=str(self.root / 'appdata'),
                        PATH=str(self.bin) + os.pathsep + os.environ['PATH'])
        self.program('wslpath', 'import sys\nprint(sys.argv[-1])\n')
        self.program('wsl.exe', '''import os, sys, time
from pathlib import Path
root = Path(__file__).resolve().parent.parent
with (root / 'launches').open('a') as log:
    log.write('bootstrap\\n')
delay = root / 'delay'
if delay.exists():
    time.sleep(float(delay.read_text()))
args = sys.argv[sys.argv.index('-e') + 1:]
os.execvp(args[0], args)
''')
        self.addCleanup(self.cleanup)

    def program(self, name, source):
        path = self.bin / name
        path.write_text('#!' + sys.executable + '\n' + source)
        path.chmod(0o755)

    def endpoints(self):
        return list((self.root / 'appdata/Zommi/wsl-relay').glob('v*/endpoints/*.json'))

    def endpoint(self):
        paths = self.endpoints()
        self.assertEqual(len(paths), 1)
        return paths[0], json.loads(paths[0].read_text())

    def proxy(self, command=None):
        return subprocess.Popen([
            str(HOST), '--wsl-proxy', '--distribution', 'test', '--cwd', '/', '--',
            *(command or ['/bin/cat']),
        ], env=self.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True)

    def round_trip(self):
        process = self.proxy()
        try:
            out, err = process.communicate('WSL_READY\n', timeout=40)
            self.assertEqual(process.returncode, 0, err)
            self.assertEqual(out, 'WSL_READY\n')
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

    def kill_relay(self, endpoint):
        # Only fixture-owned relay processes are eligible for cleanup.
        pid = endpoint['pid']
        command = Path(f'/proc/{pid}/cmdline')
        if command.exists() and str(self.root).encode() in command.read_bytes():
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def cleanup(self):
        # Include superseded daemons from the before-fix reproduction.
        for process in Path('/proc').iterdir():
            if not process.name.isdigit():
                continue
            try:
                command = (process / 'cmdline').read_bytes()
                if str(self.root).encode() in command and b'zommi-wsl-relay.js' in command:
                    os.kill(int(process.name), signal.SIGKILL)
            except (OSError, ProcessLookupError):
                pass
        self.temporary.cleanup()

    def test_cold_boot_can_exceed_the_old_five_second_cutoff(self):
        (self.root / 'delay').write_text('6')
        started = time.monotonic()
        self.round_trip()
        self.assertLess(time.monotonic() - started, 12)
        self.assertEqual((self.root / 'launches').read_text().splitlines(), ['bootstrap'])

    def test_parallel_agents_share_one_bootstrap_and_reuse_it(self):
        (self.root / 'delay').write_text('0.3')
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            list(pool.map(lambda _: self.round_trip(), range(6)))
        self.round_trip()
        self.assertEqual((self.root / 'launches').read_text().splitlines(), ['bootstrap'])

    def test_restart_ignores_a_fresh_or_future_dated_dead_endpoint(self):
        self.round_trip()
        for heartbeat in [int(time.time() * 1000), int((time.time() + 86400) * 1000)]:
            path, endpoint = self.endpoint()
            self.kill_relay(endpoint)
            endpoint['heartbeatMs'] = heartbeat
            path.write_text(json.dumps(endpoint))
            started = time.monotonic()
            self.round_trip()
            self.assertLess(time.monotonic() - started, 5)
            _, replacement = self.endpoint()
            self.assertNotEqual(replacement['pid'], endpoint['pid'])

    def test_dead_session_fails_even_when_another_relay_is_healthy(self):
        self.round_trip()
        path, endpoint = self.endpoint()
        process = self.proxy(['/bin/sh', '-c', 'echo SESSION_READY; cat'])
        try:
            self.assertEqual(process.stdout.readline(), 'SESSION_READY\n')
            self.kill_relay(endpoint)
            endpoint['heartbeatMs'] = int((time.time() + 86400) * 1000)
            path.write_text(json.dumps(endpoint))
            self.round_trip()
            # Keep stdin open, as an agent protocol does between requests.
            process.wait(timeout=9)
            self.assertNotEqual(process.returncode, 0)
            self.assertIn('WSL relay stopped', process.stderr.read())
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdin.close()
            process.stdout.close()
            process.stderr.close()


if __name__ == '__main__':
    unittest.main()
