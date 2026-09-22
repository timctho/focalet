#!/usr/bin/env python3
"""Exercise real Codex writer contention using only a local model fixture."""
from runtime_environment import without_parent_context

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer

ROOT = Path(__file__).resolve().parent.parent


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def verify(core_host, codex):
    os.environ['ZOMMI_TEST_CORE_HOST'] = str(Path(core_host).resolve())
    bridge = module('bridge', ROOT / 'tests/test_codex_home_persistence.py')
    fixture = module('fixture', ROOT / 'tests/fake_responses_server.py')
    with tempfile.TemporaryDirectory(prefix='zommi-writer-recovery-') as directory:
        root = Path(directory)
        server = ThreadingHTTPServer(('127.0.0.1', 0), fixture.Handler)
        server.request_log = root / 'provider-request.json'
        threading.Thread(target=server.serve_forever, daemon=True).start()
        (root / 'config.toml').write_text(
            'model = "gpt-5.4"\nmodel_provider = "local_fixture"\n'
            '[model_providers.local_fixture]\nname = "Local fixture"\n'
            f'base_url = "http://127.0.0.1:{server.server_port}/v1"\n'
            'wire_api = "responses"\nrequires_openai_auth = false\n')
        clients = []

        def connect(name, preferred=None):
            environment = without_parent_context(os.environ)
            environment.update(CODEX_HOME=str(root), ZOMMI_CODEX_COMMAND=str(Path(codex).absolute()),
                               ZOMMI_CODEX_ARGS_JSON='["app-server"]',
                               ZOMMI_CORE_STATE_PATH=str(root / name / 'binding.json'),
                               ZOMMI_RUNTIME_OVERRIDES_PATH=str(root / name / 'overrides.json'),
                               ZOMMI_RUNTIME_DISCOVERY_CACHE_PATH=str(root / name / 'discovery.json'))
            core = bridge.Core(environment)
            clients.append(core)
            request(core, 'core.initialize')
            targets = request(core, 'runtime.discover')['targets']
            target = next(t for t in targets if t['adapterId'] == 'codex-app-server' and t['executionHost']['kind'] == 'native')
            base = {'runtimeTargetId': target['id'], 'cwd': str(root)}
            connection = request(core, 'runtime.connect', {**base, **({'preferredSessionId': preferred} if preferred else {})})
            return core, base, connection

        def request(core, operation, payload=None):
            response = core.request(operation, payload)
            assert response['ok'], (operation, response.get('error'))
            return response['result']

        def event(core, name, seconds=40):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                message = core.messages.get(timeout=max(1, deadline-time.monotonic()))
                value = (message or {}).get('event', {})
                if value.get('name') == name:
                    return value
            raise AssertionError('Missing ' + name)

        try:
            owner, base, initial = connect('owner')
            session = initial['sessionId']
            request(owner, 'turn.start', {**base, 'sessionId': session, 'message': 'Reply READY', 'clientOperationId': 'fixture:first'})
            assert event(owner, 'turn.completed')['payload']['status'] == 'completed'
            reader, base, locked = connect('reader', session)
            assert locked['sessionId'] == session and locked['sessionMetadata']['readOnly'] is True
            another = request(reader, 'session.create', base)['sessionId']
            for _ in range(10):
                locked = request(reader, 'session.open', {**base, 'sessionId': session})
                assert locked['sessionMetadata']['readOnly'] is True
                assert locked['history']['thread']['turns'], 'Locked history was lost'
                request(reader, 'session.open', {**base, 'sessionId': another})
            request(reader, 'session.open', {**base, 'sessionId': session})
            denied = reader.request('turn.start', {**base, 'sessionId': session, 'message': 'Never send this', 'clientOperationId': 'fixture:blocked'})
            assert not denied['ok'] and denied['error']['code'] == 'session-busy'
            owner.close()
            clients.remove(owner)
            while True:
                refreshed = event(reader, 'session.refreshed')
                if refreshed['payload']['connection']['sessionMetadata']['readOnly'] is False:
                    break
            request(reader, 'turn.start', {**base, 'sessionId': session, 'message': 'Reply READY', 'clientOperationId': 'fixture:resumed'})
            assert event(reader, 'turn.completed')['payload']['status'] == 'completed'
            history = request(reader, 'session.read', {**base, 'sessionId': session})
            assert len(history['thread']['turns']) == 2, 'Duplicate or missing generation'
            print(json.dumps({'status': 'passed', 'runtimeVersion': locked.get('runtimeVersion'),
                              'busyChatSwitches': 10, 'historyPreserved': True,
                              'automaticWriterRecovery': True, 'completedTurns': 2,
                              'blockedPromptNotSent': True}, indent=2))
        finally:
            for core in clients:
                core.close()
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core-host', default='target/debug/zommi-core-host')
    parser.add_argument('--codex', default=shutil.which('codex'))
    args = parser.parse_args()
    verify(args.core_host, args.codex)
