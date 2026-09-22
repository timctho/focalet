"""Reset may stop only the exact Zommi relay and the runtimes it owns."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/stop-zommi-relay.sh'


@unittest.skipUnless(sys.platform.startswith('linux'), 'Linux /proc process identity')
class RelayResetTests(unittest.TestCase):
    def test_exact_identity_stops_owned_tree_and_preserves_unrelated_process(self):
        with tempfile.TemporaryDirectory(prefix='zommi relay reset ') as directory:
            root = Path(directory)
            endpoint = root / 'endpoints/fixture.json'
            fixture = root / 'zommi-wsl-relay.js'
            fixture.write_text("""const {spawn}=require('node:child_process');
const child=spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{detached:true});
process.on('SIGTERM',()=>{if(child.exitCode!==null || child.signalCode)process.exit(0);else child.once('exit',()=>process.exit(0));});
console.log(JSON.stringify({child:child.pid}));
setInterval(()=>{},1000);
""")
            relays = [subprocess.Popen(['node', str(fixture), str(endpoint)], stdout=subprocess.PIPE, text=True) for _ in range(2)]
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

    def test_invalid_pid_cannot_be_interpreted_as_shell_input(self):
        result = subprocess.run(['sh', str(SCRIPT), '1; echo unexpected', '/a/endpoints/test.json'])
        self.assertEqual(result.returncode, 2)
