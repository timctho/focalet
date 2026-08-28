import assert from 'node:assert/strict';
import { EventEmitter, once } from 'node:events';
import { PassThrough } from 'node:stream';
import test from 'node:test';
import {
  OpenClawGatewayAdapter,
  openClawMessagesToTurns,
  openClawModelsForRenderer,
  parseOpenClawGatewayStatus,
} from '../openclaw-gateway-adapter.mjs';
import { assertAcceptedTurnBecomesUnknownOnRuntimeExit, assertSafeUnknownNativeDiagnostic, installPendingRequestExitProbe } from './adapter-conformance.mjs';

test('OpenClaw uses the official v4 Gateway client and resumes only an exact session key', async () => {
  const fixture = openClawFixture({
    sessions: [{ key: 'agent:main:saved', kind: 'direct', derivedTitle: 'Saved', updatedAt: 12 }],
  });
  const adapter = new OpenClawGatewayAdapter({
    GatewayClientClass: fixture.GatewayClientClass,
    preferredSessionId: 'agent:main:saved',
    token: 'runtime-owned-token',
  });
  const state = await adapter.getChatState();
  assert.equal(state.activeThreadId, 'agent:main:saved');
  assert.equal(state.thread.turns[0].items[0].content[0].text, 'saved question');
  assert.equal(fixture.options.minProtocol, 4);
  assert.equal(fixture.options.maxProtocol, 4);
  assert.equal(fixture.options.token, 'runtime-owned-token');
  assert.equal(fixture.options.clientName, 'cli');
  assert.ok(fixture.requests.some((request) => request.method === 'sessions.messages.subscribe'));
  adapter.stop();
});

test('OpenClaw uses official Gateway status and service lifecycle for zero-config activation', async () => {
  const fixture = openClawFixture();
  const calls = [];
  let statusCalls = 0;
  const execFile = async (command, args) => {
    calls.push([command, ...args]);
    if (args.includes('status')) {
      statusCalls += 1;
      return { stdout: JSON.stringify(statusCalls === 1 ? {
        service: { loadState: { status: 'loaded' }, command: { programArguments: ['openclaw', 'gateway'] } },
        rpc: { ok: false, error: 'connection refused', url: 'ws://127.0.0.1:19001' },
      } : {
        service: { loadState: { status: 'loaded' } },
        rpc: { ok: true, url: 'ws://127.0.0.1:19001', server: { version: '2026.8.1' } },
      }) };
    }
    if (args.includes('start')) return { stdout: '{"ok":true}' };
    throw new Error(`unexpected OpenClaw command ${args.join(' ')}`);
  };
  const adapter = new OpenClawGatewayAdapter({
    command: 'openclaw', commandArgs: ['--profile', 'default'], execFile,
    GatewayClientClass: fixture.GatewayClientClass, lifecycleTimeoutMs: 1_000,
  });
  await adapter.ensureStarted();
  assert.ok(calls.some((call) => call.includes('status') && call.includes('--require-rpc')));
  assert.ok(calls.some((call) => call.includes('gateway') && call.includes('start')));
  assert.equal(fixture.options.url, 'ws://127.0.0.1:19001');
  adapter.stop();
});

test('OpenClaw starts an owned foreground Gateway only when no managed service exists', async () => {
  const fixture = openClawFixture();
  const child = Object.assign(new EventEmitter(), {
    stderr: new PassThrough(), killed: false,
    kill() { this.killed = true; },
  });
  let statusCalls = 0;
  let spawned = null;
  const adapter = new OpenClawGatewayAdapter({
    command: 'openclaw',
    execFile: async (_command, args) => {
      if (!args.includes('status')) throw new Error('managed lifecycle must not be used');
      statusCalls += 1;
      return { stdout: JSON.stringify(statusCalls === 1 ? {
        service: { loadState: { status: 'not-loaded' } },
        port: { status: 'free' }, rpc: { ok: false, error: 'connection refused' },
      } : {
        service: { loadState: { status: 'not-loaded' } },
        rpc: { ok: true, url: 'ws://127.0.0.1:18789' },
      }) };
    },
    spawnProcess: (command, args, options) => {
      spawned = { command, args, options };
      return child;
    },
    GatewayClientClass: fixture.GatewayClientClass,
    lifecycleTimeoutMs: 1_000,
  });
  await adapter.ensureStarted();
  assert.deepEqual(spawned.args, ['gateway', 'run']);
  adapter.stop();
  assert.equal(child.killed, true);
});

