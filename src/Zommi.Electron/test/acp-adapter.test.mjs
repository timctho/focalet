import assert from 'node:assert/strict';
import { EventEmitter, once } from 'node:events';
import { PassThrough } from 'node:stream';
import test from 'node:test';
import { AcpAdapter, capabilitiesFromAcpInitialize } from '../acp-adapter.mjs';
import { assertAcceptedTurnBecomesUnknownOnRuntimeExit, assertSafeUnknownNativeDiagnostic, installPendingRequestExitProbe } from './adapter-conformance.mjs';

test('ACP initializes, authenticates with runtime-owned credentials, and creates a session', async () => {
  const fixture = acpFixture();
  const adapter = new AcpAdapter({ command: 'hermes', commandArgs: ['acp'], spawnProcess: () => fixture.child, cwd: '/work' });
  const state = await adapter.getChatState();
  assert.equal(state.activeThreadId, 'session-new');
  assert.equal(state.activeModel, 'provider:model-a');
  assert.deepEqual(state.models.map((model) => model.id), ['provider:model-a', 'provider:model-b']);
  assert.ok(fixture.requests.some((request) => request.method === 'authenticate' && request.params.methodId === 'provider'));
  assert.ok(fixture.requests.some((request) => request.method === 'session/new' && request.params.cwd === '/work'));
  adapter.stop();
});

test('OpenClaw ACP bridge keeps credential resolution in the runtime-owned process', async () => {
  const fixture = acpFixture({ authMethods: [] });
  const adapter = new AcpAdapter({
    command: 'openclaw', commandArgs: ['acp'], spawnProcess: () => fixture.child,
    cwd: '/work', runtimeDisplayName: 'OpenClaw', signInHint: 'run openclaw onboard',
  });
  const statuses = [];
  adapter.on('status', (status) => statuses.push(status));
  const state = await adapter.getChatState();
  assert.equal(state.activeThreadId, 'session-new');
  assert.ok(fixture.requests.some((request) => request.method === 'initialize'));
  assert.ok(!fixture.requests.some((request) => request.method === 'authenticate'));
  assert.match(statuses.at(-1), /^OpenClaw ready/);
  adapter.stop();
});

test('ACP prompt acknowledges immediately, streams normalized updates, and completes exact turn', async () => {
  const fixture = acpFixture({ holdPrompt: true });
  const adapter = new AcpAdapter({ command: 'hermes', commandArgs: ['acp'], spawnProcess: () => fixture.child, cwd: '/work' });
  const streamed = once(adapter, 'streamUpdate');
  const completed = once(adapter, 'turnCompleted');
  const accepted = await adapter.startTurn('hello', [], [], { clientOperationId: 'client:acp-prompt' });
  assert.equal(accepted.accepted, true);
  assert.equal(accepted.threadId, 'session-new');
  const prompt = fixture.requests.find((request) => request.method === 'session/prompt');
  assert.ok(prompt, 'session/prompt was not written');
  fixture.send({
    jsonrpc: '2.0', method: 'session/update',
    params: { sessionId: 'session-new', update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'hi' }, messageId: 'message-a' } },
  });
  assert.equal((await streamed)[0].text, 'hi');
  const imageStreamed = once(adapter, 'streamUpdate');
  fixture.send({
    jsonrpc: '2.0', method: 'session/update',
    params: { sessionId: 'session-new', update: { sessionUpdate: 'agent_message_chunk', content: { type: 'image', mimeType: 'image/png', data: 'aGVsbG8=' }, messageId: 'message-image' } },
  });
  assert.equal((await imageStreamed)[0].artifacts[0].dataUrl, 'data:image/png;base64,aGVsbG8=');
  const toolStreamed = once(adapter, 'streamUpdate');
  fixture.send({
    jsonrpc: '2.0', method: 'session/update',
    params: {
      sessionId: 'session-new',
      update: { sessionUpdate: 'tool_call', toolCallId: 'tool-a', title: 'Read file', rawInput: { path: 'a.txt' } },
    },
  });
  const toolUpdate = (await toolStreamed)[0];
  assert.equal(toolUpdate.turnId, accepted.turnId);
  assert.equal(toolUpdate.clientOperationId, 'client:acp-prompt');
  fixture.send({ jsonrpc: '2.0', id: prompt.id, result: { stopReason: 'end_turn' } });
  assert.deepEqual((await completed)[0], {
    threadId: 'session-new', turnId: accepted.turnId, clientOperationId: 'client:acp-prompt',
    status: 'completed', stopReason: 'end_turn',
  });
  adapter.stop();
});

test('ACP loads only the exact preferred session and reconstructs history from in-call updates', async () => {
  const fixture = acpFixture({ replaySession: 'bound-session' });
  const adapter = new AcpAdapter({
    command: 'hermes', commandArgs: ['acp'], spawnProcess: () => fixture.child,
    cwd: '/work', preferredSessionId: 'bound-session',
  });
  const state = await adapter.getChatState();
  assert.equal(state.activeThreadId, 'bound-session');
  assert.equal(state.thread.turns[0].items[0].type, 'userMessage');
  assert.equal(state.thread.turns[0].items[1].text, 'saved answer');
  assert.deepEqual(fixture.requests.filter((request) => request.method === 'session/load').map((request) => request.params.sessionId), ['bound-session']);
  adapter.stop();
});

