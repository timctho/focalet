import assert from 'node:assert/strict';
import { EventEmitter, once } from 'node:events';
import { PassThrough } from 'node:stream';
import test from 'node:test';
import { PortableCodexBridge, buildSessionName, buildTurnText, compactAccessibilityTree } from '../codex-bridge.mjs';

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
  assert.match(context, /PRIMARY SELECTION/);
  assert.match(context, /"role": "Table"/);
  assert.match(context, /"row": 1/);
  assert.doesNotMatch(context, /windows-uia-control-view/);
  assert.doesNotMatch(context, /nodeCount/);
  assert.doesNotMatch(context, /Snapshot confidence|confidence medium|Safety:/i);
  assert.doesNotMatch(context, /flat fallback must not duplicate/);
  assert.doesNotMatch(context, /\|\s*Accounts\s*\|/);
  assert.doesNotMatch(context, /image regions attached/i);
});

test('accessibility payload keeps semantic structure while dropping capture metadata', () => {
  const compact = compactAccessibilityTree({
    source: 'windows-uia-control-view', nodeCount: 9, truncated: true,
    roots: [{
      role: 'Table', name: 'Accounts', value: 'Accounts', automationId: 'grid-42',
      bounds: '1,2,300,400', isOffscreen: false, rowCount: 2, columnCount: 2,
      children: [{ role: 'DataItem', name: 'example', row: 1, column: 0, rowSpan: 1 }],
    }],
  });
  assert.deepEqual(compact, {
    roots: [{
      role: 'Table', name: 'Accounts', rowCount: 2, columnCount: 2,
      children: [{ role: 'DataItem', name: 'example', row: 1, column: 0 }],
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
  await bridge.startTurn('keep working');
  const completion = once(bridge, 'turnCompleted');
  const interrupted = await bridge.interruptTurn();
  stdout.write(`${JSON.stringify({ method: 'turn/completed', params: { threadId: 'thread-zommi', turn: { id: 'turn-zommi', status: 'interrupted' } } })}\n`);
  assert.deepEqual(interrupted, { interrupted: true, threadId: 'thread-zommi', turnId: 'turn-zommi' });
  assert.deepEqual((await completion)[0], { threadId: 'thread-zommi', status: 'interrupted' });
  assert.deepEqual(
    requests.find((request) => request.method === 'turn/interrupt')?.params,
    { threadId: 'thread-zommi', turnId: 'turn-zommi' },
  );
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
