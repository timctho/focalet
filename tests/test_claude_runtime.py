"""Broker-level Claude integration; no agent accounts or external model requests."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from test_runtime_commands import Core, FIXTURES


class ClaudeRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='focalet-claude-')
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('FOCALET_')}
        self.env.update(FOCALET_RUNTIME_DISCOVERY_MODE='configured-only',
                        FOCALET_CLAUDE_COMMAND=sys.executable,
                        FOCALET_CLAUDE_ARGS_JSON=json.dumps([str(FIXTURES / 'fake_claude_runtime.py')]),
                        FOCALET_FAKE_CLAUDE_STORE=str(self.path / 'sessions'),
                        FOCALET_FAKE_REQUEST_LOG=str(self.path / 'wire.jsonl'),
                        FOCALET_CORE_STATE_PATH=str(self.path / 'binding.json'),
                        FOCALET_RUNTIME_OVERRIDES_PATH=str(self.path / 'overrides.json'),
                        FOCALET_RUNTIME_DISCOVERY_CACHE_PATH=str(self.path / 'targets.json'))
        self.core = self.start()

    def start(self):
        core = Core(self.env)
        self.addCleanup(core.close)
        core.request('core.initialize')
        self.target = core.request('runtime.discover')['targets'][0]
        self.assertEqual(self.target['adapterId'], 'claude-stream-json')
        return core

    def connect(self, **extra):
        result = self.core.request('runtime.connect', dict(runtimeTargetId=self.target['id'], cwd=str(self.path), **extra))
        self.identity = {'runtimeTargetId': self.target['id'], 'sessionId': result['sessionId']}
        return result

    def turn(self, message, **extra):
        operation = 'test:claude:' + str(self.core.sequence)
        payload = dict(self.identity, message=message, clientOperationId=operation, **extra)
        receipt = self.core.request('turn.start', payload)
        self.assertEqual(receipt, self.core.request('turn.start', payload), 'An accepted prompt must never be replayed')
        return operation, receipt

    def test_models_images_context_refresh_and_resume_keep_exact_session(self):
        connection = self.connect()
        self.assertIn('input.image.v1', connection['capabilities'])
        self.assertNotIn('history.read.v1', connection['capabilities'])
        op, receipt = self.turn('remember-synthetic-marker', model='fixture-b',
                                images=['data:image/png;base64,aGVsbG8='],
                                snapshots=[{'selection': ['synthetic-selection']}])
        self.assertEqual(self.core.completed(op)['payload']['status'], 'completed')
        updates = [e for e in self.core.events if e['name'] == 'item.update' and e.get('clientOperationId') == op]
        self.assertEqual(len({e['payload']['itemId'] for e in updates}), 1, 'Final assistant frame updates the streamed block')
        self.assertEqual(updates[-1]['payload']['text'], 'CLAUDE_OK')
        wire = [json.loads(line) for line in (self.path / 'wire.jsonl').read_text().splitlines()]
        prompt = next(v for v in wire if v['type'] == 'user')
        self.assertIn('synthetic-selection', prompt['message']['content'][0]['text'])
        self.assertEqual(prompt['message']['content'][1]['source']['type'], 'base64')
        self.assertTrue(prompt['client_composed'])
        saved = (self.path / 'binding.json').read_text()
        models = self.core.request('runtime.refreshModels', {'runtimeTargetId': self.target['id']})
        self.assertEqual(len(models['models']), 2)
        self.assertEqual((self.path / 'binding.json').read_text(), saved)
        first = self.identity.copy()
        other = self.core.request('session.create', dict(runtimeTargetId=self.target['id'], cwd=str(self.path)))
        self.assertNotEqual(other['sessionId'], first['sessionId'])
        self.core.close()
        self.core = self.start()
        self.connect(preferredSessionId=first['sessionId'])
        self.assertEqual(self.identity, first)
        op, _ = self.turn('recall-now')
        self.core.completed(op)
        self.assertTrue(any('remember-synthetic-marker' in e['payload'].get('text', '') for e in self.core.events if e['name'] == 'item.update'))

    def test_approval_checks_identity_and_explicit_allow_or_deny(self):
        self.connect()
        for option, expected in [('reject_once', 'DENIED'), ('allow_once', 'ALLOWED')]:
            op, _ = self.turn('approve-now')
            while not any(e['name'] == 'approval.requested' for e in self.core.events): self.core.receive()
            wrong = self.core.request('approval.resolve', dict(self.identity, sessionId='wrong', approvalId='approval', optionId=option), ok=False)
            self.assertFalse(wrong['ok'])
            invalid = self.core.request('approval.resolve', dict(self.identity, approvalId='approval', optionId='auto'), ok=False)
            self.assertFalse(invalid['ok'])
            self.core.request('approval.resolve', dict(self.identity, approvalId='approval', optionId=option))
            self.core.completed(op)
            self.assertTrue(any(e['payload'].get('text') == expected for e in self.core.events))
            self.core.events.clear()

    def test_cancel_finishes_once_and_next_prompt_works(self):
        self.connect()
        op, receipt = self.turn('wait-now')
        self.core.request('turn.interrupt', dict(self.identity, turnId=receipt['turnId']))
        self.assertEqual(self.core.completed(op)['payload']['status'], 'interrupted')
        next_op, _ = self.turn('next prompt')
        self.assertEqual(self.core.completed(next_op)['payload']['status'], 'completed')

    def test_disconnect_does_not_replay_and_reconnect_recovers(self):
        self.connect()
        first = self.identity.copy()
        op, _ = self.turn('crash-now')
        self.assertEqual(self.core.completed(op)['payload']['status'], 'unknown')
        self.core.request('runtime.connect', dict(self.identity, preferredSessionId=first['sessionId'], cwd=str(self.path)))
        self.assertEqual(self.identity, first)
        op, _ = self.turn('recovered')
        self.assertEqual(self.core.completed(op)['payload']['status'], 'completed')

    def test_identity_mismatch_and_malformed_stream_never_report_success(self):
        for prompt in ['wrong-session', 'malformed-now']:
            self.connect(newSession=True)
            op, _ = self.turn(prompt)
            self.assertEqual(self.core.completed(op)['payload']['status'], 'unknown')

    def test_missing_auth_is_actionable(self):
        self.core.close()
        self.env['FOCALET_FAKE_CLAUDE_AUTH'] = 'missing'
        self.core = self.start()
        result = self.core.request('runtime.connect', {'runtimeTargetId': self.target['id'], 'cwd':str(self.path)}, ok=False)
        self.assertEqual(result['error']['code'], 'authentication-required')

    def test_older_cli_retries_without_optional_partial_flag_and_keeps_permissions(self):
        self.core.close()
        self.env['FOCALET_CLAUDE_ARGS_JSON'] = json.dumps([
            str(FIXTURES / 'fake_claude_runtime.py'), '--include-partial-messages',
            '--permission-prompt-tool', 'stdio'])
        self.env['FOCALET_FAKE_CLAUDE_REJECT_PARTIAL'] = '1'
        self.core = self.start()
        self.connect(fullAccess=True)
        operation, _ = self.turn('one accepted prompt')
        self.assertEqual(self.core.completed(operation)['payload']['status'], 'completed')
        self.core.request('session.create', {'runtimeTargetId': self.target['id'], 'cwd': str(self.path)})
        wire = [json.loads(line) for line in (self.path / 'wire.jsonl').read_text().splitlines()]
        launches = [v for v in wire if v['type'] == 'fixture_launch']
        self.assertEqual(len(launches), 3)
        self.assertIn('--include-partial-messages', launches[0]['launchArgs'])
        for launch in launches[1:]:
            self.assertNotIn('--include-partial-messages', launch['launchArgs'])
            self.assertIn('--permission-prompt-tool', launch['launchArgs'])
        permissions = launches[1]['launchArgs']
        self.assertEqual(permissions[permissions.index('--permission-mode') + 1], 'bypassPermissions')
        self.assertEqual(sum(v['type'] == 'user' for v in wire), 1)

    def test_required_flag_failure_keeps_stderr_and_does_not_remove_permissions(self):
        self.core.close()
        self.env['FOCALET_FAKE_CLAUDE_STARTUP_ERROR'] = "error: unknown option '--permission-prompt-tool'"
        self.core = self.start()
        result = self.core.request('runtime.connect', {'runtimeTargetId': self.target['id'], 'cwd': str(self.path)}, ok=False)
        self.assertEqual(result['error']['code'], 'runtime-update-required')
        self.assertIn('--permission-prompt-tool', result['error']['message'])
        self.assertIn('claude update', result['error']['message'])
        launches = [json.loads(line) for line in (self.path / 'wire.jsonl').read_text().splitlines()]
        self.assertEqual(sum(v['type'] == 'fixture_launch' for v in launches), 1)

    def test_legacy_resume_requires_update_without_touching_saved_chat(self):
        self.core.close()
        self.env['FOCALET_CLAUDE_ARGS_JSON'] = json.dumps([
            str(FIXTURES / 'fake_claude_runtime.py'), '--include-partial-messages',
            '--permission-prompt-tool', 'stdio'])
        old_cli = self.path / 'old-cli'
        old_cli.touch()
        self.env['FOCALET_FAKE_CLAUDE_REJECT_PARTIAL'] = str(old_cli)
        self.core = self.start()
        self.connect()
        operation, _ = self.turn('crash-now')
        self.assertEqual(self.core.completed(operation)['payload']['status'], 'unknown')
        binding = (self.path / 'binding.json').read_bytes()
        files = {p: p.read_bytes() for p in (self.path / 'sessions').glob('*.json')}
        for restart in [False, True]:
            if restart:
                self.core.close()
                self.core = self.start()
            rejected = self.core.request('runtime.connect', dict(
                runtimeTargetId=self.target['id'], preferredSessionId=self.identity['sessionId'],
                cwd=str(self.path)), ok=False)
            self.assertEqual(rejected['error']['code'], 'runtime-update-required')
            self.assertEqual((self.path / 'binding.json').read_bytes(), binding)
            self.assertEqual({p: p.read_bytes() for p in (self.path / 'sessions').glob('*.json')}, files)
        launches = [json.loads(line) for line in (self.path / 'wire.jsonl').read_text().splitlines()]
        resumes = [v for v in launches if v['type'] == 'fixture_launch' and '--resume' in v['launchArgs']]
        self.assertEqual(len(resumes), 2, 'Only the rejected argv probe runs; no legacy resume fallback')
        self.assertTrue(all('--include-partial-messages' in v['launchArgs'] for v in resumes))
        old_cli.unlink()
        self.connect(preferredSessionId=self.identity['sessionId'])
        operation, _ = self.turn('recall-now')
        self.assertEqual(self.core.completed(operation)['payload']['status'], 'completed')
        self.assertTrue(any('crash-now' in e['payload'].get('text', '')
                            for e in self.core.events if e['name'] == 'item.update'))

    def test_startup_timeout_does_not_poison_the_next_connection(self):
        store = self.path / 'sessions'
        store.mkdir()
        marker = store / 'stall-startup'
        marker.touch()
        self.core.receive_timeout = 40
        result = self.core.request('runtime.connect', {'runtimeTargetId':self.target['id'], 'cwd':str(self.path)}, ok=False)
        self.assertEqual(result['error']['code'], 'runtime-timeout')
        marker.unlink()
        self.connect()
        op, _ = self.turn('after startup timeout')
        self.assertEqual(self.core.completed(op)['payload']['status'], 'completed')

    def test_background_turn_remains_attached_to_its_original_session(self):
        self.connect()
        first = self.identity.copy()
        op, receipt = self.turn('wait-now')
        second = self.core.request('session.create', {'runtimeTargetId': self.target['id'], 'cwd':str(self.path)})
        self.identity['sessionId'] = second['sessionId']
        next_op, _ = self.turn('other conversation')
        self.assertEqual(self.core.completed(next_op)['sessionId'], second['sessionId'])
        self.core.request('turn.interrupt', dict(first, turnId=receipt['turnId']))
        self.assertEqual(self.core.completed(op)['sessionId'], first['sessionId'])

    def test_rejected_new_chat_model_preserves_the_previous_binding_and_chat(self):
        self.connect()
        saved = (self.path / 'binding.json').read_bytes()
        result = self.core.request('session.create', {'runtimeTargetId': self.target['id'], 'cwd':str(self.path), 'model':'unavailable-model'}, ok=False)
        self.assertEqual(result['error']['code'], 'invalid-request')
        self.assertEqual((self.path / 'binding.json').read_bytes(), saved)
        op, _ = self.turn('still in the original conversation')
        self.assertEqual(self.core.completed(op)['sessionId'], self.identity['sessionId'])


if __name__ == '__main__':
    unittest.main()