test('OpenClaw status parser accepts only one JSON object', () => {
  assert.deepEqual(parseOpenClawGatewayStatus('{"rpc":{"ok":true}}'), { rpc: { ok: true } });
  assert.equal(parseOpenClawGatewayStatus('warning\n{"rpc":{"ok":true}}'), null);
  assert.equal(parseOpenClawGatewayStatus('[]'), null);
});

test('OpenClaw sends one idempotent run and maps validated chat stream events', async () => {
  const fixture = openClawFixture();
  const adapter = new OpenClawGatewayAdapter({ GatewayClientClass: fixture.GatewayClientClass });
  await adapter.ensureStarted();
  const accepted = await adapter.startTurn(
    'inspect this', [], ['data:image/png;base64,aGVsbG8='],
    { clientOperationId: 'client:openclaw-run' },
  );
  const send = fixture.requests.find((request) => request.method === 'chat.send');
  assert.equal(accepted.turnId, 'run-1');
  assert.equal(send.params.idempotencyKey, 'client:openclaw-run');
  assert.equal(send.params.attachments[0].sizeBytes, 5);

  const streamed = once(adapter, 'streamUpdate');
  fixture.event('chat', {
    state: 'delta', runId: 'run-1', sessionKey: accepted.threadId, seq: 0,
    deltaText: 'hello', replace: false,
  });
  assert.equal((await streamed)[0].text, 'hello');
  const completed = once(adapter, 'turnCompleted');
  fixture.event('chat', {
    state: 'final', runId: 'run-1', sessionKey: accepted.threadId, seq: 1,
    message: { role: 'assistant', content: [{ type: 'text', text: 'hello' }] },
  });
  assert.deepEqual((await completed)[0], {
    threadId: accepted.threadId, turnId: 'run-1',
    clientOperationId: 'client:openclaw-run', status: 'completed',
  });
  assert.equal(fixture.requests.filter((request) => request.method === 'chat.send').length, 1);
  adapter.stop();
});

test('OpenClaw keeps approval kind and multi-question answers in official protocol shapes', async () => {
  const fixture = openClawFixture();
  const adapter = new OpenClawGatewayAdapter({ GatewayClientClass: fixture.GatewayClientClass });
  await adapter.ensureStarted();
  const approval = once(adapter, 'approvalRequested');
  fixture.event('exec.approval.requested', { id: 'approval-a', sessionKey: fixture.activeKey, presentation: { title: 'Run command' } });
  const approvalRequest = (await approval)[0];
  await adapter.resolveApproval(approvalRequest.approvalId, 'allow-once');
  assert.deepEqual(fixture.requests.find((request) => request.method === 'approval.resolve').params, {
    id: 'approval-a', kind: 'exec', decision: 'allow-once',
  });

  const question = once(adapter, 'questionRequested');
  fixture.event('question.requested', {
    id: 'question-a', sessionKey: fixture.activeKey, createdAtMs: 1, expiresAtMs: 10, status: 'pending',
    questions: [
      { questionId: 'branch', header: 'Branch', question: 'Which branch?', options: [{ label: 'main' }, { label: 'dev' }] },
      { questionId: 'reason', header: 'Reason', question: 'Why?', options: [], isOther: true },
    ],
  });
  const questionRequest = (await question)[0];
  assert.equal(questionRequest.questions.length, 2);
  await adapter.resolveQuestion(questionRequest.questionId, { answers: { branch: ['dev'], reason: ['safer'] } });
  assert.deepEqual(fixture.requests.find((request) => request.method === 'question.resolve').params, {
    id: 'question-a',
    answers: { answers: { branch: ['dev'], reason: ['safer'] } },
    resolvedBy: 'zommi',
  });
  adapter.stop();
});

