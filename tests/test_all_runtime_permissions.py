"""Full-access transitions through real broker processes and native protocol fixtures."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from test_runtime_commands import Core, FIXTURES


class AllRuntimePermissionTests(unittest.TestCase):
    def setup_runtime(self, adapter, **environment):
        directory = tempfile.TemporaryDirectory(prefix='zommi-all-permissions-')
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('ZOMMI_')}
        self.env.update(ZOMMI_RUNTIME_DISCOVERY_MODE='configured-only',
                        ZOMMI_CORE_STATE_PATH=str(self.path / 'binding.json'),
                        ZOMMI_RUNTIME_OVERRIDES_PATH=str(self.path / 'overrides.json'),
                        ZOMMI_RUNTIME_DISCOVERY_CACHE_PATH=str(self.path / 'targets.json'),
                        ZOMMI_OPENCLAW_DEVICE_IDENTITY_PATH=str(self.path / 'device.json'),
                        ZOMMI_FAKE_REQUEST_LOG=str(self.path / 'wire.jsonl'),
                        ZOMMI_FAKE_UNIQUE_SESSIONS='1',
                        ZOMMI_FAKE_HERMES_LEGACY_SESSION_LIST='1',
                        ZOMMI_FAKE_GATEWAY_SESSIONS=str(self.path / 'gateway-sessions.json'),
                        ZOMMI_FAKE_CLAUDE_STORE=str(self.path / 'claude-sessions'))
        self.env.update(environment)
        runtime = adapter.split('-')[0].upper()
        if adapter == 'openclaw-gateway':
            gateway = subprocess.Popen([sys.executable, str(FIXTURES / 'fake_gateway_runtime.py'), '--mode', 'openclaw'],
                                       env=self.env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            def stop_gateway():
                gateway.terminate()
                gateway.wait(timeout=5)
                gateway.stdout.close()
            self.addCleanup(stop_gateway)
            endpoint = gateway.stdout.readline().strip().split(' ', 1)[1]
            self.env.update(ZOMMI_OPENCLAW_GATEWAY_URL=endpoint, OPENCLAW_GATEWAY_TOKEN='fixture-token')
        else:
            self.env[f'ZOMMI_{runtime}_COMMAND'] = sys.executable
            if adapter.endswith('-acp'):
                args = [str(FIXTURES / 'fake_acp_runtime.py')]
            elif adapter == 'hermes-gateway':
                args = [str(FIXTURES / 'fake_gateway_runtime.py'), '--mode', 'hermes']
            elif adapter == 'pi-rpc':
                args = [str(FIXTURES / 'fake_pi_rpc.py')]
            else:
                args = [str(FIXTURES / 'fake_claude_runtime.py')]
            self.env[f'ZOMMI_{adapter.upper().replace("-", "_")}_ARGS_JSON'] = json.dumps(args)
        self.adapter = adapter
        self.restart()

    def restart(self):
        if getattr(self, 'core', None):
            self.core.close()
        self.core = Core(self.env)
        self.addCleanup(self.core.close)
        self.core.request('core.initialize')
        self.target = next(t['id'] for t in self.core.request('runtime.discover')['targets'] if t['adapterId'] == self.adapter)
        self.identity = {'runtimeTargetId': self.target}

    def select(self, operation, **extra):
        connection = self.core.request(operation, dict(runtimeTargetId=self.target, cwd=str(self.path), **extra))
        self.identity = {'runtimeTargetId': self.target, 'sessionId': connection['sessionId']}
        return dict(self.identity)

    def wire(self):
        return [json.loads(line) for line in (self.path / 'wire.jsonl').read_text().splitlines()]

    def acp_approval(self, full_access):
        self.core.events.clear()
        receipt = self.core.request('turn.start', dict(self.identity, message='request-approval', clientOperationId=f'approval:{self.core.sequence}'))
        if full_access:
            self.core.completed(receipt['clientOperationId'])
            self.assertFalse(any(e['name'] == 'approval.requested' for e in self.core.events))
        else:
            while not any(e['name'] == 'approval.requested' for e in self.core.events):
                self.core.receive()
            event = next(e for e in self.core.events if e['name'] == 'approval.requested')
            return receipt, event

    def test_acp_modes_are_isolated_and_saved_across_reconnect(self):
        for adapter in ['hermes-acp', 'opencode-acp', 'gemini-acp', 'openclaw-acp']:
            with self.subTest(adapter=adapter):
                self.setup_runtime(adapter)
                first = self.select('runtime.connect', fullAccess=False, newSession=True)
                pending, approval = self.acp_approval(False)
                full = self.select('session.create', fullAccess=True)
                launches = [v for v in self.wire() if 'launchArgs' in v]
                self.assertEqual(len(launches), 2, 'Changing permissions needs a separate ACP process')
                if adapter == 'gemini-acp':
                    self.assertEqual(launches[1]['launchArgs'][-2:], ['--approval-mode', 'yolo'])
                    self.assertNotIn('--approval-mode', launches[0]['launchArgs'])
                for name in {'hermes-acp':['HERMES_YOLO_MODE'], 'opencode-acp':['OPENCODE_PERMISSION']}.get(adapter, []):
                    self.assertIsNone(launches[0]['permissionEnvironment'][name])
                    self.assertTrue(launches[1]['permissionEnvironment'][name])
                self.acp_approval(True)
                self.core.request('approval.resolve', dict(first, approvalId=approval['payload']['approvalId'], optionId=None))
                self.core.completed(pending['clientOperationId'])
                self.select('session.create', fullAccess=False)
                receipt, event = self.acp_approval(False)
                self.core.request('approval.resolve', dict(self.identity, approvalId=event['payload']['approvalId'], optionId=None))
                self.core.completed(receipt['clientOperationId'])
                self.assertEqual(len([v for v in self.wire() if 'launchArgs' in v]), 2)
                held = dict(self.identity)
                pending, approval = self.acp_approval(False)
                self.select('session.open', sessionId=full['sessionId'])
                crash = self.core.request('turn.start', dict(self.identity, message='exit-runtime', clientOperationId=f'crash-acp:{self.core.sequence}'))
                self.core.completed(crash['clientOperationId'])
                self.select('runtime.connect', preferredSessionId=full['sessionId'], fullAccess=False)
                self.acp_approval(True)
                self.core.request('approval.resolve', dict(held, approvalId=approval['payload']['approvalId'], optionId=None))
                self.core.completed(pending['clientOperationId'])
                self.assertEqual(len([v for v in self.wire() if 'launchArgs' in v]), 3)
                self.core.request('runtime.refreshModels', {'runtimeTargetId':self.target})
                self.assertEqual(len([v for v in self.wire() if 'launchArgs' in v]), 5)
                self.acp_approval(True)
                self.restart()
                self.select('runtime.connect', preferredSessionId=full['sessionId'], fullAccess=False)
                self.acp_approval(True)
                self.select('session.open', sessionId=first['sessionId'])
                receipt, event = self.acp_approval(False)
                self.core.request('approval.resolve', dict(self.identity, approvalId=event['payload']['approvalId'], optionId=None))
                self.core.completed(receipt['clientOperationId'])

    def test_claude_uses_each_chats_policy_for_spawn_and_resume(self):
        self.setup_runtime('claude-stream-json')
        self.core.request('runtime.prepare', dict(self.identity, fullAccess=False))
        full = self.select('runtime.connect', fullAccess=True, newSession=True)
        for full_access in [False, True, False]:
            self.select('session.create', fullAccess=full_access)
            launch = [v for v in self.wire() if v.get('sessionId') == self.identity['sessionId'] and 'launchArgs' in v][-1]
            self.assertEqual('bypassPermissions' in launch['launchArgs'], full_access)
        count = len([v for v in self.wire() if 'launchArgs' in v])
        self.select('session.open', sessionId=full['sessionId'])
        self.assertEqual(len([v for v in self.wire() if 'launchArgs' in v]), count)
        crash = self.core.request('turn.start', dict(self.identity, message='crash-now', clientOperationId='crash-claude'))
        self.core.completed(crash['clientOperationId'])
        self.select('runtime.connect', preferredSessionId=full['sessionId'], fullAccess=False)
        self.assertIn('bypassPermissions', [v for v in self.wire() if 'launchArgs' in v][-1]['launchArgs'])
        self.restart()
        self.select('runtime.connect', preferredSessionId=full['sessionId'], fullAccess=False)
        launch = [v for v in self.wire() if 'launchArgs' in v][-1]
        self.assertIn('--resume', launch['launchArgs'])
        self.assertIn('bypassPermissions', launch['launchArgs'])

    def gateway_approval(self, full_access):
        self.core.events.clear()
        receipt = self.core.request('turn.start', dict(self.identity, message='request-interactions', clientOperationId=f'gateway:{self.core.sequence}'))
        while not any(e['name'] == 'question.requested' for e in self.core.events):
            self.core.receive()
        question = next(e for e in self.core.events if e['name'] == 'question.requested')
        if not full_access:
            while not any(e['name'] == 'approval.requested' for e in self.core.events):
                self.core.receive()
            approval = next(e for e in self.core.events if e['name'] == 'approval.requested')
            self.core.request('approval.resolve', dict(self.identity, approvalId=approval['payload']['approvalId'], optionId='deny'))
        self.core.request('question.resolve', dict(self.identity, questionId=question['payload']['questionId'], answer={'answer':'main'}))
        self.core.completed(receipt['clientOperationId'])
        self.assertEqual(any(e['name'] == 'approval.requested' for e in self.core.events), not full_access)

    def test_gateway_approvals_follow_the_chat_without_answering_questions(self):
        for adapter in ['hermes-gateway', 'openclaw-gateway']:
            with self.subTest(adapter=adapter):
                self.setup_runtime(adapter)
                default = self.select('runtime.connect', fullAccess=False, newSession=True)
                self.gateway_approval(False)
                full = self.select('session.create', fullAccess=True)
                self.gateway_approval(True)
                self.select('session.create', fullAccess=False)
                self.gateway_approval(False)
                self.select('session.open', sessionId=full['sessionId'])
                self.gateway_approval(True)
                self.restart()
                self.select('runtime.connect', preferredSessionId=full['sessionId'], fullAccess=False)
                self.gateway_approval(True)
                self.select('session.open', sessionId=default['sessionId'])
                self.gateway_approval(False)

    def test_pi_keeps_native_unrestricted_tools_in_both_modes(self):
        self.setup_runtime('pi-rpc')
        self.select('runtime.connect', fullAccess=False, newSession=True)
        for full_access in [True, False]:
            self.select('session.create', fullAccess=full_access)
            receipt = self.core.request('turn.start', dict(self.identity, message='fixture native tools', clientOperationId=f'permission-pi:{self.core.sequence}'))
            self.core.completed(receipt['clientOperationId'])
        self.assertFalse(any(e['name'] == 'approval.requested' for e in self.core.events))

    def test_gateway_rejected_automatic_approval_returns_to_the_ui(self):
        for adapter in ['hermes-gateway', 'openclaw-gateway']:
            with self.subTest(adapter=adapter):
                self.setup_runtime(adapter, ZOMMI_FAKE_REJECT_AUTOMATIC_APPROVAL='1')
                self.select('runtime.connect', fullAccess=True, newSession=True)
                self.gateway_approval(False)
                decisions = [v['params']['decision'] for v in self.wire() if v.get('method') in ('approval.respond', 'approval.resolve')]
                self.assertEqual(decisions, ['once' if adapter == 'hermes-gateway' else 'allow-once', 'deny'])

    def test_gateway_broadcast_without_chat_identity_needs_manual_approval(self):
        self.setup_runtime('openclaw-gateway', ZOMMI_FAKE_UNSCOPED_APPROVAL='1')
        self.select('runtime.connect', fullAccess=True, newSession=True)
        self.gateway_approval(False)
        self.assertEqual([v['params']['decision'] for v in self.wire() if v.get('method') == 'approval.resolve'], ['deny'])


if __name__ == '__main__':
    unittest.main()
