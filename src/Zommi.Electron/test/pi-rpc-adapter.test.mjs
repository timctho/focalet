import assert from 'node:assert/strict';
import { EventEmitter, once } from 'node:events';
import { PassThrough } from 'node:stream';
import test from 'node:test';
import { PiRpcAdapter, piMessagesToTurns } from '../pi-rpc-adapter.mjs';
import { assertAcceptedTurnBecomesUnknownOnRuntimeExit, assertSafeUnknownNativeDiagnostic, installPendingRequestExitProbe } from './adapter-conformance.mjs';

test('Pi RPC initializes from runtime-owned state and maps models, reasoning, messages, and session file', async () => {
  const fixture = piFixture();
  const adapter = new PiRpcAdapter({ command: 'pi', commandArgs: ['--mode', 'rpc'], spawnProcess: () => fixture.child, cwd: '/work' });
  const state = await adapter.getChatState();
  assert.equal(state.activeThreadId, 'pi-session-a');
  assert.equal(state.activeModel, 'openai/gpt-test');
  assert.equal(state.activeEffort, 'high');
  assert.equal(adapter.protocolVersion, 1);
  assert.deepEqual(state.sessionMetadata, { sessionFile: '/sessions/a.jsonl' });
  assert.deepEqual(state.models[0].supportedReasoningEfforts.map((item) => item.reasoningEffort), ['off', 'high']);
  assert.equal(state.thread.turns[0].items[1].text, 'saved answer');
  adapter.stop();
});

test('Pi RPC uses strict LF framing and preserves Unicode line separators inside JSON strings', async () => {
  const fixture = piFixture();
  const adapter = new PiRpcAdapter({ command: 'pi', commandArgs: ['--mode', 'rpc'], spawnProcess: () => fixture.child });
  await adapter.ensureStarted();
  const streamed = once(adapter, 'streamUpdate');
  fixture.sendRaw(`${JSON.stringify({
    type: 'message_update',
    assistantMessageEvent: { type: 'text_delta', contentIndex: 0, delta: 'left\u2028right' },
  })}\n`);
  assert.equal((await streamed)[0].text, 'left\u2028right');
  adapter.stop();
});

test('Pi prompt returns after acceptance and completes when the official agent_end event arrives', async () => {
  const fixture = piFixture();
  const adapter = new PiRpcAdapter({ command: 'pi', commandArgs: ['--mode', 'rpc'], spawnProcess: () => fixture.child });
  const accepted = await adapter.startTurn(
    'hello', [], [], { clientOperationId: 'client:pi-prompt' },
  );
  assert.equal(accepted.accepted, true);
  assert.deepEqual(accepted.sessionMetadata, { sessionFile: '/sessions/a.jsonl' });
  const steered = await adapter.steerTurn('also compare totals', [], {
    sessionId: accepted.threadId,
    turnId: accepted.turnId,
  });
  assert.deepEqual(steered, {
    accepted: true,
    threadId: accepted.threadId,
    turnId: accepted.turnId,
    clientOperationId: 'client:pi-prompt',
  });
  assert.ok(fixture.requests.some((request) => request.type === 'steer' && request.message === 'also compare totals'));
  await assert.rejects(
    adapter.steerTurn('wrong turn', [], { sessionId: accepted.threadId, turnId: 'other-turn' }),
    /turn identity does not match/,
  );
  const streamed = once(adapter, 'streamUpdate');
  fixture.send({ type: 'message_update', assistantMessageEvent: { type: 'thinking_delta', contentIndex: 0, delta: 'considering' } });
  assert.equal((await streamed)[0].kind, 'thinking');
  const imageStreamed = once(adapter, 'streamUpdate');
  fixture.send({
    type: 'tool_execution_end', toolName: 'generate_image', toolCallId: 'image-tool',
    result: { content: [{ type: 'image', mimeType: 'image/png', data: 'aGVsbG8=' }] },
  });
  assert.equal((await imageStreamed)[0].artifacts[0].dataUrl, 'data:image/png;base64,aGVsbG8=');
  const completed = once(adapter, 'turnCompleted');
  fixture.send({ type: 'agent_end' });
  assert.deepEqual((await completed)[0], {
    threadId: 'pi-session-a', turnId: accepted.turnId,
    clientOperationId: 'client:pi-prompt', status: 'completed',
  });
  adapter.stop();
});

test('Pi resumes only an exact runtime-owned session file and answers extension questions', async () => {
  const fixture = piFixture({ switchedSessionFile: '/sessions/b.jsonl' });
  const adapter = new PiRpcAdapter({
    command: 'pi', commandArgs: ['--mode', 'rpc'], spawnProcess: () => fixture.child,
    preferredSessionFile: '/sessions/b.jsonl',
  });
  await adapter.ensureStarted();
  assert.ok(fixture.requests.some((request) => request.type === 'switch_session' && request.sessionPath === '/sessions/b.jsonl'));
  const question = once(adapter, 'questionRequested');
  fixture.send({ type: 'extension_ui_request', id: 'ui-1', method: 'confirm', title: 'Continue?', message: 'Run it?' });
  const request = (await question)[0];
  adapter.resolveQuestion(request.questionId, { confirmed: true });
  assert.deepEqual(fixture.responses.find((response) => response.id === 'ui-1'), {
    type: 'extension_ui_response', id: 'ui-1', confirmed: true,
  });
  adapter.stop();
});