test('OpenClaw projections retain provider/model identity and transcript roles', () => {
  const models = openClawModelsForRenderer([{ id: 'gpt-test', name: 'GPT Test', provider: 'copilot' }]);
  assert.equal(models[0].id, 'copilot::gpt-test');
  const turns = openClawMessagesToTurns([
    { role: 'user', content: [{ type: 'text', text: 'question' }] },
    { role: 'assistant', content: [{ type: 'text', text: 'answer' }], reasoning: 'thought' },
  ]);
  assert.deepEqual(turns[0].items.map((item) => item.type), ['userMessage', 'reasoning', 'agentMessage']);
});

test('OpenClaw rejects protocol skew and derives optional capabilities from hello', async () => {
  const skewed = openClawFixture({ protocolVersion: 3 });
  const rejected = new OpenClawGatewayAdapter({ GatewayClientClass: skewed.GatewayClientClass });
  await assert.rejects(rejected.ensureStarted(), /Unsupported OpenClaw Gateway protocol version 3/);

  const methods = [
    'sessions.list', 'sessions.create', 'sessions.messages.subscribe', 'sessions.messages.unsubscribe',
    'chat.history', 'chat.send', 'models.list',
  ];
  const downgraded = openClawFixture({ methods });
  const adapter = new OpenClawGatewayAdapter({ GatewayClientClass: downgraded.GatewayClientClass });
  await adapter.ensureStarted();
  assert.equal(adapter.protocolVersion, 4);
  assert.equal(adapter.runtimeVersion, '2026.8.1');
  assert.equal(adapter.capabilities.includes('turn.interrupt.v1'), false);
  assert.equal(adapter.capabilities.includes('approval.resolve.v1'), false);
  adapter.stop();
});

test('OpenClaw reconnects to the exact bound session without creating or selecting by recency', async () => {
  const fixture = openClawFixture({
    sessions: [
      { key: 'agent:main:newer', derivedTitle: 'Newer', updatedAt: 99 },
      { key: 'agent:main:bound', derivedTitle: 'Bound', updatedAt: 1 },
    ],
  });
  const adapter = new OpenClawGatewayAdapter({
    GatewayClientClass: fixture.GatewayClientClass,
    preferredSessionId: 'agent:main:bound',
  });
  await adapter.ensureStarted();
  const recovered = once(adapter, 'status');
  fixture.hello('connection-b');
  assert.match((await recovered)[0], /reconnected to the exact session/i);
  const subscriptions = fixture.requests.filter((request) => request.method === 'sessions.messages.subscribe');
  assert.equal(subscriptions.at(-1).params.key, 'agent:main:bound');
  assert.equal(fixture.requests.filter((request) => request.method === 'sessions.create').length, 0);
  assert.equal((await adapter.getChatState()).activeThreadId, 'agent:main:bound');
  adapter.stop();
});

test('OpenClaw conformance reports an accepted turn as unknown when reconnect is permanently paused', async () => {
  const fixture = openClawFixture();
  const adapter = new OpenClawGatewayAdapter({ GatewayClientClass: fixture.GatewayClientClass });
  await adapter.ensureStarted();
  const pendingRequest = installPendingRequestExitProbe(adapter);
  await assertAcceptedTurnBecomesUnknownOnRuntimeExit({
    adapter,
    operationId: 'client:openclaw-disconnect',
    forbiddenDiagnostics: ['openclaw-adapter-secret', 'captured private OpenClaw context'],
    exitRuntime: () => {
      fixture.event('future.openclaw.event', {
        sessionKey: fixture.activeKey, runId: 'run-future', token: 'native-openclaw-secret', content: 'private openclaw payload',
      });
      fixture.pause('token=openclaw-adapter-secret <zommi_invocation_context>captured private OpenClaw context</zommi_invocation_context>');
    },
  });
  assertSafeUnknownNativeDiagnostic(adapter, {
    eventName: 'future.openclaw.event', forbidden: ['native-openclaw-secret', 'private openclaw payload'],
  });
  await assert.rejects(pendingRequest, /disconnected permanently/);
  assert.equal((await adapter.getChatState()).activeTurns.length, 0);
  adapter.stop();
});