test('ACP permission requests deny by default unless the exact option is resolved', async () => {
  const fixture = acpFixture();
  const adapter = new AcpAdapter({ command: 'hermes', commandArgs: ['acp'], spawnProcess: () => fixture.child, cwd: '/work' });
  await adapter.ensureStarted();
  const approval = once(adapter, 'approvalRequested');
  fixture.send({
    jsonrpc: '2.0', id: 'permission-1', method: 'session/request_permission',
    params: {
      sessionId: 'session-new', toolCall: { toolCallId: 'tool-a', title: 'Run command' },
      options: [{ optionId: 'allow_once', kind: 'allow_once', name: 'Allow once' }],
    },
  });
  const request = (await approval)[0];
  assert.equal(request.toolCall.toolCallId, 'tool-a');
  adapter.resolveApproval(request.approvalId, 'allow_once');
  const response = fixture.responses.find((message) => message.id === 'permission-1');
  assert.deepEqual(response.result, { outcome: { outcome: 'selected', optionId: 'allow_once' } });
  adapter.stop();
});

test('ACP negotiated capabilities come from initialize rather than adapter name', () => {
  const capabilities = capabilitiesFromAcpInitialize({
    agentCapabilities: {
      loadSession: true,
      promptCapabilities: { image: true },
      sessionCapabilities: { list: {} },
    },
  });
  assert.ok(capabilities.includes('history.read.v1'));
  assert.ok(capabilities.includes('session.list.v1'));
  assert.ok(capabilities.includes('input.image.v1'));
});

test('ACP rejects protocol version skew before advertising a ready target', async () => {
  const fixture = acpFixture({ protocolVersion: 2 });
  const adapter = new AcpAdapter({ command: 'hermes', commandArgs: ['acp'], spawnProcess: () => fixture.child });
  await assert.rejects(adapter.ensureStarted(), /Unsupported ACP protocol version 2/);
  assert.equal(adapter.protocolVersion, null);
});

test('ACP conformance reports an accepted turn as unknown when its process exits', async () => {
  const fixture = acpFixture({ holdPrompt: true });
  const adapter = new AcpAdapter({ command: 'hermes', commandArgs: ['acp'], spawnProcess: () => fixture.child, cwd: '/work' });
  const pendingRequest = installPendingRequestExitProbe(adapter);
  await assertAcceptedTurnBecomesUnknownOnRuntimeExit({
    adapter,
    operationId: 'client:acp-exit',
    forbiddenDiagnostics: ['acp-adapter-secret', 'captured private ACP context'],
    exitRuntime: () => {
      fixture.send({ jsonrpc: '2.0', method: 'session/update', params: {
        sessionId: 'session-new', update: { sessionUpdate: 'future_acp_event', token: 'native-acp-secret', content: 'private acp payload' },
      } });
      fixture.stderr.write('password=acp-adapter-secret <zommi_invocation_context>captured private ACP context</zommi_invocation_context>');
      fixture.child.emit('exit', 23);
    },
  });
  assertSafeUnknownNativeDiagnostic(adapter, {
    eventName: 'future_acp_event', forbidden: ['native-acp-secret', 'private acp payload'],
  });
  await assert.rejects(pendingRequest, /exited/);
  adapter.stop();
});

function acpFixture(options = {}) {
  const stdout = new PassThrough();
  const stderr = new PassThrough();
  const requests = [];
  const responses = [];
  const child = Object.assign(new EventEmitter(), {
    stdout, stderr, killed: false,
    kill() { this.killed = true; },
  });
  child.stdin = {
    write(line) {
      const message = JSON.parse(line);
      if (!message.method) {
        responses.push(message);
        return true;
      }
      requests.push(message);
      if (!Object.hasOwn(message, 'id')) return true;
      let result = {};
      if (message.method === 'initialize') result = {
        protocolVersion: options.protocolVersion ?? 1,
        agentInfo: { name: 'fixture', version: '1.0.0' },
        agentCapabilities: {
          loadSession: true,
          promptCapabilities: { image: true },
          sessionCapabilities: { list: {}, resume: {} },
        },
        authMethods: options.authMethods ?? [{ id: 'provider', name: 'Provider credentials' }],
      };
      if (message.method === 'session/list') result = { sessions: [] };
      if (message.method === 'session/new') result = {
        sessionId: 'session-new',
        models: {
          currentModelId: 'provider:model-a',
          availableModels: [
            { modelId: 'provider:model-a', name: 'Model A' },
            { modelId: 'provider:model-b', name: 'Model B' },
          ],
        },
      };
      if (message.method === 'session/load') {
        if (options.replaySession === message.params.sessionId) {
          queueMicrotask(() => {
            send({ jsonrpc: '2.0', method: 'session/update', params: { sessionId: message.params.sessionId, update: { sessionUpdate: 'user_message_chunk', content: { type: 'text', text: 'saved question' }, messageId: 'user-saved' } } });
            send({ jsonrpc: '2.0', method: 'session/update', params: { sessionId: message.params.sessionId, update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'saved answer' }, messageId: 'agent-saved' } } });
            send({ jsonrpc: '2.0', id: message.id, result: {} });
          });
          return true;
        }
      }
      if (message.method === 'session/prompt' && options.holdPrompt) return true;
      queueMicrotask(() => send({ jsonrpc: '2.0', id: message.id, result }));
      return true;
    },
  };
  function send(message) {
    stdout.write(`${JSON.stringify(message)}\n`);
  }
  return { child, stdout, stderr, requests, responses, send };
}
