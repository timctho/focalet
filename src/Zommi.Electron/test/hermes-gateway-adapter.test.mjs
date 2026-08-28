import assert from 'node:assert/strict';
import { EventEmitter, once } from 'node:events';
import { PassThrough } from 'node:stream';
import test from 'node:test';
import {
  HermesGatewayAdapter,
  buildHermesGatewayLaunch,
  hermesMessagesToTurns,
  hermesModelsForRenderer,
} from '../hermes-gateway-adapter.mjs';
import { assertAcceptedTurnBecomesUnknownOnRuntimeExit, assertSafeUnknownNativeDiagnostic, installPendingRequestExitProbe } from './adapter-conformance.mjs';

test('Hermes Gateway owns an isolated loopback lifecycle and resumes only the exact binding', async () => {
  const fixture = gatewayFixture({ sessions: [{ id: 'stored-a', title: 'Saved chat', preview: 'hello' }] });
  const adapter = new HermesGatewayAdapter({
    command: 'hermes', commandArgs: ['serve'], preferredSessionId: 'stored-a',
    spawnProcess: fixture.spawnProcess, fetchImpl: fixture.fetchImpl, WebSocketImpl: fixture.WebSocketImpl,
    sessionToken: 'test-session-token',
  });
  const state = await adapter.getChatState();
  assert.equal(state.activeThreadId, 'stored-a');
  assert.equal(adapter.protocolVersion, 1);
  assert.equal(adapter.runtimeVersion, '0.20.0');
  assert.equal(state.thread.turns[0].items[0].content[0].text, 'saved question');
  assert.equal(fixture.healthUrls[0], 'http://127.0.0.1:43119/api/health');
  assert.match(fixture.socketUrls[0], /^ws:\/\/127\.0\.0\.1:43119\/api\/ws\?token=test-session-token$/);
  assert.deepEqual(fixture.requests.slice(0, 2).map((request) => request.method), ['session.list', 'session.resume']);
  assert.ok(fixture.spawn.args.includes('--isolated'));
  assert.equal(fixture.spawn.options.env.HERMES_DASHBOARD_SESSION_TOKEN, 'test-session-token');
  adapter.stop();
});

test('Hermes Gateway maps acknowledged turns, images, events, approvals, and questions', async () => {
  const fixture = gatewayFixture();
  const adapter = new HermesGatewayAdapter({
    command: 'hermes', commandArgs: ['serve'], spawnProcess: fixture.spawnProcess,
    fetchImpl: fixture.fetchImpl, WebSocketImpl: fixture.WebSocketImpl, sessionToken: 'token-b',
  });
  await adapter.ensureStarted();
  const accepted = await adapter.startTurn(
    'inspect this', [], ['data:image/png;base64,aGVsbG8='],
    { clientOperationId: 'client:hermes-gateway-turn' },
  );
  assert.equal(accepted.accepted, true);
  assert.ok(fixture.requests.some((request) => request.method === 'image.attach_bytes'));
  const streamed = once(adapter, 'streamUpdate');
  fixture.event('message.delta', fixture.runtimeSessionId, { text: 'answer' });
  assert.equal((await streamed)[0].text, 'answer');
  const completed = once(adapter, 'turnCompleted');
  fixture.event('message.complete', fixture.runtimeSessionId, { text: 'answer', status: 'complete' });
  assert.deepEqual((await completed)[0], {
    threadId: fixture.storedSessionId, turnId: accepted.turnId,
    clientOperationId: 'client:hermes-gateway-turn', status: 'completed',
  });

  const approval = once(adapter, 'approvalRequested');
  fixture.event('approval.request', fixture.runtimeSessionId, {
    request_id: 'approval-1', command: 'git status', choices: ['once', 'deny'],
  });
  const approvalRequest = (await approval)[0];
  await adapter.resolveApproval(approvalRequest.approvalId, 'once');
  assert.deepEqual(fixture.requests.find((request) => request.method === 'approval.respond').params, {
    request_id: 'approval-1', decision: 'once',
  });

  const question = once(adapter, 'questionRequested');
  fixture.event('clarify.request', fixture.runtimeSessionId, {
    request_id: 'question-1', question: 'Which branch?', choices: ['main', 'dev'],
  });
  const questionRequest = (await question)[0];
  await adapter.resolveQuestion(questionRequest.questionId, { value: 'dev' });
  assert.deepEqual(fixture.requests.find((request) => request.method === 'clarify.respond').params, {
    request_id: 'question-1', answer: 'dev',
  });
  adapter.stop();
});

test('Hermes Gateway launch injects its transport token inside WSL without exporting it globally', () => {
  const launch = buildHermesGatewayLaunch({
    args: ['-d', 'Ubuntu', '-e', '/usr/local/bin/hermes', 'serve'],
    executionHost: { kind: 'wsl' },
    sessionToken: 'private-token',
  });
  assert.deepEqual(launch.env, {});
  assert.deepEqual(launch.args.slice(3, 7), [
    'env', 'HERMES_DASHBOARD_SESSION_TOKEN=private-token', '/usr/local/bin/hermes', 'serve',
  ]);
  assert.ok(launch.args.includes('--port'));
  assert.ok(launch.args.includes('--isolated'));
});

