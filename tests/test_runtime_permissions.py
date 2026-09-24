"""Permission decisions through the actual broker, without provider accounts."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from test_runtime_commands import Core, FIXTURES


class RuntimePermissionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='zommi-permissions-')
        self.addCleanup(temporary.cleanup)
        self.path = Path(temporary.name)
        env = {k: v for k, v in os.environ.items() if not k.startswith('ZOMMI_')}
        env.update(ZOMMI_RUNTIME_DISCOVERY_MODE='configured-only',
                   ZOMMI_CODEX_COMMAND=sys.executable,
                   ZOMMI_CODEX_ARGS_JSON=json.dumps([str(FIXTURES / 'fake_codex_app_server.py')]),
                   ZOMMI_FAKE_UNIQUE_THREADS='1',
                   ZOMMI_FAKE_REQUEST_LOG=str(self.path / 'wire.jsonl'),
                   ZOMMI_CORE_STATE_PATH=str(self.path / 'binding.json'),
                   ZOMMI_RUNTIME_OVERRIDES_PATH=str(self.path / 'overrides.json'),
                   ZOMMI_RUNTIME_DISCOVERY_CACHE_PATH=str(self.path / 'targets.json'))
        self.env = env
        self.core = Core(env)
        self.addCleanup(self.core.close)
        self.core.request('core.initialize')
        self.target = self.core.request('runtime.discover')['targets'][0]['id']
        self.identity = {'runtimeTargetId': self.target}

    def wire(self):
        return [json.loads(line) for line in (self.path / 'wire.jsonl').read_text().splitlines()]

    def connect(self, **kwargs):
        connection = self.core.request('runtime.connect', dict(self.identity, cwd=str(self.path), **kwargs))
        self.identity['sessionId'] = connection['sessionId']
        self.assertIn('approval.resolve.v1', connection['capabilities'])

    def approval(self, kind, count=1):
        self.core.events.clear()
        self.receipt = self.core.request('turn.start', dict(self.identity, message='request-approval:' + kind,
                                        clientOperationId='permission:' + str(self.core.sequence)))
        while len([e for e in self.core.events if e['name'] == 'approval.requested']) < count:
            self.core.receive()
        return [e for e in self.core.events if e['name'] == 'approval.requested']

    def answer(self, event, option, **kwargs):
        return self.core.request('approval.resolve', dict(self.identity, approvalId=event['payload']['approvalId'], optionId=option, **kwargs))

    def test_all_approval_families_preserve_wire_responses(self):
        self.connect()
        for kind, option, expected in [
            ('command', 'allow_once', {'decision':'accept'}),
            ('files', 'allow_session', {'decision':'acceptForSession'}),
            ('legacy-command', 'reject_once', {'decision':'abort'}),
            ('legacy-files', 'allow_once', {'decision':'approved'}),
            ('permissions', 'allow_once', {'permissions':{'network':{'enabled':True}},'scope':'turn'}),
            ('permissions', None, {'permissions':{},'scope':'turn'}),
        ]:
            event = self.approval(kind)[0]
            if kind == 'files':
                self.assertIn('fixture change', json.dumps(event['payload']))
            self.answer(event, option)
            self.core.completed(self.receipt['clientOperationId'])
            reply = [v for v in self.wire() if v.get('id') == 77 and 'result' in v][-1]
            self.assertEqual(reply['result'], expected)

    def test_concurrent_approvals_keep_identity_and_reject_duplicate_answers(self):
        self.connect()
        first, second = self.approval('multiple', 2)
        self.assertNotEqual(first['payload']['approvalId'], second['payload']['approvalId'])
        for extra in [{'sessionId':'wrong'}, {'optionId':'invalid'}]:
            result = self.core.request('approval.resolve', dict(self.identity, approvalId=first['payload']['approvalId'], **extra), ok=False)
            self.assertFalse(result['ok'])
        self.answer(second, 'reject_once')
        self.answer(first, 'allow_once')
        self.core.completed(self.receipt['clientOperationId'])
        replies = [v for v in self.wire() if v.get('id') in (77, '77') and 'result' in v]
        self.assertEqual([(v['id'], v['result']['decision']) for v in replies], [('77','decline'), (77,'accept')])
        duplicate = self.core.request('approval.resolve', dict(self.identity, approvalId=first['payload']['approvalId'], optionId='allow_once'), ok=False)
        self.assertEqual(duplicate['error']['code'], 'approval-expired')

    def test_runtime_resolution_and_interrupt_expire_ui_requests(self):
        self.connect()
        for kind in ['resolved', 'command']:
            event = self.approval(kind)[0]
            if kind == 'command':
                self.core.request('turn.interrupt', dict(self.identity, turnId=self.receipt['turnId']))
            while not any(e['name']=='approval.resolved' for e in self.core.events):
                self.core.receive()
            stale = self.core.request('approval.resolve', dict(self.identity, approvalId=event['payload']['approvalId'], optionId='allow_once'), ok=False)
            self.assertEqual(stale['error']['code'], 'approval-expired')
            if kind == 'resolved':
                self.core.request('turn.interrupt', dict(self.identity, turnId=self.receipt['turnId']))
                self.core.completed(self.receipt['clientOperationId'])

    def test_full_access_applies_when_activating_a_prepared_runtime(self):
        self.core.request('runtime.prepare', dict(self.identity, fullAccess=False))
        self.connect(fullAccess=True)
        starts = [v for v in self.wire() if 'launchArgs' in v]
        self.assertEqual(len(starts), 1)
        self.assertNotIn('approval_policy="never"', starts[0]['launchArgs'])
        starts = [v for v in self.wire() if v.get('method')=='thread/start']
        self.assertTrue(all(v['params']['approvalPolicy']=='never' and v['params']['sandbox']=='danger-full-access' for v in starts))
        self.core.request('session.goal', dict(self.identity, action='set', objective='fixture goal', model='fixture-model'))
        settings = [v for v in self.wire() if v.get('method')=='thread/settings/update'][-1]['params']
        self.assertEqual(settings['approvalPolicy'], 'never')
        self.assertEqual(settings['sandboxPolicy'], {'type':'dangerFullAccess'})
        self.assertNotIn('sandbox', settings)

    def test_new_chats_use_current_permissions_without_changing_existing_chats(self):
        self.connect(fullAccess=False)
        self.assert_chat_permissions(False)
        default_chat = dict(self.identity)
        # Keep work in flight while creating chats with both permission modes.
        receipt = self.core.request('turn.start', dict(self.identity, message='hold-for-interrupt', clientOperationId='held-default'))
        full = self.core.request('session.create', dict(self.identity, fullAccess=True))
        start = [v for v in self.wire() if v.get('method') == 'thread/start'][-1]['params']
        self.assertEqual(start['approvalPolicy'], 'never')
        self.assertEqual(start['sandbox'], 'danger-full-access')
        self.identity['sessionId'] = full['sessionId']
        self.assert_chat_permissions(True)
        full_chat = dict(self.identity)
        default = self.core.request('session.create', dict(self.identity, fullAccess=False))
        start = [v for v in self.wire() if v.get('method') == 'thread/start'][-1]['params']
        self.assertNotIn('approvalPolicy', start)
        self.assertNotIn('sandbox', start)
        self.identity['sessionId'] = default['sessionId']
        self.assert_chat_permissions(False)
        self.core.request('turn.interrupt', dict(default_chat, turnId=receipt['turnId']))
        self.core.completed(receipt['clientOperationId'])
        for identity, full_access in [(full_chat, True), (default_chat, False)]:
            self.identity = identity
            self.core.request('session.open', self.identity)
            self.assert_chat_permissions(full_access)
            fork = self.core.request('session.fork', self.identity)
            self.identity = dict(identity, sessionId=fork['sessionId'])
            self.assert_chat_permissions(full_access)
        self.assertEqual(len([v for v in self.wire() if 'launchArgs' in v]), 1)

    def test_disabling_full_access_after_first_connect_restores_runtime_defaults(self):
        self.connect(fullAccess=True)
        self.assert_chat_permissions(True)
        connection = self.core.request('session.create', dict(self.identity, fullAccess=False))
        self.identity['sessionId'] = connection['sessionId']
        self.assert_chat_permissions(False)
        launch = next(v for v in self.wire() if 'launchArgs' in v)
        self.assertNotIn('approval_policy="never"', launch['launchArgs'])
        self.assertNotIn('sandbox_mode="danger-full-access"', launch['launchArgs'])

    def test_permissions_survive_app_restart_and_do_not_escalate_saved_chats(self):
        self.connect(fullAccess=True)
        self.assert_chat_permissions(True)
        full_chat = dict(self.identity)
        connection = self.core.request('session.create', dict(self.identity, fullAccess=False))
        self.identity['sessionId'] = connection['sessionId']
        self.assert_chat_permissions(False)
        default_id = self.identity['sessionId']
        self.core.close()
        self.core = Core(self.env)
        self.addCleanup(self.core.close)
        self.core.request('core.initialize')
        # The toggle governs new chats; reconnecting a saved default chat with
        # Full access enabled must leave that chat's policy alone.
        self.connect(fullAccess=True)
        self.assertEqual(self.identity['sessionId'], default_id)
        self.assert_chat_permissions(False)
        self.identity = full_chat
        self.core.request('session.open', self.identity)
        self.assert_chat_permissions(True)
        fork = self.core.request('session.fork', self.identity)
        self.identity['sessionId'] = fork['sessionId']
        self.assert_chat_permissions(True)

    def assert_chat_permissions(self, full_access):
        receipt = self.core.request('turn.start', dict(self.identity, message='fixture permission check', clientOperationId='policy:' + str(self.core.sequence)))
        self.core.completed(receipt['clientOperationId'])
        self.core.request('session.goal', dict(self.identity, action='set', objective='fixture goal', model='fixture-model'))
        relevant = [v for v in self.wire() if v.get('method') in ('turn/start', 'thread/settings/update') and v['params'].get('threadId') == self.identity['sessionId']][-2:]
        self.assertEqual(len(relevant), 2)
        for request in relevant:
            params = request['params']
            if full_access:
                self.assertEqual(params.get('approvalPolicy'), 'never')
                self.assertEqual(params.get('sandboxPolicy'), {'type':'dangerFullAccess'})
            else:
                self.assertNotIn('approvalPolicy', params)
                self.assertNotIn('sandboxPolicy', params)

    def test_acp_full_access_grants_the_runtime_offered_once_option(self):
        self.core.close()
        env = {k: v for k, v in self.env.items() if not k.startswith('ZOMMI_CODEX_')}
        env.update(ZOMMI_HERMES_COMMAND=sys.executable,
                   ZOMMI_HERMES_ARGS_JSON=json.dumps([str(FIXTURES / 'fake_acp_runtime.py')]))
        self.core = Core(env)
        self.addCleanup(self.core.close)
        self.core.request('core.initialize')
        target = next(t['id'] for t in self.core.request('runtime.discover')['targets'] if t['adapterId'] == 'hermes-acp')
        connection = self.core.request('runtime.connect', {'runtimeTargetId':target, 'cwd':str(self.path), 'fullAccess':True, 'newSession':True})
        receipt = self.core.request('turn.start', {'runtimeTargetId':target, 'sessionId':connection['sessionId'], 'message':'request-approval', 'clientOperationId':'acp-full-access'})
        self.core.completed(receipt['clientOperationId'])
        self.assertFalse(any(e['name']=='approval.requested' for e in self.core.events))
        response = next(v for v in self.wire() if v.get('id')=='permission-1' and 'result' in v)
        self.assertEqual(response['result'], {'outcome':{'outcome':'selected','optionId':'allow_once'}})
        self.assertEqual(next(v['permissionEnvironment'] for v in self.wire() if 'permissionEnvironment' in v)['HERMES_YOLO_MODE'], '1')

    def test_runtime_default_does_not_override_user_policy(self):
        self.connect()
        start = next(v for v in self.wire() if v.get('method')=='thread/start')
        self.assertNotIn('approvalPolicy', start['params'])
        self.assertNotIn('sandbox', start['params'])


if __name__ == '__main__':
    unittest.main()