test('OpenClaw suppresses duplicate terminal frames and late deltas without resurrecting a run', async () => {
  const fixture = openClawFixture();
  const adapter = new OpenClawGatewayAdapter({ GatewayClientClass: fixture.GatewayClientClass });
  await adapter.ensureStarted();
  const accepted = await adapter.startTurn('once', [], [], { clientOperationId: 'client:openclaw-once' });
  const updates = [];
  const terminals = [];
  adapter.on('streamUpdate', (event) => updates.push(event));
  adapter.on('turnCompleted', (event) => terminals.push(event));
  fixture.event('chat', {
    state: 'delta', runId: accepted.turnId, sessionKey: accepted.threadId, seq: 0,
    deltaText: 'one', replace: false,
  });
  fixture.event('chat', {
    state: 'final', runId: accepted.turnId, sessionKey: accepted.threadId, seq: 1,
    message: { role: 'assistant', content: [{ type: 'text', text: 'one' }] },
  });
  fixture.event('chat', {
    state: 'final', runId: accepted.turnId, sessionKey: accepted.threadId, seq: 1,
    message: { role: 'assistant', content: [{ type: 'text', text: 'duplicate' }] },
  });
  fixture.event('chat', {
    state: 'delta', runId: accepted.turnId, sessionKey: accepted.threadId, seq: 2,
    deltaText: 'late', replace: false,
  });
  assert.deepEqual(updates.map((event) => event.text), ['one']);
  assert.equal(terminals.length, 1);
  assert.equal((await adapter.getChatState()).activeTurns.length, 0);
  adapter.stop();
});

function openClawFixture(options = {}) {
  const requests = [];
  const fixture = {
    requests,
    options: null,
    activeKey: options.activeKey || 'agent:main:zommi-new',
    event: null,
    hello: null,
    pause: null,
  };
  const methods = options.methods || [
    'sessions.list', 'sessions.create', 'sessions.messages.subscribe', 'sessions.messages.unsubscribe',
    'chat.history', 'chat.send', 'chat.abort', 'models.list', 'approval.resolve', 'question.resolve',
  ];
  class FakeGatewayClient {
    constructor(clientOptions) {
      fixture.options = clientOptions;
    }

    start() {
      queueMicrotask(() => fixture.hello('connection-a'));
    }

    stop() {}

    async request(method, params, requestOptions) {
      requests.push({ method, params, requestOptions });
      if (method === 'sessions.list') return { sessions: options.sessions || [] };
      if (method === 'sessions.create') return { ok: true, key: fixture.activeKey };
      if (method === 'chat.history') return { messages: [
        { role: 'user', content: [{ type: 'text', text: 'saved question' }] },
        { role: 'assistant', content: [{ type: 'text', text: 'saved answer' }] },
      ] };
      if (method === 'models.list') return { models: [{ id: 'gpt-test', name: 'GPT Test', provider: 'copilot' }] };
      if (method === 'sessions.messages.subscribe') return { key: params.key, approvalReplay: { approvals: [] } };
      if (method === 'sessions.messages.unsubscribe') return { ok: true };
      if (method === 'chat.send') return { runId: 'run-1', status: 'started' };
      return { ok: true };
    }
  }
  fixture.GatewayClientClass = FakeGatewayClient;
  fixture.hello = (connectionId) => fixture.options.onHelloOk({
        type: 'hello-ok', protocol: options.protocolVersion ?? 4, features: { methods, events: ['chat'] },
        server: { version: '2026.8.1', connId: connectionId }, snapshot: {},
        auth: { role: 'operator', scopes: fixture.options.scopes },
        policy: { maxPayload: 25_000_000, maxBufferedBytes: 50_000_000, tickIntervalMs: 15_000 },
  });
  fixture.pause = (reason) => fixture.options.onReconnectPaused({ code: 1008, reason, detailCode: 'PROTOCOL_MISMATCH' });
  fixture.event = (event, payload) => fixture.options.onEvent({ type: 'event', event, payload, seq: 1 });
  return fixture;
}
