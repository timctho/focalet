#!/usr/bin/env python3
"""Stateful Pi/Hermes/OpenClaw protocol fixture with persistent edit history."""
import copy
import json
import os
from pathlib import Path
import sys

import fake_gateway_runtime as gateway

MODE = sys.argv[sys.argv.index('--mode') + 1]
PATH = Path(os.environ['FOCALET_FAKE_REWIND_STORE'])
LOG = os.environ.get('FOCALET_FAKE_REQUEST_LOG')
SOURCE = {'pi': 'pi-session-a', 'hermes': 'hermes-stored-session', 'openclaw': 'agent:main:focalet-rust'}[MODE]
if PATH.exists():
    state = json.loads(PATH.read_text())
else:
    state = {'sequence': 10, 'sessions': {SOURCE: [
        {'id': f'u{i}', 'text': f'Question {i}'} for i in range(3)
    ]}, 'files': {'/sessions/a.jsonl': SOURCE}}
selected = SOURCE
active = ''


def save():
    PATH.write_text(json.dumps(state))


def log(value):
    if LOG:
        with open(LOG, 'a') as stream:
            stream.write(json.dumps(value) + '\n')


def messages():
    values = []
    for turn in state['sessions'][selected]:
        for role, prefix, text in [('user', '', turn['text']), ('assistant', 'a-', 'Reply to ' + turn['text'])]:
            identity = prefix + turn['id']
            if MODE == 'hermes':
                values.append({'row_id': identity, 'role': role, 'text': text})
            else:
                item = {'role': role, 'content': [{'type': 'text', 'text': text}]}
                if MODE == 'openclaw':
                    item['__openclaw'] = {'id': identity}
                values.append(item)
    return values


def append(text):
    global active
    log({'modelContext': [turn['text'] for turn in state['sessions'][selected]], 'replacement': text})
    state['sequence'] += 1
    active = f'run-{state["sequence"]}'
    state['sessions'][selected].append({'id': f'u{state["sequence"]}', 'text': text})
    save()


def mutate(entry=None, count=None, fork=False):
    global selected
    if os.environ.get('FOCALET_FAKE_REWIND_FAIL') == '1':
        raise ValueError('Fixture rejects rewind')
    turns = state['sessions'][selected]
    index = len(turns) - count if count is not None else next(i for i, turn in enumerate(turns) if turn['id'] == entry)
    text = turns[index]['text']
    if fork:
        state['sequence'] += 1
        selected = f'pi-fork-{state["sequence"]}'
        state['files'][f'/sessions/{selected}.jsonl'] = selected
    state['sessions'][selected] = copy.deepcopy(turns[:index])
    save()
    return text


def pi():
    global selected, active
    def send(value):
        print(json.dumps(value), flush=True)
    for line in sys.stdin:
        request = json.loads(line)
        log(request)
        kind = request['type']
        data = {}
        try:
            if kind == 'get_state':
                data = {'sessionId': selected, 'sessionFile': next(file for file, session in state['files'].items() if session == selected),
                        'model': {'provider': 'test', 'id': 'fixture'}, 'isStreaming': bool(active), 'pendingMessageCount': 0}
            elif kind == 'get_available_models':
                data = {'models': [{'provider': 'test', 'id': 'fixture', 'name': 'Fixture'}]}
            elif kind == 'get_commands':
                data = {'commands': []}
            elif kind == 'get_messages':
                data = {'messages': messages()}
            elif kind == 'get_fork_messages':
                data = {'messages': [{'entryId': turn['id'], 'text': turn['text']} for turn in state['sessions'][selected]]}
            elif kind == 'fork':
                data = {'cancelled': False, 'text': mutate(entry=request['entryId'], fork=True)}
            elif kind == 'switch_session':
                selected = state['files'][request['sessionPath']]
                data = {'cancelled': False}
            elif kind == 'prompt':
                append(request['message'])
            elif kind == 'abort':
                active = ''
            send({'type': 'response', 'id': request['id'], 'success': True, 'data': data})
            if kind == 'abort' or (kind == 'prompt' and 'hold-for-interrupt' not in request['message']):
                active = ''
                send({'type': 'agent_end'})
        except (ValueError, KeyError, StopIteration) as error:
            send({'type': 'response', 'id': request['id'], 'success': False, 'error': str(error)})