test('Hermes model and history projections retain provider identity and reasoning', () => {
  const models = hermesModelsForRenderer({
    providers: [{ slug: 'copilot', models: [{ id: 'gpt-test', name: 'GPT Test' }] }],
  });
  assert.equal(models[0].id, 'copilot::gpt-test');
  assert.equal(models[0].displayName, 'GPT Test');
  const turns = hermesMessagesToTurns([
    { role: 'user', text: 'question' },
    { role: 'assistant', text: 'answer', reasoning: 'thought' },
  ]);
  assert.deepEqual(turns[0].items.map((item) => item.type), ['userMessage', 'reasoning', 'agentMessage']);
});

test('Hermes Gateway conformance reports an accepted turn as unknown when its process exits', async () => {
  const fixture = gatewayFixture();
  const adapter = new HermesGatewayAdapter({
    command: 'hermes', commandArgs: ['serve'], spawnProcess: fixture.spawnProcess,
    fetchImpl: fixture.fetchImpl, WebSocketImpl: fixture.WebSocketImpl, sessionToken: 'token-exit',
  });
  const pendingRequest = installPendingRequestExitProbe(adapter);
  await assertAcceptedTurnBecomesUnknownOnRuntimeExit({
    adapter,
    operationId: 'client:hermes-exit',
    forbiddenDiagnostics: ['hermes-adapter-secret', 'captured private Hermes context'],
    exitRuntime: () => {
      fixture.event('future.hermes.event', fixture.runtimeSessionId, {
        token: 'native-hermes-secret', text: 'private hermes payload', runId: 'run-future',
      });
      fixture.stderr.write('secret=hermes-adapter-secret <zommi_invocation_context>captured private Hermes context</zommi_invocation_context>');
      fixture.child.emit('exit', 25);
    },
  });
  assertSafeUnknownNativeDiagnostic(adapter, {
    eventName: 'future.hermes.event', forbidden: ['native-hermes-secret', 'private hermes payload'],
  });
  await assert.rejects(pendingRequest, /exited/);
  adapter.stop();
});

function gatewayFixture(options = {}) {
  const stdout = new PassThrough();
  const stderr = new PassThrough();
  const requests = [];
  const socketUrls = [];
  const healthUrls = [];
  const sessions = options.sessions || [];
  const storedSessionId = options.storedSessionId || 'stored-new';
  const runtimeSessionId = options.runtimeSessionId || 'runtime-new';
  const spawn = {};
  const child = Object.assign(new EventEmitter(), {
    stdout, stderr, killed: false,
    kill() { this.killed = true; },
  });
  const spawnProcess = (command, args, spawnOptions) => {
    Object.assign(spawn, { command, args, options: spawnOptions });
    queueMicrotask(() => stdout.write('HERMES_BACKEND_READY port=43119\n'));
    return child;
  };
  const fetchImpl = async (url) => {
    healthUrls.push(url);
    return { ok: true, status: 200, async json() { return { ok: true, auth_required: false, version: '0.20.0' }; } };
  };
  let socket = null;
  class FakeWebSocket extends EventTarget {
    constructor(url) {
      super();
      socketUrls.push(url);
      socket = this;
      this.readyState = 0;
      queueMicrotask(() => {
        this.readyState = 1;
        this.dispatchEvent(new Event('open'));
        this.message({ jsonrpc: '2.0', method: 'event', params: { type: 'gateway.ready', payload: {} } });
      });
    }

    send(raw) {
      const request = JSON.parse(raw);
      requests.push(request);
      let result = {};
      if (request.method === 'session.list') result = { sessions };
      if (request.method === 'session.create') result = {
        session_id: runtimeSessionId, stored_session_id: storedSessionId,
        messages: [], info: { model: 'gpt-test', provider: 'copilot', reasoning_effort: 'medium' },
      };
      if (request.method === 'session.resume') result = {
        session_id: runtimeSessionId, resumed: request.params.session_id, session_key: request.params.session_id,
        messages: [
          { role: 'user', text: 'saved question' },
          { role: 'assistant', text: 'saved answer' },
        ],
        info: { model: 'gpt-test', provider: 'copilot', reasoning_effort: 'medium' },
      };
      if (request.method === 'model.options') result = {
        providers: [{ slug: 'copilot', models: [{ id: 'gpt-test', name: 'GPT Test' }] }],
      };
      if (request.method === 'prompt.submit') result = { status: 'streaming' };
      queueMicrotask(() => this.message({ jsonrpc: '2.0', id: request.id, result }));
    }

    close() {
      this.readyState = 3;
      this.dispatchEvent(new Event('close'));
    }

    message(frame) {
      this.dispatchEvent(new MessageEvent('message', { data: JSON.stringify(frame) }));
    }
  }
  function event(type, sessionId, payload) {
    socket.message({ jsonrpc: '2.0', method: 'event', params: { type, session_id: sessionId, payload } });
  }
  return {
    spawnProcess, fetchImpl, WebSocketImpl: FakeWebSocket, requests, socketUrls, healthUrls,
    spawn, child, stdout, stderr, event, runtimeSessionId, storedSessionId,
  };
}
