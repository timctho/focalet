"""Startup failures must identify the downstream dependency and permit recovery."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

from test_runtime_commands import Core, FIXTURES


class AcpStartupTests(unittest.TestCase):
    def test_openclaw_gateway_failure_keeps_other_chats_and_can_retry(self):
        with tempfile.TemporaryDirectory(prefix='zommi-acp-startup-') as directory:
            root = Path(directory)
            marker = root / 'gateway-failure.txt'
            marker.write_text('ACP bridge failed: Opening handshake has timed out')
            env = {k: v for k, v in os.environ.items() if not k.startswith('ZOMMI_')}
            env.update(
                ZOMMI_RUNTIME_DISCOVERY_MODE='configured-only',
                ZOMMI_OPENCLAW_COMMAND=sys.executable,
                ZOMMI_OPENCLAW_ARGS_JSON=json.dumps([str(FIXTURES / 'fake_acp_runtime.py')]),
                ZOMMI_CODEX_COMMAND=sys.executable,
                ZOMMI_CODEX_ARGS_JSON=json.dumps([str(FIXTURES / 'fake_codex_app_server.py')]),
                ZOMMI_FAKE_ACP_STARTUP_FAILURE=str(marker),
                ZOMMI_CORE_STATE_PATH=str(root / 'binding.json'),
                ZOMMI_RUNTIME_OVERRIDES_PATH=str(root / 'overrides.json'),
                ZOMMI_RUNTIME_DISCOVERY_CACHE_PATH=str(root / 'targets.json'),
            )
            core = Core(env)
            try:
                core.request('core.initialize')
                targets = core.request('runtime.discover')['targets']
                codex = next(t for t in targets if t['adapterId'] == 'codex-app-server')
                openclaw = next(t for t in targets if t['adapterId'] == 'openclaw-acp')
                original = core.request('runtime.connect', {'runtimeTargetId': codex['id'], 'cwd': directory})
                saved = (root / 'binding.json').read_bytes()
                failure = core.request('session.create', {'runtimeTargetId': openclaw['id'], 'cwd': directory}, ok=False)
                self.assertEqual(failure['error']['code'], 'gateway-unavailable')
                self.assertIn('openclaw gateway status', failure['error']['message'])
                self.assertNotIn('preparing WSL transport', failure['error']['message'])
                self.assertEqual((root / 'binding.json').read_bytes(), saved)
                core.request('runtime.connect', {'runtimeTargetId': codex['id'], 'preferredSessionId': original['sessionId'], 'cwd': directory})
                marker.unlink()
                recovered = core.request('session.create', {'runtimeTargetId': openclaw['id'], 'cwd': directory})
                self.assertEqual(recovered['runtimeTargetId'], openclaw['id'])
                self.assertTrue(recovered['sessionId'])
            finally:
                core.close()
