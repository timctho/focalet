"""Claude stream-json protocol fixture: conversations, controls and failure modes."""
import json
import os
from pathlib import Path
import sys
import time
import uuid

args = sys.argv[1:]
session = args[args.index('--resume') + 1] if '--resume' in args else args[args.index('--session-id') + 1]
if log := os.environ.get('FOCALET_FAKE_REQUEST_LOG'):
    with open(log, 'a', encoding='utf-8') as out:
        out.write(json.dumps({'type':'fixture_launch', 'launchArgs':args, 'sessionId':session}) + '\n')
startup_error = os.environ.get('FOCALET_FAKE_CLAUDE_STARTUP_ERROR')
partial_mode = os.environ.get('FOCALET_FAKE_CLAUDE_REJECT_PARTIAL')
reject_partial = partial_mode == '1' or bool(partial_mode and Path(partial_mode).exists())
if reject_partial and '--include-partial-messages' in args:
    startup_error = "error: unknown option '--include-partial-messages'"
if startup_error:
    # A process may close stdout before its useful diagnostic reaches stderr.
    os.close(sys.stdout.fileno())
    time.sleep(.1)
    print(startup_error, file=sys.stderr, flush=True)
    sys.exit(1)
store = Path(os.environ['FOCALET_FAKE_CLAUDE_STORE'])
store.mkdir(exist_ok=True)
file = store / (session + '.json')
history = json.loads(file.read_text()) if file.exists() else []
pending = None
model = 'fixture-a'

def emit(value):
    print(json.dumps(value), flush=True)

def finish(text='CLAUDE_OK', *, error=False):
    identity = str(uuid.uuid4())
    if not reject_partial:
        emit({'type': 'stream_event', 'session_id': session, 'event': {'type': 'message_start', 'message': {'id': identity}}})
        emit({'type': 'stream_event', 'session_id': session, 'event': {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': text}}})
    emit({'type': 'assistant', 'session_id': session, 'message': {'id': identity, 'content': [{'type': 'text', 'text': text}]}})
    emit({'type': 'result', 'session_id': session, 'subtype': 'error_during_execution' if error else 'success', 'is_error': error, 'result': text, 'errors': ['fixture API failure'] if error else []})

for line in sys.stdin:
    value = json.loads(line)
    if log := os.environ.get('FOCALET_FAKE_REQUEST_LOG'):
        with open(log, 'a', encoding='utf-8') as out:
            out.write(json.dumps(value) + '\n')
    if value['type'] == 'control_request':
        request = value['request']
        response = {}
        if request['subtype'] == 'initialize':
            if (store / 'stall-startup').exists():
                continue
            if os.environ.get('FOCALET_FAKE_CLAUDE_AUTH') == 'missing':
                emit({'type': 'control_response', 'response': {'subtype': 'error', 'request_id': value['request_id'], 'error': 'Not logged in; API key required'}})
                continue
            response = {'models': [{'value': id, 'displayName': id} for id in ['fixture-a', 'fixture-b']], 'commands': [{'name': 'inspect', 'description': 'Inspect selection'}]}
        elif request['subtype'] == 'set_model':
            model = request['model']
        emit({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': value['request_id'], 'response': response}})
        if request['subtype'] == 'interrupt':
            emit({'type': 'control_cancel_request', 'request_id': 'approval'})
            finish('INTERRUPTED')
    elif value['type'] == 'control_response':
        finish('ALLOWED' if value['response']['response']['behavior'] == 'allow' else 'DENIED')
    elif value['type'] == 'user':
        assert value['session_id'] == session
        text = value['message']['content'][0]['text']
        emit({'type': 'system', 'subtype': 'init', 'session_id': session, 'model': model})
        history.append(text)
        file.write_text(json.dumps(history))
        if 'crash-now' in text:
            sys.exit(7)
        if 'malformed-now' in text:
            print('not json', flush=True)
            continue
        if 'wrong-session' in text:
            emit({'type': 'result', 'session_id': str(uuid.uuid4()), 'subtype': 'success'})
            continue
        if 'wait-now' in text:
            continue
        if 'approve-now' in text:
            emit({'type': 'control_request', 'request_id': 'approval', 'request': {'subtype': 'can_use_tool', 'tool_name': 'Write', 'input': {'file_path': 'fixture.txt', 'content': 'fixture'}}})
        else:
            finish('REMEMBERED:' + history[0] if 'recall-now' in text else 'CLAUDE_OK', error='fail-now' in text)