test('Pi message history groups assistant reasoning, text, tool calls, and results under user turns', () => {
  const turns = piMessagesToTurns([
    { id: 'u1', role: 'user', content: [{ type: 'text', text: 'question' }] },
    { id: 'a1', role: 'assistant', content: [
      { type: 'thinking', text: 'reasoning' },
      { type: 'text', text: 'answer' },
      { type: 'toolCall', id: 'tool-1', name: 'read', arguments: { path: 'a' } },
    ] },
    { id: 'r1', role: 'toolResult', toolCallId: 'tool-1', content: [
      { type: 'text', text: 'file' },
      { type: 'image', mimeType: 'image/png', data: 'aGVsbG8=' },
    ] },
  ]);
  assert.equal(turns.length, 1);
  assert.deepEqual(turns[0].items.map((item) => item.type), ['userMessage', 'reasoning', 'agentMessage', 'dynamicToolCall', 'commandExecution']);
  assert.equal(turns[0].items.at(-1).artifacts[0].dataUrl, 'data:image/png;base64,aGVsbG8=');
});

test('Pi conformance reports an accepted turn as unknown when its process exits', async () => {
  const fixture = piFixture();
  const adapter = new PiRpcAdapter({ command: 'pi', commandArgs: ['--mode', 'rpc'], spawnProcess: () => fixture.child });
  const pendingRequest = installPendingRequestExitProbe(adapter);
  await assertAcceptedTurnBecomesUnknownOnRuntimeExit({
    adapter,
    operationId: 'client:pi-exit',
    forbiddenDiagnostics: ['pi-adapter-secret', 'captured private Pi context'],
    exitRuntime: () => {
      fixture.send({ type: 'future_pi_event', sessionId: 'pi-session-a', token: 'native-pi-secret', message: 'private pi payload' });
      fixture.stderr.write('api_key=pi-adapter-secret <zommi_invocation_context>captured private Pi context</zommi_invocation_context>');
      fixture.child.emit('exit', 24);
    },
  });
  assertSafeUnknownNativeDiagnostic(adapter, {
    eventName: 'future_pi_event', forbidden: ['native-pi-secret', 'private pi payload'],
  });
  await assert.rejects(pendingRequest, /exited/);
  adapter.stop();
});

function piFixture(options = {}) {
  const stdout = new PassThrough();
  const stderr = new PassThrough();
  const requests = [];
  const responses = [];
  let sessionFile = '/sessions/a.jsonl';
  let sessionId = 'pi-session-a';
  const child = Object.assign(new EventEmitter(), {
    stdout, stderr, killed: false,
    kill() { this.killed = true; },
  });
  child.stdin = {
    write(line) {
      const message = JSON.parse(line);
      if (message.type === 'extension_ui_response') {
        responses.push(message);
        return true;
      }
      requests.push(message);
      let data = null;
      if (message.type === 'get_state') data = {
        model: { provider: 'openai', id: 'gpt-test' },
        thinkingLevel: 'high', isStreaming: false, sessionFile, sessionId,
        messageCount: 2, pendingMessageCount: 0,
      };
      if (message.type === 'get_available_models') data = {
        models: [{
          provider: 'openai', id: 'gpt-test', name: 'GPT Test', reasoning: true,
          thinkingLevelMap: { minimal: null, low: null, medium: null, xhigh: null },
        }],
      };
      if (message.type === 'get_messages') data = { messages: [
        { id: 'u', role: 'user', content: [{ type: 'text', text: 'saved question' }] },
        { id: 'a', role: 'assistant', content: [{ type: 'text', text: 'saved answer' }] },
      ] };
      if (message.type === 'switch_session') {
        sessionFile = message.sessionPath;
        sessionId = options.switchedSessionFile === message.sessionPath ? 'pi-session-b' : 'pi-session-a';
        data = { cancelled: false };
      }
      if (message.type === 'new_session') {
        sessionFile = '/sessions/new.jsonl';
        sessionId = 'pi-session-new';
        data = { cancelled: false };
      }
      queueMicrotask(() => send({
        id: message.id, type: 'response', command: message.type, success: true,
        ...(data === null ? {} : { data }),
      }));
      return true;
    },
  };
  function send(message) {
    stdout.write(`${JSON.stringify(message)}\n`);
  }
  function sendRaw(value) {
    stdout.write(value);
  }
  return { child, stdout, stderr, requests, responses, send, sendRaw };
}
