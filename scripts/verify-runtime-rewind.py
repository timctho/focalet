#!/usr/bin/env python3
"""Verify native runtime rewinds via Rust using isolated homes and a local model."""
from runtime_environment import without_parent_context

import argparse
import asyncio
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import tempfile
import threading
import time
import socket
from urllib.request import urlopen


class Model(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        body = json.dumps({'object': 'list', 'data': [{'id': 'fixture', 'object': 'model'}]}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
        self.server.requests.append(body)
        base = {'id': 'chatcmpl-local', 'object': 'chat.completion', 'created': int(time.time()), 'model': 'fixture'}
        if body.get('stream'):
            base['object'] = 'chat.completion.chunk'
            frames = [{**base, 'choices': [{'index': 0, 'delta': {'role': 'assistant', 'content': 'READY'}, 'finish_reason': None}]},
                      {**base, 'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}], 'usage': {'prompt_tokens': 1, 'completion_tokens': 1, 'total_tokens': 2}}]
            data = ''.join('data: ' + json.dumps(frame) + '\n\n' for frame in frames).encode() + b'data: [DONE]\n\n'
            content_type = 'text/event-stream'
        else:
            data = json.dumps({**base, 'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': 'READY'}, 'finish_reason': 'stop'}],
                               'usage': {'prompt_tokens': 1, 'completion_tokens': 1, 'total_tokens': 2}}).encode()
            content_type = 'application/json'
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


async def verify(mode, root):
    repo = Path(__file__).resolve().parent.parent
    root.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Model)
    server.requests = []
    threading.Thread(target=server.serve_forever, daemon=True).start()
    # Retain the user's shell/runtime launch tools, but isolate provider config.
    environment = {k: v for k, v in without_parent_context(os.environ).items() if not any(fragment in k for fragment in ['API_KEY', 'TOKEN', 'SECRET', 'PASSWORD']) and not k.startswith('FOCALET_')}
    environment.update({
        'FOCALET_CORE_STATE_PATH': str(root / 'binding.json'),
        'FOCALET_RUNTIME_OVERRIDES_PATH': str(root / 'overrides.json'),
        'FOCALET_RUNTIME_DISCOVERY_CACHE_PATH': str(root / 'discovery.json'),
    })
    endpoint = f'http://127.0.0.1:{server.server_port}/v1'
    gateway = None
    if mode == 'pi':
        (root / 'models.json').write_text(json.dumps({'providers': {'fixture': {
            'baseUrl': endpoint, 'api': 'openai-completions', 'apiKey': 'fixture-local',
            'models': [{'id': 'fixture', 'contextWindow': 64000, 'maxTokens': 4096}]
        }}}))
        environment.update({'PI_CODING_AGENT_DIR': str(root), 'PI_CODING_AGENT_SESSION_DIR': str(root / 'sessions'),
            'FOCALET_PI_COMMAND': shutil.which('pi'),
            'FOCALET_PI_ARGS_JSON': json.dumps(['--mode', 'rpc', '--provider', 'fixture', '--model', 'fixture', '--no-extensions', '--no-skills', '--no-prompt-templates'])})
    elif mode == 'hermes':
        (root / 'config.yaml').write_text(f'model:\n  default: fixture\n  provider: custom\n  base_url: {endpoint}\n  api_key: fixture-local\n  api_mode: chat_completions\n')
        environment.update({'HERMES_HOME': str(root), 'OPENAI_API_KEY': 'fixture-local', 'OPENAI_BASE_URL': endpoint,
                            'FOCALET_HERMES_COMMAND': shutil.which('hermes')})
    else:
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        config = {'gateway': {'mode': 'local', 'port': port, 'auth': {'mode': 'token', 'token': 'fixture-local'}},
            'agents': {'defaults': {'model': {'primary': 'fixture/fixture'}, 'workspace': str(root / 'workspace')}},
            'plugins': {'entries': {'memory-core': {'enabled': False}}},
            'models': {'providers': {'fixture': {'baseUrl': endpoint, 'apiKey': 'fixture-local', 'api': 'openai-completions',
                'models': [{'id': 'fixture', 'name': 'Fixture', 'contextWindow': 64000, 'maxTokens': 4096}]}}}}
        (root / 'openclaw.json').write_text(json.dumps(config))
        environment.update({'OPENCLAW_STATE_DIR': str(root), 'OPENCLAW_CONFIG_PATH': str(root / 'openclaw.json'),
            'OPENCLAW_GATEWAY_TOKEN': 'fixture-local', 'FOCALET_OPENCLAW_GATEWAY_URL': f'ws://127.0.0.1:{port}',
            'FOCALET_OPENCLAW_DEVICE_IDENTITY_PATH': str(root / 'device.json')})
    core = None
    async def start_gateway():
        nonlocal gateway
        gateway = await asyncio.create_subprocess_exec(shutil.which('openclaw'), 'gateway', '--port', str(port),
            env=environment, cwd=root, stdout=(root / 'gateway.log').open('a'), stderr=asyncio.subprocess.STDOUT)
        def ready():
            with urlopen(f'http://127.0.0.1:{port}/readyz', timeout=2) as response:
                return response.status == 200
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if gateway.returncode is not None:
                raise RuntimeError('Isolated OpenClaw gateway exited during startup')
            try:
                if await asyncio.to_thread(ready):
                    break
            except OSError:
                await asyncio.sleep(.25)
        else:
            raise RuntimeError('Isolated OpenClaw gateway did not start')
    try:
        if mode == 'openclaw':
            await start_gateway()
        async def launch():
            return await asyncio.create_subprocess_exec(str(repo / 'target/debug/focalet-core-host'), cwd=root, env=environment,
                stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=(root / 'core.log').open('a'), limit=64 * 1024 * 1024)
        core = await launch()
        seq = 0
        events = []
        async def receive():
            line = await asyncio.wait_for(core.stdout.readline(), 60)
            if not line:
                raise RuntimeError('Core exited')
            value = json.loads(line)
            if 'event' in value:
                events.append(value['event'])
            return value
        async def request(operation, payload=None):
            nonlocal seq
            seq += 1
            identity = str(seq)
            core.stdin.write((json.dumps({'id': identity, 'protocolVersion': 1, 'operation': operation, 'payload': payload or {}}) + '\n').encode())
            await core.stdin.drain()
            while True:
                value = await receive()
                if value.get('id') == identity:
                    if not value.get('ok'):
                        raise RuntimeError(f'{operation}: {value.get("error")}')
                    return value['result']
        await request('core.initialize')
        discovery = await request('runtime.discover')
        adapter = 'pi-rpc' if mode == 'pi' else mode + '-gateway'
        target = next(t for t in discovery['targets'] if t['adapterId'] == adapter and (mode == 'openclaw' or t['executionHost']['kind'] == 'native'))
        selected = {'runtimeTargetId': target['id'], 'cwd': str(root)}
        connection = await request('runtime.connect', selected)
        assert 'session.rewind.v1' in connection['capabilities'], connection['capabilities']
        selected['sessionId'] = connection['sessionId']
        async def send(text):
            receipt = await request('turn.start', {**selected, 'message': text, 'clientOperationId': text})
            def complete():
                return next((e for e in events if e['name'] == 'turn.completed' and e.get('turnId') == receipt['turnId']), None)
            while complete() is None:
                await receive()
            assert complete()['payload']['status'] == 'completed', complete()
        for text in ['REWIND_KEEP', 'REWIND_DROP_ORIGINAL', 'REWIND_DROP_LATER']:
            await send(text)
        before = await request('session.rewind.prepare', selected)
        turns = before['thread']['turns']
        assert len(turns) == 3, before
        print(f'{mode}: native history prepared', flush=True)
        result = await request('session.rewind', {**selected, 'turnId': turns[1]['id'], 'expectedLastTurnId': turns[-1]['id']})
        selected['sessionId'] = result['thread']['id']
        assert len(result['thread']['turns']) == 1, result
        await send('REWIND_REPLACEMENT')
        provider = next(value for value in reversed(server.requests) if 'REWIND_REPLACEMENT' in json.dumps(value.get('messages', [])))
        serialized = json.dumps(provider['messages'])
        assert 'REWIND_KEEP' in serialized and 'REWIND_DROP' not in serialized, serialized
        # Reopen and restart the actual runtime through the persisted native binding.
        await request('session.open', selected)
        await request('core.shutdown')
        await core.wait()
        if gateway is not None:
            gateway.terminate()
            await asyncio.wait_for(gateway.wait(), 30)
            await start_gateway()
        core = await launch()
        await request('core.initialize')
        await request('runtime.discover')
        resumed = await request('runtime.connect', {'runtimeTargetId': target['id']})
        assert resumed['sessionId'] == selected['sessionId']
        after = await request('session.rewind.prepare', selected)
        assert len(after['thread']['turns']) == 2, after
        assert 'REWIND_DROP' not in json.dumps(after), after
        result = {'runtime': mode, 'status': 'passed', 'middleEditRemovedSuffix': True,
                  'providerInputExcludedRemovedMessages': True, 'runtimeRestartPreservedRewind': True,
                  'newBranch': connection['sessionId'] != selected['sessionId'],
                  'coreSha256': hashlib.sha256((repo / 'target/debug/focalet-core-host').read_bytes()).hexdigest(),
                  'sourceSha256': {str(path.relative_to(repo)): hashlib.sha256(path.read_bytes()).hexdigest()
                      for path in [repo / 'crates/focalet-core-host/src/main.rs',
                                   *sorted((repo / 'crates/focalet-core/src').glob('*.rs'))]}}
        (root / 'verification.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result), flush=True)
        return result
    finally:
        if core and core.returncode is None:
            core.terminate()
            await core.wait()
        if gateway and gateway.returncode is None:
            gateway.terminate()
            await gateway.wait()
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', choices=['pi', 'hermes', 'openclaw'], required=True)
    parser.add_argument('--output-directory', type=Path)
    args = parser.parse_args()
    directory = args.output_directory or Path(tempfile.mkdtemp(prefix=f'focalet-real-{args.runtime}-rewind-'))
    asyncio.run(verify(args.runtime, directory.resolve()))
