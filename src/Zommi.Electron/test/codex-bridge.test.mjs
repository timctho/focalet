import assert from 'node:assert/strict';
import { EventEmitter, once } from 'node:events';
import { PassThrough } from 'node:stream';
import test from 'node:test';
import {
  CodexAppServerAdapter,
  PortableCodexBridge,
  buildSessionName,
  buildTurnText,
  codexLaunchArgs,
  codexRuntimeVersion,
  compactAccessibilityTree,
  parseStreamUpdate,
} from '../codex-bridge.mjs';
import { assertAcceptedTurnBecomesUnknownOnRuntimeExit, assertSafeUnknownNativeDiagnostic, installPendingRequestExitProbe } from './adapter-conformance.mjs';

test('WSL Codex launch injects the non-IDE compatibility originator inside Linux', () => {
  assert.deepEqual(codexLaunchArgs('wsl.exe', [
    '-d', 'Ubuntu', '--cd', '/home/u', '-e', '/home/u/bin/codex', 'app-server',
  ]), [
    '-d', 'Ubuntu', '--cd', '/home/u', '-e',
    'env', 'CODEX_INTERNAL_ORIGINATOR_OVERRIDE=codex_exec',
    '/home/u/bin/codex', 'app-server',
  ]);
  assert.deepEqual(codexLaunchArgs('/home/u/bin/codex', ['app-server']), ['app-server']);
});

test('Codex adapter records protocol readiness only after initialize and extracts the real CLI version', () => {
  const adapter = new CodexAppServerAdapter();
  assert.equal(adapter.protocolVersion, null);
  assert.equal(codexRuntimeVersion({
    userAgent: 'zommi/0.149.0 (Windows 10; x86_64) terminal (zommi; 0.2.0)',
  }), '0.149.0');
  adapter.stop();
});

test('structured browser context remains nested JSON without inferred markdown', () => {
  const context = buildTurnText('what is this?', [{
    observedAtUtc: '2026-08-25T00:00:00Z',
    surfaceKind: 'Browser',
    application: 'Edge',
    windowTitle: 'Usage',
    locator: { kind: 'URL', value: 'https://example.test/report' },
    selection: ['SELECTED_TEXT_IS_PRIMARY'],
    visibleText: ['flat fallback must not duplicate'],
    accessibilityTree: {
      source: 'windows-uia-control-view', nodeCount: 2, truncated: false,
      roots: [{ role: 'Table', name: 'Accounts', children: [{ role: 'DataItem', name: 'example', row: 1, column: 0 }] }],
    },
  }]);
  assert.match(context, /PRIMARY SURFACE SELECTION/);
  assert.match(context, /"role": "Table"/);
  assert.match(context, /"row": 1/);
  assert.doesNotMatch(context, /windows-uia-control-view/);
  assert.doesNotMatch(context, /nodeCount/);
  assert.doesNotMatch(context, /Snapshot confidence|confidence medium|Safety:/i);
  assert.doesNotMatch(context, /flat fallback must not duplicate/);
  assert.doesNotMatch(context, /\|\s*Accounts\s*\|/);
  assert.doesNotMatch(context, /image regions attached/i);
});

test('structured surface selection precedes pointer fallback and keeps shape or range anchors', () => {
  const context = buildTurnText('redesign these', [{
    observedAtUtc: '2026-08-25T00:00:00Z', surfaceKind: 'Browser', application: 'Chrome',
    selection: [], selectionElementCount: 7,
    selectionElements: [{
      controlType: 'DataItem', name: 'Revenue', value: '$42', formula: '=SUM(B2:B8)',
      bounds: '100,200,300,80', row: 1, column: 2,
    }],
    indicatedTarget: { controlType: 'Document', name: 'Google Sheets', bounds: '0,80,1200,800' },
  }]);
  assert.match(context, /showing 1 of 7/);
  assert.match(context, /"formula": "=SUM\(B2:B8\)"/);
  assert.match(context, /"box": "100,200,300,80"/);
  assert.ok(context.indexOf('Revenue') < context.indexOf('Mouse pointer:'));
});

test('accessibility payload keeps semantic structure while dropping capture metadata', () => {
  const compact = compactAccessibilityTree({
    source: 'windows-uia-control-view', nodeCount: 9, truncated: true,
    roots: [{
      role: 'Table', name: 'Accounts', value: 'Accounts', automationId: 'grid-42',
      bounds: '1,2,300,400', isOffscreen: false, rowCount: 2, columnCount: 2,
      children: [{ role: 'DataItem', name: 'example', isSelected: true, row: 1, column: 0, rowSpan: 1 }],
    }],
  });
  assert.deepEqual(compact, {
    roots: [{
      role: 'Table', name: 'Accounts', rowCount: 2, columnCount: 2,
      children: [{ role: 'DataItem', name: 'example', selected: true, row: 1, column: 0 }],
    }],
    truncated: true,
  });
});

