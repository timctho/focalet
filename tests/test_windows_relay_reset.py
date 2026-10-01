"""Exercise uninstall's Windows PowerShell wrapper using temporary cache records."""
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/stop-zommi-relays.ps1'


@unittest.skipUnless(os.name == 'nt', 'Windows PowerShell 5.1')
class WindowsRelayResetTests(unittest.TestCase):
    def run_cleanup(self, directory, architecture):
        powershell = Path(os.environ['WINDIR']) / architecture / 'WindowsPowerShell/v1.0/powershell.exe'
        # This is a functional cleanup test, including cold 32-bit PowerShell
        # startup on hosted Windows runners. Keep it bounded without making
        # the engine's first launch a 15-second performance assertion.
        return subprocess.run([
            str(powershell), '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', str(SCRIPT), '-DataDirectory', str(directory),
        ], capture_output=True, text=True, timeout=60)

    def test_missing_cache_and_stale_corrupt_record_need_no_wsl(self):
        for architecture in ('System32', 'SysWOW64'):
            with self.subTest(architecture=architecture), tempfile.TemporaryDirectory(prefix='zommi reset ') as directory:
                data = Path(directory) / 'Zommi'
                missing = self.run_cleanup(data, architecture)
                self.assertEqual(missing.returncode, 0, missing.stderr)
                endpoint = data / 'wsl-relay/v4/endpoints/fixture.json'
                endpoint.parent.mkdir(parents=True)
                endpoint.write_text('invalid inactive cache')
                stale = self.run_cleanup(data, architecture)
                self.assertEqual(stale.returncode, 0, stale.stderr)
                self.assertEqual(endpoint.read_text(), 'invalid inactive cache')

    def test_active_corrupt_record_keeps_data_and_reports_stage_without_token(self):
        secret = 'fixture-private-token-must-not-be-displayed'
        for architecture in ('System32', 'SysWOW64'):
            with self.subTest(architecture=architecture), tempfile.TemporaryDirectory(prefix='zommi reset ') as directory:
                data = Path(directory) / 'Zommi'
                endpoint = data / 'wsl-relay/v4/endpoints/fixture.json'
                endpoint.parent.mkdir(parents=True)
                endpoint.write_text('invalid active cache')
                finished = threading.Event()

                def write_corrupt_heartbeat():
                    counter = 0
                    while not finished.wait(.05):
                        temporary = endpoint.with_suffix('.tmp')
                        # A JSON parser's exception can include this secret.
                        temporary.write_text(f'{{"token":"{secret}","heartbeatMs":{counter}')
                        try:
                            temporary.replace(endpoint)
                        except PermissionError:
                            # Windows can briefly hold the file during a read.
                            pass
                        counter += 1

                writer = threading.Thread(target=write_corrupt_heartbeat)
                writer.start()
                try:
                    result = self.run_cleanup(data, architecture)
                    self.assertEqual(result.returncode, 4)
                    self.assertIn('validating an active connection record', result.stderr)
                    self.assertIn('Your data was kept.', result.stderr)
                    self.assertNotIn(secret, result.stdout + result.stderr)
                    self.assertTrue(endpoint.exists())
                finally:
                    finished.set()
                    writer.join(timeout=5)


if __name__ == '__main__':
    unittest.main()
