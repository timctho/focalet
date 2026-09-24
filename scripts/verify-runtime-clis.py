#!/usr/bin/env python3
"""Run the real broker and pinned Gemini/Claude CLIs with synthetic model replies.

CI runs this inside a network namespace with only loopback enabled. All accounts,
runtime settings, workspaces and session files are temporary; no credentials are
read from the developer's CLI configuration.
"""
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import threading
import unittest
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
from test_runtime_commands import Core  # noqa: E402

PACKAGES = ROOT / 'tests/runtime-clis/node_modules'
PIXEL = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jG9sAAAAASUVORK5CYII='


class ModelServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(('127.0.0.1', 0), ModelHandler)
        self.requests = []


class ModelHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
        self.server.requests.append(body)
        if 'count_tokens' in self.path:
            self.send_json({'input_tokens': 10})
            return
        if not self.path.startswith('/v1/messages'):
            self.send_error(404)
            return
        messages = body['messages']
        # Newer CLIs append environment context after the user prompt.
        relevant = [m for m in messages if m.get('role') == 'user' and any(marker in json.dumps(m['content']) for marker in ['synthetic-session-marker', 'request-tool', 'recall-marker', 'tool_result'])]
        last = relevant[-1]['content']
        last = last if isinstance(last, list) else [{'type': 'text', 'text': last}]
        text = '\n'.join(b.get('text', '') for b in last)
        tool_result = any(b['type'] == 'tool_result' for b in last)
        tool = 'request-tool' in text and not tool_result
        answer = 'CLAUDE_REAL_CLI_OK'
        if 'recall-marker' in text:
            answer = 'REMEMBERED' if 'synthetic-session-marker' in json.dumps(messages[:-1]) else 'MISSING'
        if tool_result:
            answer = 'TOOL_DENIED' if any(b.get('is_error') for b in last) else 'TOOL_DONE'
        block = {'type': 'tool_use', 'id': 'tool_' + uuid.uuid4().hex, 'name': 'Write',
                 'input': {'file_path': self.server.output_file, 'content': 'synthetic tool output'}} if tool else {'type': 'text', 'text': answer}
        response = {'id': 'msg_' + uuid.uuid4().hex, 'type': 'message', 'role': 'assistant',
                    'model': body['model'], 'content': [block], 'stop_reason': 'tool_use' if tool else 'end_turn',
                    'stop_sequence': None, 'usage': {'input_tokens': 10, 'output_tokens': 5}}
        if not body.get('stream'):
            self.send_json(response)
            return
        events = [
            {'type': 'message_start', 'message': {**response, 'content': [], 'stop_reason': None}},
            {'type': 'content_block_start', 'index': 0, 'content_block': {**block, 'input': {}} if tool else {'type': 'text', 'text': ''}},
            {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'input_json_delta', 'partial_json': json.dumps(block['input'])} if tool else {'type': 'text_delta', 'text': answer}},
            {'type': 'content_block_stop', 'index': 0},
            {'type': 'message_delta', 'delta': {'stop_reason': response['stop_reason'], 'stop_sequence': None}, 'usage': {'output_tokens': 5}},
            {'type': 'message_stop'},
        ]
        payload = ''.join('event: ' + e['type'] + '\ndata: ' + json.dumps(e) + '\n\n' for e in events).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def send_json(self, value):
        payload = json.dumps(value).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


class RealCliTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix='zommi-real-cli-')
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name)
        self.workspace = self.path / 'workspace'
        self.workspace.mkdir()
        # Only OS/toolchain variables cross the isolation boundary. In particular,
        # no provider keys, cloud credentials, proxy routing or parent CLI settings.
        allowed = {'PATH', 'Path', 'PATHEXT', 'SystemRoot', 'WINDIR', 'COMSPEC',
                   'LD_LIBRARY_PATH', 'TMP', 'TEMP', 'LANG', 'LC_ALL'}
        self.env = {k: v for k, v in os.environ.items() if k in allowed}
        isolated_home = self.path / 'home'
        isolated_home.mkdir()
        self.env.update(HOME=str(isolated_home), USERPROFILE=str(isolated_home), XDG_CONFIG_HOME=str(isolated_home / '.config'))
        self.env.update(ZOMMI_RUNTIME_DISCOVERY_MODE='configured-only',
                        ZOMMI_CORE_STATE_PATH=str(self.path / 'binding.json'),
                        ZOMMI_RUNTIME_OVERRIDES_PATH=str(self.path / 'overrides.json'),
                        ZOMMI_RUNTIME_DISCOVERY_CACHE_PATH=str(self.path / 'discovery.json'))
        self.serial = 0

    def connect(self, runtime, preferred=None, *, full_access=False):
        self.core = Core(self.env)
        self.addCleanup(self.core.close)
        self.core.request('core.initialize')
        target = next(t for t in self.core.request('runtime.discover')['targets'] if t['runtimeId'] == runtime)
        self.target = target['id']
        connection = self.core.request('runtime.connect', {'runtimeTargetId':self.target, 'cwd':str(self.workspace), 'preferredSessionId':preferred, 'newSession':preferred is None, 'fullAccess':full_access})
        self.identity = {'runtimeTargetId':self.target, 'sessionId':connection['sessionId']}
        return connection

    def turn(self, text, **extra):
        self.serial += 1
        operation = 'real-cli:' + str(self.serial)
        receipt = self.core.request('turn.start', dict(self.identity, message=text, clientOperationId=operation, **extra))
        return operation, receipt

    def reply(self, operation):
        self.assertEqual(self.core.completed(operation)['payload']['status'], 'completed')
        blocks = {}
        for e in self.core.events:
            if e['name'] == 'item.update' and e.get('clientOperationId') == operation and e['payload'].get('kind') == 'assistant':
                p = e['payload']
                key = p.get('itemId', '')
                blocks[key] = blocks.get(key, '') + p.get('text', '') if p.get('textMode') == 'append' else p.get('text', '')
        return '\n'.join(blocks.values())

    def test_gemini_real_acp_models_images_refresh_and_safe_resume_rejection(self):
        package = PACKAGES / '@google/gemini-cli'
        self.assertEqual(json.loads((package / 'package.json').read_text())['version'], '0.61.0')
        home = self.path / 'gemini'
        settings = home / '.gemini/settings.json'
        settings.parent.mkdir(parents=True)
        settings.write_text(json.dumps({'security': {'auth': {'selectedType': 'gemini-api-key'}},
                                        'telemetry': {'enabled': False}, 'privacy': {'usageStatisticsEnabled': False}}))
        response = {'candidates': [{'content': {'role': 'model', 'parts': [{'text': 'GEMINI_REAL_CLI_OK'}]}, 'finishReason': 'STOP'}],
                    'usageMetadata': {'promptTokenCount': 1, 'candidatesTokenCount': 5, 'totalTokenCount': 6}}
        fixture = self.path / 'responses.jsonl'
        fixture.write_text(''.join(json.dumps(v) + '\n' for _ in range(20) for v in [
            {'method': 'generateContent', 'response': response},
            {'method': 'generateContentStream', 'response': [response]},
            {'method': 'countTokens', 'response': {'totalTokens': 1}},
        ]))
        self.env.update(GEMINI_CLI_HOME=str(home), GEMINI_CLI_NO_RELAUNCH='1',
                        GEMINI_API_KEY='fixture-not-a-real-key', GOOGLE_GEMINI_BASE_URL='http://127.0.0.1:9',
                        ZOMMI_GEMINI_COMMAND=shutil.which('node'),
                        ZOMMI_GEMINI_ARGS_JSON=json.dumps([str(package / 'bundle/gemini.js'), '--acp', '--fake-responses-non-strict', str(fixture), '--model', 'gemini-2.5-flash']))
        connection = self.connect('gemini')
        self.assertTrue(connection['models'])
        self.assertIn('input.image.v1', connection['capabilities'])
        op, _ = self.turn('synthetic-session-marker', images=[PIXEL], snapshots=[{'selection':['synthetic selected text']}])
        self.assertIn('GEMINI_REAL_CLI_OK', self.reply(op))
        saved_id = self.identity['sessionId']
        saved_binding = (self.path / 'binding.json').read_text()
        self.assertTrue(self.core.request('runtime.refreshModels', {'runtimeTargetId':self.target})['models'])
        self.assertEqual((self.path / 'binding.json').read_text(), saved_binding)
        op, _ = self.turn('after refresh')
        self.assertIn('GEMINI_REAL_CLI_OK', self.reply(op))
        self.assertNotIn('session.resume.v1', connection['capabilities'])
        self.core.close()
        files = {p: p.read_bytes() for p in home.rglob('*.jsonl') if json.loads(p.read_text().splitlines()[0]).get('sessionId') == saved_id}
        self.assertEqual(len(files), 1)
        self.core = Core(self.env)
        self.addCleanup(self.core.close)
        self.core.request('core.initialize')
        self.core.request('runtime.discover')
        resumed = self.core.request('runtime.connect', {'runtimeTargetId': self.target, 'cwd': str(self.workspace), 'preferredSessionId': saved_id}, ok=False)
        self.assertEqual(resumed['error']['code'], 'capability-unavailable')
        self.assertIn('0.60/0.61', resumed['error']['message'])
        self.assertEqual({p: p.read_bytes() for p in files}, files, 'Known-broken session/load must never touch saved conversation files')
        self.assertEqual((self.path / 'binding.json').read_text(), saved_binding)
        self.core.close()
        self.connect('gemini', full_access=True)
        op, _ = self.turn('full access fixture')
        self.assertIn('GEMINI_REAL_CLI_OK', self.reply(op))
        self.assertFalse(any(e['name'] == 'approval.requested' for e in self.core.events))

    def test_claude_real_stream_models_context_approval_refresh_and_restart_resume(self):
        package = PACKAGES / '@anthropic-ai/claude-code'
        self.assertEqual(json.loads((package / 'package.json').read_text())['version'], '2.1.281')
        server = ModelServer()
        server.output_file = str(self.workspace / 'approved.txt')
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.env.update(CLAUDE_CONFIG_DIR=str(self.path / 'claude'),
                        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1', DISABLE_AUTOUPDATER='1',
                        ANTHROPIC_API_KEY='fixture-not-a-real-key', ANTHROPIC_BASE_URL=f'http://127.0.0.1:{server.server_port}',
                        ZOMMI_CLAUDE_COMMAND=str(PACKAGES / '.bin/claude'),
                        ZOMMI_CLAUDE_ARGS_JSON=json.dumps(['--print','--verbose','--input-format','stream-json','--output-format','stream-json',
                            '--include-partial-messages','--permission-prompt-tool','stdio','--setting-sources','','--strict-mcp-config','--mcp-config','{"mcpServers":{}}']))
        connection = self.connect('claude')
        self.assertTrue(connection['models'])
        model = connection['models'][0]['id']
        op, _ = self.turn('synthetic-session-marker', model=model, images=[PIXEL], snapshots=[{'selection':['synthetic selected text']}])
        self.assertEqual(self.reply(op), 'CLAUDE_REAL_CLI_OK')
        prompt = next(m['content'] for request in server.requests for m in request['messages'] if 'synthetic-session-marker' in json.dumps(m))
        self.assertIn('synthetic selected text', json.dumps(prompt))
        self.assertTrue(any(b['type'] == 'image' for b in prompt))
        self.assertTrue(self.core.request('runtime.refreshModels', {'runtimeTargetId':self.target})['models'])
        self.assertFalse(any(e['name'] == 'runtime.status' and e['payload'].get('status') == 'unavailable' for e in self.core.events), 'A refresh probe must not disconnect the active chat')
        op, _ = self.turn('request-tool')
        while not any(e['name'] == 'approval.requested' for e in self.core.events): self.core.receive()
        approval = next(e['payload']['approvalId'] for e in self.core.events if e['name'] == 'approval.requested')
        self.assertFalse(Path(server.output_file).exists())
        self.core.request('approval.resolve', dict(self.identity, approvalId=approval, optionId='allow_once'))
        self.assertIn('TOOL_DONE', self.reply(op))
        self.assertEqual(Path(server.output_file).read_text(), 'synthetic tool output')
        saved = self.identity['sessionId']
        self.core.close()
        self.assertEqual(self.connect('claude', saved)['sessionId'], saved)
        op, _ = self.turn('recall-marker')
        self.assertEqual(self.reply(op), 'REMEMBERED')
        self.core.close()
        server.output_file = str(self.workspace / 'full-access.txt')
        self.connect('claude', full_access=True)
        op, _ = self.turn('request-tool')
        self.assertIn('TOOL_DONE', self.reply(op))
        self.assertEqual(Path(server.output_file).read_text(), 'synthetic tool output')
        self.assertFalse(any(e['name'] == 'approval.requested' for e in self.core.events))



if __name__ == '__main__':
    unittest.main(verbosity=2)