test('accessibility payload flattens empty layout wrappers without losing their semantic children', () => {
  const compact = compactAccessibilityTree({
    roots: [{ role: 'Document', children: [{ role: 'Group', children: [{ role: 'Text', name: 'Necessary label' }] }] }],
  });
  assert.deepEqual(compact, {
    roots: [{ role: 'Document', children: [{ role: 'Text', name: 'Necessary label' }] }],
  });
});

test('image note appears only for explicit selected images', () => {
  const withoutImage = buildTurnText('hello', [], 0);
  assert.equal(withoutImage, 'hello');
  const withImage = buildTurnText('hello', [], 1);
  assert.match(withImage, /User-selected image regions attached: 1/);
});

test('completed image generation and HTML file changes retain structured preview artifacts', () => {
  const image = parseStreamUpdate('item/completed', { item: {
    id: 'generated-1', type: 'imageGeneration', status: 'completed', result: 'aGVsbG8=',
    savedPath: '/workspace/render.png', failure: null,
  } }, new Map(), { cwd: '/workspace' });
  const html = parseStreamUpdate('item/completed', { item: {
    id: 'change-1', type: 'fileChange', status: 'completed', changes: [{ kind: 'add', path: 'preview.html' }],
  } }, new Map(), { cwd: '/workspace' });
  assert.equal(image.artifacts[0].dataUrl, 'data:image/png;base64,aGVsbG8=');
  assert.equal(html.artifacts[0].path, 'preview.html');
  assert.equal(html.artifacts[0].cwd, '/workspace');
});

test('Zommi sessions receive a bounded persistent name', () => {
  const name = buildSessionName('  Compare   these two long documents and preserve every relevant structural difference in the answer  ');
  assert.match(name, /^Zommi · Compare these two long documents/);
  assert.ok(name.length <= 63);
});

test('active turns are interrupted with the exact app-server thread and turn ids', async () => {
  const requests = [];
  const stdout = new PassThrough();
  const stderr = new PassThrough();
  const child = Object.assign(new EventEmitter(), {
    stdout,
    stderr,
    killed: false,
    kill() { this.killed = true; },
  });
  child.stdin = {
    write(line) {
      const message = JSON.parse(line);
      if (!message.id) return true;
      requests.push(message);
      let result = {};
      if (message.method === 'model/list') result = { data: [] };
      if (message.method === 'thread/list') result = { data: [] };
      if (message.method === 'thread/start' && !message.params.input) result = { thread: { id: 'thread-zommi', turns: [] } };
      if (message.method === 'turn/start') result = { turn: { id: 'turn-zommi' } };
      queueMicrotask(() => stdout.write(`${JSON.stringify({ id: message.id, result })}\n`));
      return true;
    },
  };
  const bridge = new PortableCodexBridge({ spawnProcess: () => child, cwd: '/tmp/zommi-test' });
  await bridge.startTurn('keep working', [], [], { clientOperationId: 'client:codex-interrupt' });
  const completion = once(bridge, 'turnCompleted');
  const interrupted = await bridge.interruptTurn();
  stdout.write(`${JSON.stringify({ method: 'turn/completed', params: { threadId: 'thread-zommi', turn: { id: 'turn-zommi', status: 'interrupted' } } })}\n`);
  assert.deepEqual(interrupted, { interrupted: true, threadId: 'thread-zommi', turnId: 'turn-zommi' });
  assert.deepEqual((await completion)[0], {
    threadId: 'thread-zommi', turnId: 'turn-zommi',
    clientOperationId: 'client:codex-interrupt', status: 'interrupted',
  });
  assert.deepEqual(
    requests.find((request) => request.method === 'turn/interrupt')?.params,
    { threadId: 'thread-zommi', turnId: 'turn-zommi' },
  );
  bridge.stop();
});

