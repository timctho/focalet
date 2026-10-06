"""Reset may stop only the exact Focalet relay and the runtimes it owns."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/stop-focalet-relay.sh'


@unittest.skipUnless(sys.platform.startswith('linux'), 'Linux /proc process identity')
class RelayResetTests(unittest.TestCase):
    def test_exact_identity_stops_owned_tree_and_preserves_unrelated_process(self):
        with tempfile.TemporaryDirectory(prefix='focalet relay reset ') as directory:
            root = Path(directory)
            endpoint = root / 'endpoints/fixture.json'
            fixture = root / 'focalet-wsl-relay.js'
            fixture.write_text("""const {spawn}=require('node:child_process');
const child=spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{detached:true});
process.on('SIGTERM',()=>{if(child.exitCode!==null || child.signalCode)process.exit(0);else child.once('exit',()=>process.exit(0));});
console.log(JSON.stringify({child:child.pid}));
setInterval(()=>{},1000);
""")
            bootstrap = root / 'bootstrap/fixture/focalet-wsl-relay.js'
            bootstrap.parent.mkdir(parents=True)
            shutil.copyfile(fixture, bootstrap)
            # An upgrade can leave the old layout and the new layout alive.
            relays = [subprocess.Popen(['node', str(script), '--endpoint', str(endpoint)], stdout=subprocess.PIPE, text=True)
                      for script in (fixture, bootstrap)]
            relay = relays[0]
            unrelated = subprocess.Popen([sys.executable, '-c', 'import time;time.sleep(60)'])
            try:
                children = [json.loads(process.stdout.readline())['child'] for process in relays]
                wrong = subprocess.run(['sh', str(SCRIPT), str(relay.pid), str(root / 'endpoints/other.json')])
                self.assertEqual(wrong.returncode, 3)
                self.assertIsNone(relay.poll())
                self.assertIsNone(unrelated.poll())
                subprocess.run(['sh', str(SCRIPT), str(relay.pid), str(endpoint)], check=True, timeout=10)
                for process in relays: process.wait(timeout=5)
                for child in children:
                    with self.assertRaises(ProcessLookupError):
                        os.kill(child, 0)
                self.assertIsNone(unrelated.poll())
                # A second cleanup is harmless after this process has gone.
                subprocess.run(['sh', str(SCRIPT), str(relay.pid), str(endpoint)], check=True)
            finally:
                for process in relays:
                    if process.poll() is None: process.kill()
                    process.wait()
                    process.stdout.close()
                unrelated.terminate()
                unrelated.wait()

    def test_current_production_relay_stops_without_touching_other_distribution(self):
        with tempfile.TemporaryDirectory(prefix='focalet relay reset ') as directory:
            root = Path(directory) / 'wsl-relay/v4'
            relays = []
            endpoints = []
            try:
                for distribution in ('Ubuntu', 'Ubuntu-Other'):
                    name = distribution.lower().encode().hex()
                    script = root / 'bootstrap' / name / 'focalet-wsl-relay.js'
                    script.parent.mkdir(parents=True)
                    shutil.copyfile(SCRIPT.with_name('focalet-wsl-relay.js'), script)
                    endpoint = root / 'endpoints' / f'{name}.json'
                    endpoints.append(endpoint)
                    relay = subprocess.Popen([
                        'node', str(script), '--endpoint', str(endpoint),
                        '--token', 'fixture-token-for-uninstall-testing-only',
                        '--version', '4', '--distribution', distribution,
                    ], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                    relays.append(relay)
                    deadline = time.monotonic() + 5
                    while not endpoint.exists():
                        self.assertIsNone(relay.poll(), 'The fixture relay exited before startup')
                        self.assertLess(time.monotonic(), deadline, 'The fixture relay did not start')
                        time.sleep(.05)
                subprocess.run(['sh', str(SCRIPT), str(relays[0].pid), str(endpoints[0])], check=True, timeout=10)
                relays[0].wait(timeout=5)
                self.assertIsNone(relays[1].poll(), 'Cleanup stopped another distribution')
                before = json.loads(endpoints[0].read_text())['heartbeatMs']
                time.sleep(1.2)
                self.assertEqual(json.loads(endpoints[0].read_text())['heartbeatMs'], before)
            finally:
                for relay in relays:
                    if relay.poll() is None:
                        relay.terminate()
                    relay.wait(timeout=5)
                    relay.stderr.close()

    def test_script_and_endpoint_mentions_do_not_identify_a_relay(self):
        with tempfile.TemporaryDirectory(prefix='focalet relay reset ') as directory:
            root = Path(directory)
            endpoint = root / 'endpoints/fixture.json'
            fixture = root / 'focalet-wsl-relay.js'
            unrelated = subprocess.Popen([
                'node', '-e', 'setInterval(()=>{},1000)',
                str(fixture), '--endpoint', str(endpoint),
            ])
            try:
                result = subprocess.run(['sh', str(SCRIPT), str(unrelated.pid), str(endpoint)], timeout=10)
                self.assertEqual(result.returncode, 3)
                self.assertIsNone(unrelated.poll())
            finally:
                unrelated.terminate()
                unrelated.wait(timeout=5)

    def test_invalid_pid_cannot_be_interpreted_as_shell_input(self):
        result = subprocess.run(['sh', str(SCRIPT), '1; echo unexpected', '/a/endpoints/test.json'])
        self.assertEqual(result.returncode, 2)