def serve(connection):
    global selected, active
    if MODE == 'openclaw':
        gateway.openclaw_event(connection, 'connect.challenge', {'nonce': 'rewind-fixture', 'ts': 1800000000000}, 0)
    while True:
        request = gateway.read_ws(connection)
        if request is None:
            return
        gateway.write_log(request)
        method, params = request['method'], request.get('params', {})
        result = {'ok': True}
        try:
            if method == 'connect':
                result = {'type': 'hello-ok', 'protocol': 4, 'server': {'version': 'fixture'},
                          'features': {'methods': gateway.OPENCLAW_METHODS + ['sessions.rewind']},
                          'auth': {'scopes': ['operator.read', 'operator.write', 'operator.admin']}}
            elif method == 'sessions.list':
                result = {'sessions': [{'key': selected, 'derivedTitle': 'Rewind fixture', 'model': 'fixture', 'modelProvider': 'test'}]}
            elif method == 'sessions.create':
                result = {'key': selected}
            elif method in ('session.create', 'session.resume'):
                result = {'session_id': 'native-hermes', 'session_key': SOURCE, 'stored_session_id': SOURCE,
                          'resumed': SOURCE, 'messages': messages(), 'info': {'model': 'fixture', 'provider': 'test'}}
            elif method in ('session.history', 'chat.history'):
                result = {'messages': messages(), 'hasMore': False, 'sessionInfo': {'hasActiveRun': bool(active)}}
            elif method == 'model.options':
                result = {'providers': [{'slug': 'test', 'models': [{'id': 'fixture', 'name': 'Fixture'}]}]}
            elif method == 'models.list':
                result = {'models': [{'provider': 'test', 'id': 'fixture', 'name': 'Fixture'}]}
            elif method == 'commands.catalog':
                result = {'pairs': [['/undo', 'Undo turns']], 'terminal': []}
            elif method == 'commands.list':
                result = {'commands': []}
            elif method == 'slash.exec':
                result = {'type': 'prefill', 'message': mutate(count=int(params['command'].split()[1]))}
            elif method == 'sessions.rewind':
                result = {'editorText': mutate(entry=params['entryId'])}
            elif method in ('prompt.submit', 'chat.send'):
                append(params.get('text', params.get('message', '')))
                result = {'status': 'streaming' if MODE == 'hermes' else 'started', 'runId': active}
            elif method in ('session.interrupt', 'chat.abort'):
                result = {'ok': True, 'aborted': True}
            if MODE == 'hermes':
                gateway.send_ws(connection, {'jsonrpc': '2.0', 'id': request['id'], 'result': result})
            else:
                gateway.send_ws(connection, {'type': 'res', 'id': request['id'], 'ok': True, 'payload': result})
            if method in ('session.interrupt', 'chat.abort') or (method in ('prompt.submit', 'chat.send') and 'hold-for-interrupt' not in params.get('text', params.get('message', ''))):
                if MODE == 'hermes':
                    gateway.hermes_event(connection, 'message.complete', 'native-hermes', {'status': 'completed', 'text': 'Replacement reply'})
                else:
                    gateway.openclaw_event(connection, 'chat', {'state': 'final', 'sessionKey': selected, 'runId': active,
                        'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': 'Replacement reply'}]}}, state['sequence'])
                active = ''
        except (ValueError, KeyError, StopIteration) as error:
            if MODE == 'hermes':
                gateway.send_ws(connection, {'jsonrpc': '2.0', 'id': request['id'], 'error': {'code': -32000, 'message': str(error)}})
            else:
                gateway.send_ws(connection, {'type': 'res', 'id': request['id'], 'ok': False, 'error': {'code': 'INVALID_REQUEST', 'message': str(error)}})


save()
if MODE == 'pi':
    pi()
else:
    gateway.serve_hermes = serve
    gateway.serve_openclaw = serve
    gateway.main()