test('completed Codex agent messages recover missing deltas without duplicating streamed text', async () => {
  const stdout = new PassThrough();
  const stderr = new PassThrough();
  const child = Object.assign(new EventEmitter(), {
    stdout,
    stderr,
    killed: false,
    kill() { this.killed = true; },
  });
  child.stdin = {
    write(line) {
      const message = JSON.parse(line);
      if (!message.id) return true;
      let result = {};
      if (message.method === 'model/list') result = { data: [] };
      if (message.method === 'thread/list') result = { data: [] };
      if (message.method === 'thread/start') result = { thread: { id: 'thread-completed', turns: [] } };
      if (message.method === 'turn/start') result = { turn: { id: 'turn-completed' } };
      queueMicrotask(() => stdout.write(`${JSON.stringify({ id: message.id, result })}\n`));
      return true;
    },
  };

  const bridge = new PortableCodexBridge({ spawnProcess: () => child, cwd: '/tmp/zommi-test' });
  await bridge.startTurn('reply exactly', [], [], { clientOperationId: 'client:codex-completed' });
  stdout.write(`${JSON.stringify({ method: 'item/started', params: {
    threadId: 'thread-completed',
    item: { id: 'agent-completed', type: 'agentMessage', phase: 'final' },
  } })}\n`);
  const streamed = once(bridge, 'streamUpdate');
  stdout.write(`${JSON.stringify({ method: 'item/completed', params: {
    threadId: 'thread-completed',
    item: { id: 'agent-completed', type: 'agentMessage', phase: 'final', text: 'AUTHORITATIVE_FINAL' },
  } })}\n`);
  assert.deepEqual((await streamed)[0], {
    kind: 'assistant',
    lifecycle: 'completed',
    title: 'Codex',
    text: 'AUTHORITATIVE_FINAL',
    itemId: 'agent-completed',
    status: null,
    replace: true,
    threadId: 'thread-completed',
    turnId: 'turn-completed',
    clientOperationId: 'client:codex-completed',
  });
  bridge.stop();
});

test('running turns remain routed to their session while another session is active', async () => {
  const requests = [];
  const stdout = new PassThrough();
  const stderr = new PassThrough();
  let startedThreads = 0;
  const child = Object.assign(new EventEmitter(), {
    stdout,
    stderr,
    killed: false,
    kill() { this.killed = true; },
  });
  child.stdin = {
    write(line) {
      const message = JSON.parse(line);
      if (!message.id) return true;
      requests.push(message);
      let result = {};
      if (message.method === 'model/list') result = { data: [] };
      if (message.method === 'thread/list') result = { data: [] };
      if (message.method === 'thread/start') {
        startedThreads += 1;
        result = { thread: { id: `thread-${startedThreads === 1 ? 'a' : 'b'}`, turns: [] } };
      }
      if (message.method === 'turn/start') result = { turn: { id: 'turn-a' } };
      if (message.method === 'thread/read' || message.method === 'thread/resume') {
        result = { thread: { id: message.params.threadId, turns: [] } };
      }
      queueMicrotask(() => stdout.write(`${JSON.stringify({ id: message.id, result })}\n`));
      return true;
    },
  };

  const bridge = new PortableCodexBridge({ spawnProcess: () => child, cwd: '/tmp/zommi-test' });
  await bridge.startTurn('run in the background');
  const secondSessionState = await bridge.createSession();
  assert.equal(secondSessionState.activeThreadId, 'thread-b');
  assert.deepEqual(secondSessionState.activeTurns, [{ threadId: 'thread-a', turnId: 'turn-a' }]);

  stdout.write(`${JSON.stringify({ method: 'item/started', params: { threadId: 'thread-a', item: { id: 'agent-a', type: 'agentMessage', phase: 'final' } } })}\n`);
  const streamed = once(bridge, 'streamUpdate');
  stdout.write(`${JSON.stringify({ method: 'item/agentMessage/delta', params: { threadId: 'thread-a', itemId: 'agent-a', delta: 'background output' } })}\n`);
  assert.equal((await streamed)[0].threadId, 'thread-a');

  await bridge.switchSession('thread-a');
  assert.ok(requests.some((request) => request.method === 'thread/read' && request.params.threadId === 'thread-a'));
  bridge.stop();
});

test('startup resumes only the exact bound session and creates fresh when it has another writer', async () => {
  const stdout = new PassThrough();
  const stderr = new PassThrough();
  const requests = [];
  const child = Object.assign(new EventEmitter(), {
    stdout, stderr, killed: false,
    kill() { this.killed = true; },
  });
  child.stdin = {
    write(line) {
      const message = JSON.parse(line);
      if (!message.id) return true;
      requests.push(message);
      let result = {};
      let error = null;
      if (message.method === 'model/list') result = { data: [] };
      if (message.method === 'thread/list') {
        result = { data: [{ id: 'busy-thread', threadSource: 'zommi', name: 'Zommi · busy' }] };
      }
      if (message.method === 'thread/resume') {
        error = { code: -32600, message: 'thread busy-thread already has an active writer' };
      }
      if (message.method === 'thread/start') result = { thread: { id: 'fresh-thread', turns: [] } };
      queueMicrotask(() => stdout.write(`${JSON.stringify(error
        ? { id: message.id, error }
        : { id: message.id, result })}\n`));
      return true;
    },
  };
  const bridge = new PortableCodexBridge({
    spawnProcess: () => child,
    cwd: '/tmp/zommi-test',
    preferredSessionId: 'busy-thread',
  });
  await bridge.ensureStarted();
  assert.equal(bridge.threadId, 'fresh-thread');
  assert.ok(requests.some((request) => request.method === 'thread/resume'));
  assert.ok(requests.some((request) => request.method === 'thread/start'));
  bridge.stop();
});

