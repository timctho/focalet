#!/usr/bin/env python3
"""Compare same/cross-runtime protocol latency using isolated Codex/Hermes fixtures.

--flow before reproduces the previous controller's connect + open + read path.
No prompts or user history are used. This does not measure UI frame latency.
"""
import argparse
import asyncio
from collections import Counter
import json
import os
from pathlib import Path
import statistics
import sys
import tempfile
import time


async def measure(args):
    fixtures = Path(__file__).resolve().parent.parent / 'crates/focalet-core-host/tests'
    with tempfile.TemporaryDirectory(prefix='focalet-runtime-switch-') as directory:
        root = Path(directory)
        log = root / 'requests.jsonl'
        process = await asyncio.create_subprocess_exec(
            str(Path(args.core_host).resolve()), stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            limit=64 * 1024 * 1024,
            env={**os.environ,
                 'FOCALET_CODEX_COMMAND': sys.executable,
                 'FOCALET_CODEX_ARGS_JSON': json.dumps([str(fixtures / 'fake_codex_app_server.py')]),
                 'FOCALET_HERMES_COMMAND': sys.executable,
                 'FOCALET_HERMES_GATEWAY_ARGS_JSON': json.dumps([str(fixtures / 'fake_gateway_runtime.py'), '--mode', 'hermes']),
                 'FOCALET_CORE_STATE_PATH': str(root / 'binding.json'),
                 'FOCALET_RUNTIME_OVERRIDES_PATH': str(root / 'overrides.json'),
                 'FOCALET_RUNTIME_DISCOVERY_CACHE_PATH': str(root / 'discovery.json'),
                 'FOCALET_FAKE_REQUEST_LOG': str(log),
                 'FOCALET_FAKE_HISTORY_COUNT': '3',
                 'FOCALET_FAKE_CATALOG_DELAY': str(args.catalog_delay_ms / 1000),
                 'FOCALET_FAKE_REQUEST_DELAY_MS': str(args.delay_ms)})
        sequence = 0
        async def request(operation, payload=None):
            nonlocal sequence
            sequence += 1
            identity = str(sequence)
            process.stdin.write((json.dumps({'id': identity, 'protocolVersion': 1,
                'operation': operation, 'payload': payload or {}}) + '\n').encode())
            await process.stdin.drain()
            while True:
                line = await asyncio.wait_for(process.stdout.readline(), 90)
                if not line:
                    raise RuntimeError('Core exited')
                response = json.loads(line)
                if response.get('id') != identity:
                    continue
                if not response['ok']:
                    raise RuntimeError(response['error'])
                return response['result']
        try:
            await request('core.initialize')
            discovery = await request('runtime.discover')
            targets = {t['adapterId']: t['id'] for t in discovery['targets']
                       if t['executablePath'] == sys.executable and t['executionHost']['kind'] == 'native'}
            codex, hermes = targets['codex-app-server'], targets['hermes-gateway']
            for target, session in [(codex, 'benchmark-chat'), (hermes, 'hermes-stored-session')]:
                await request('runtime.connect', {'runtimeTargetId': target, 'preferredSessionId': session})
            # Warm each profile's model and command catalogs before steady-state samples.
            for session in ['hermes-coder-session', 'hermes-stored-session']:
                await request('session.open', {'runtimeTargetId': hermes, 'sessionId': session})
            output = {'flow': args.flow, 'fixture': {'request_delay_ms': args.delay_ms,
                'catalog_delay_ms': args.catalog_delay_ms, 'switches_per_case': args.switches}}
            for scenario in ['same_runtime', 'cross_runtime']:
                samples = []
                start_log = len(log.read_text().splitlines())
                for index in range(args.switches):
                    target = codex if scenario == 'cross_runtime' and index % 2 == 0 else hermes
                    session = 'benchmark-chat' if target == codex else ('hermes-coder-session' if index % 2 == 0 else 'hermes-stored-session')
                    payload = {'runtimeTargetId': target, 'sessionId': session}
                    started = time.perf_counter()
                    before = sequence
                    if args.flow == 'before' and scenario == 'cross_runtime':
                        await request('runtime.connect', {'runtimeTargetId': target, 'preferredSessionId': session})
                    connection = await request('session.open', payload)
                    history = connection.get('history')
                    if history is None:
                        history = await request('session.read', payload)
                    assert connection['sessionId'] == session
                    assert history['thread']['id'] == session
                    samples.append({'ms': round((time.perf_counter() - started) * 1000, 2), 'core_requests': sequence - before})
                methods = Counter(json.loads(line).get('method') for line in log.read_text().splitlines()[start_log:])
                output[scenario] = {'median_ms': statistics.median(s['ms'] for s in samples),
                    'core_requests_per_switch': statistics.median(s['core_requests'] for s in samples),
                    'native_requests': dict(methods), 'samples': samples}
            print(json.dumps(output, indent=2))
            await request('core.shutdown')
            await asyncio.wait_for(process.wait(), 10)
        finally:
            if process.returncode is None:
                process.kill()
                await process.wait()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core-host', default='target/debug/focalet-core-host')
    parser.add_argument('--flow', choices=['before', 'after'], default='after')
    parser.add_argument('--delay-ms', type=float, default=20)
    parser.add_argument('--catalog-delay-ms', type=float, default=100)
    parser.add_argument('--switches', type=int, default=12)
    args = parser.parse_args()
    if args.switches < 2 or min(args.delay_ms, args.catalog_delay_ms) < 0:
        parser.error('Use at least two switches and nonnegative delays')
    asyncio.run(measure(args))