test('slow Chrome MCP startup does not block the first thread and turn', async () => {
  const stdout = new PassThrough();
  const stderr = new PassThrough();
  const requests = [];
  let statusRequest;
  const child = Object.assign(new EventEmitter(), {
    stdout, stderr, killed: false,
    kill() { this.killed = true; },
  });
  child.stdin = {
    write(line) {
      const message = JSON.parse(line);
      if (!message.id) return true;
      requests.push(message);
      if (message.method === 'mcpServerStatus/list') {
        statusRequest = message;
        return true;
      }
      let result = {};
      if (message.method === 'model/list') result = { data: [] };
      if (message.method === 'thread/list') result = { data: [] };
      if (message.method === 'thread/start') result = { thread: { id: 'chrome-thread', turns: [] } };
      if (message.method === 'turn/start') result = { turn: { id: 'chrome-turn' } };
      queueMicrotask(() => stdout.write(`${JSON.stringify({ id: message.id, result })}\n`));
      return true;
    },
  };
  const bridge = new PortableCodexBridge({ spawnProcess: () => child, cwd: '/tmp/zommi-test' });
  const turnPromise = bridge.startTurn(
    'inspect this sheet', [], [], { clientOperationId: 'client:codex-slow-mcp' },
  );
  while (!statusRequest) await new Promise((resolve) => setImmediate(resolve));

  assert.deepEqual(await turnPromise, {
    accepted: true,
    threadId: 'chrome-thread',
    turnId: 'chrome-turn',
    clientOperationId: 'client:codex-slow-mcp',
  });
  assert.ok(requests.findIndex((request) => request.method === 'mcpServerStatus/list') <
    requests.findIndex((request) => request.method === 'thread/start'));
  assert.ok(requests.findIndex((request) => request.method === 'thread/start') <
    requests.findIndex((request) => request.method === 'turn/start'));
  assert.equal(requests.some((request) => request.method === 'config/mcpServer/reload'), false);

  const chromeReady = once(bridge, 'status');
  stdout.write(`${JSON.stringify({
    id: statusRequest.id,
    result: {
      data: [{
        name: 'chrome',
        serverInfo: { name: 'chrome_devtools', version: '1.8.0' },
        tools: { list_pages: { name: 'list_pages' }, click: { name: 'click' } },
      }],
    },
  })}\n`);
  assert.deepEqual(await chromeReady, ['Chrome control ready · v1.8.0']);
  bridge.stop();
});

test('Codex conformance reports an accepted turn as unknown when app-server exits', async () => {
  const stdout = new PassThrough();
  const stderr = new PassThrough();
  const child = Object.assign(new EventEmitter(), {
    stdout, stderr, killed: false,
    kill() { this.killed = true; },
  });
  child.stdin = {
    write(line) {
      const message = JSON.parse(line);
      if (!message.id) return true;
      let result = {};
      if (message.method === 'model/list' || message.method === 'thread/list') result = { data: [] };
      if (message.method === 'thread/start') result = { thread: { id: 'thread-exit', turns: [] } };
      if (message.method === 'turn/start') result = { turn: { id: 'turn-exit' } };
      queueMicrotask(() => stdout.write(`${JSON.stringify({ id: message.id, result })}\n`));
      return true;
    },
  };
  const adapter = new PortableCodexBridge({ spawnProcess: () => child, cwd: '/tmp/zommi-test' });
  const pendingRequest = installPendingRequestExitProbe(adapter);
  await assertAcceptedTurnBecomesUnknownOnRuntimeExit({
    adapter,
    operationId: 'client:codex-exit',
    forbiddenDiagnostics: ['codex-adapter-secret', 'captured private Codex context'],
    exitRuntime: () => {
      stdout.write(`${JSON.stringify({ method: 'future/codex-event', params: { threadId: 'thread-exit', token: 'native-codex-secret', text: 'private codex payload' } })}\n`);
      stderr.write('token=codex-adapter-secret <zommi_invocation_context>captured private Codex context</zommi_invocation_context>');
      child.emit('exit', 26);
    },
  });
  assertSafeUnknownNativeDiagnostic(adapter, {
    eventName: 'future/codex-event', forbidden: ['native-codex-secret', 'private codex payload'],
  });
  await assert.rejects(pendingRequest, /exited/);
  adapter.stop();
});
