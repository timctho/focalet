import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { RuntimeBroker, classifyRuntimeError, createDefaultRuntimeAdapter } from '../runtime-broker.mjs';
import { BROKER_PROTOCOL_VERSION, BrokerProtocolError, ambiguousOutcome } from '../broker-protocol.mjs';
import { AcpAdapter } from '../acp-adapter.mjs';
import { catalogEntry } from '../runtime-catalog.mjs';

test('broker chooses default-WSL protocol target and exposes runtime-neutral state', async () => {
  const discovery = new FakeDiscovery([
    target('native-codex', 'codex-app-server', { kind: 'native', displayName: 'Windows' }, 10),
    target('wsl-pi', 'pi-rpc', { kind: 'wsl', displayName: 'WSL · Ubuntu', isDefault: true }, 20),
  ]);
  const broker = new RuntimeBroker({ discovery, autoWarm: false, adapterFactory: fakeAdapterFactory });
  const state = await broker.initialize();
  assert.equal(state.activeTargetId, 'wsl-pi');
  assert.equal(state.targets.length, 2);
  assert.deepEqual(state.activeTarget.capabilities, []);
  assert.deepEqual(state.activeTarget.capabilityHints, ['turn.stream.v1']);
});

test('OpenClaw local target uses the official ACP credential bridge adapter', () => {
  const runtimeTarget = {
    ...target('wsl-openclaw', 'openclaw-acp', {
      kind: 'wsl', name: 'Ubuntu', displayName: 'WSL · Ubuntu', isDefault: true,
    }, 40),
    runtimeId: 'openclaw', displayName: 'OpenClaw', protocolName: 'Gateway via ACP',
    executableName: 'openclaw', executablePath: '/home/user/bin/openclaw', runtimeHome: '/home/user',
  };
  const adapter = createDefaultRuntimeAdapter(runtimeTarget, {
    entry: catalogEntry('openclaw-acp'), binding: { sessionId: 'agent:main:saved' },
  });
  assert.ok(adapter instanceof AcpAdapter);
  assert.equal(adapter.command, 'wsl.exe');
  assert.deepEqual(adapter.commandArgs, [
    '-d', 'Ubuntu', '--cd', '/home/user', '-e', '/home/user/bin/openclaw', 'acp',
  ]);
  assert.equal(adapter.runtimeDisplayName, 'OpenClaw');
  assert.equal(adapter.preferredSessionId, 'agent:main:saved');
});

test('broker persists explicit target selection and exact Session Binding without credentials', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'zommi-runtime-broker-'));
  const preferencePath = join(directory, 'runtime-preferences.json');
  const seenBindings = [];
  try {
    const discovery = new FakeDiscovery([
      target('wsl-codex', 'codex-app-server', { kind: 'wsl', displayName: 'WSL · Ubuntu', isDefault: true }, 10),
      target('native-pi', 'pi-rpc', { kind: 'native', displayName: 'Windows' }, 20),
    ]);
    const factory = (_target, { binding }) => {
      seenBindings.push(binding);
      return new FakeAdapter('pi-thread');
    };
    const first = new RuntimeBroker({ discovery, preferencePath, autoWarm: false, adapterFactory: factory });
    await first.selectTarget('native-pi', { activate: false });
    const chat = await first.getChatState();
    assert.deepEqual(chat.sessionBinding, { runtimeTargetId: 'native-pi', sessionId: 'pi-thread' });
    first.stop();

    const persisted = JSON.parse(await readFile(preferencePath, 'utf8'));
    assert.equal(persisted.lastSelectedTargetId, 'native-pi');
    assert.deepEqual(persisted.bindings['native-pi'], { sessionId: 'pi-thread' });
    assert.doesNotMatch(JSON.stringify(persisted), /token|password|credential/i);

    const second = new RuntimeBroker({ discovery, preferencePath, autoWarm: false, adapterFactory: factory });
    await second.getChatState();
    assert.deepEqual(seenBindings.at(-1), { sessionId: 'pi-thread' });
    second.stop();
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test('broker decorates turn and stream identities with the exact Runtime Target', async () => {
  const discovery = new FakeDiscovery([
    target('wsl-codex', 'codex-app-server', { kind: 'wsl', displayName: 'WSL · Ubuntu', isDefault: true }, 10),
  ]);
  const adapter = new FakeAdapter('thread-a');
  const broker = new RuntimeBroker({ discovery, autoWarm: false, adapterFactory: () => adapter });
  const streamed = new Promise((resolve) => broker.once('streamUpdate', resolve));
  const result = await broker.startTurn('hello');
  adapter.emit('streamUpdate', { threadId: 'thread-a', kind: 'assistant', text: 'hello' });
  assert.equal(result.runtimeTargetId, 'wsl-codex');
  assert.equal((await streamed).runtimeTargetId, 'wsl-codex');
});

test('authentication failures become actionable target state', async () => {
  const discovery = new FakeDiscovery([
    target('wsl-codex', 'codex-app-server', { kind: 'wsl', displayName: 'WSL · Ubuntu', isDefault: true }, 10),
  ]);
  const broker = new RuntimeBroker({
    discovery,
    autoWarm: false,
    adapterFactory: () => new FailingAdapter('not authenticated; run codex login'),
  });
  await assert.rejects(broker.getChatState(), /not authenticated/);
  assert.equal(broker.getStatus().status, 'sign-in-required');
  assert.deepEqual(broker.getSignInLaunch().args.slice(-2), ['/home/user/codex', 'login']);
});

test('non-default WSL discovery failures stay diagnostic and do not replace a ready runtime status', async () => {
  const discovery = new FakeDiscovery([
    target('wsl-codex', 'codex-app-server', { kind: 'wsl', displayName: 'WSL · Ubuntu-20.04', isDefault: true }, 10),
  ]);
  const broker = new RuntimeBroker({ discovery, autoWarm: false, adapterFactory: fakeAdapterFactory });
  const statuses = [];
  const diagnostics = [];
  broker.on('status', (status) => statuses.push(status));
  broker.on('diagnostic', (diagnostic) => diagnostics.push(diagnostic));
  await broker.activateTarget('wsl-codex');
  const statusCount = statuses.length;
  discovery.emit('hostError', {
    host: { kind: 'wsl', displayName: 'WSL · Ubuntu', isDefault: false },
    error: 'distribution did not respond',
  });
  assert.equal(statuses.length, statusCount);
  assert.equal(diagnostics.length, 1);
  assert.match(diagnostics[0].message, /WSL · Ubuntu discovery unavailable/);
  assert.equal(broker.getStatus('wsl-codex').status, 'ready');
});

test('resume rediscovery reuses TTL-aware discovery without forcing a full refresh', async () => {
  const discovery = new FakeDiscovery([
    target('wsl-codex', 'codex-app-server', { kind: 'wsl', displayName: 'WSL · Ubuntu', isDefault: true }, 10),
  ]);
  const broker = new RuntimeBroker({ discovery, autoWarm: false, adapterFactory: fakeAdapterFactory });
  await broker.initialize();
  await broker.rediscoverTargets();
  assert.deepEqual(discovery.discoverOptions, [undefined, { force: false }]);
  assert.equal(discovery.refreshCalls, 0);
});

test('automatic activation falls back only to another machine mode of the same runtime', async () => {
  const discovery = new FakeDiscovery([
    target('hermes-acp', 'hermes-acp', { kind: 'wsl', displayName: 'WSL · Ubuntu', isDefault: true }, 30),
    target('hermes-gateway', 'hermes-gateway', { kind: 'wsl', displayName: 'WSL · Ubuntu', isDefault: true }, 31),
    target('native-pi', 'pi-rpc', { kind: 'native', displayName: 'Windows' }, 20),
  ]);
  const broker = new RuntimeBroker({
    discovery,
    autoWarm: false,
    adapterFactory: (runtimeTarget) => runtimeTarget.id === 'hermes-acp'
      ? new FailingAdapter('unknown command acp')
      : new FakeAdapter('thread-a'),
  });
  await broker.initialize();
  await broker.warmSelectedTarget();
  assert.equal(broker.getRuntimeState().activeTargetId, 'hermes-gateway');
  assert.equal(broker.getStatus('hermes-acp').status, 'unsupported-version');
  assert.equal(broker.getStatus('native-pi').status, 'detected');
});

test('explicit target selection cancels only an in-flight automatic warm-up', async () => {
  const discovery = new FakeDiscovery([
    target('wsl-codex', 'codex-app-server', { kind: 'wsl', displayName: 'WSL · Ubuntu', isDefault: true }, 10),
    target('native-pi', 'pi-rpc', { kind: 'native', displayName: 'Windows' }, 20),
  ]);
  const warming = new DeferredAdapter();
  const broker = new RuntimeBroker({
    discovery,
    autoWarm: false,
    adapterFactory: (runtimeTarget) => runtimeTarget.id === 'wsl-codex' ? warming : new FakeAdapter('pi-thread'),
  });
  await broker.initialize();
  const activation = broker.activateTarget('wsl-codex');
  activation.catch(() => {});
  await warming.started;
  await broker.selectTarget('native-pi', { activate: false });
  assert.equal(warming.stopped, true);
  warming.finish();
  await assert.rejects(activation, (error) => error.code === 'operation-cancelled');
  assert.equal(broker.getStatus('wsl-codex').status, 'detected');
  assert.equal(broker.getRuntimeState().activeTargetId, 'native-pi');
});

test('background discovery preserves negotiated capabilities and protocol version', async () => {
  const discovered = target('wsl-codex', 'codex-app-server', { kind: 'wsl', displayName: 'WSL · Ubuntu', isDefault: true }, 10);
  discovered.capabilities = [];
  discovered.protocolVersion = null;
  const discovery = new FakeDiscovery([discovered]);
  const broker = new RuntimeBroker({ discovery, autoWarm: false, adapterFactory: fakeAdapterFactory });
  await broker.activateTarget('wsl-codex');
  discovery.emit('targetsChanged', [{ ...discovered, capabilities: [], protocolVersion: null }]);
  assert.deepEqual(broker.getStatus('wsl-codex').capabilities, ['turn.stream.v1']);
  assert.equal(broker.getStatus('wsl-codex').protocolVersion, 1);
});

test('broker rejects missing or older negotiated protocol versions and records runtime version', async () => {
  const discovered = target('wsl-codex', 'codex-app-server', { kind: 'wsl', displayName: 'WSL · Ubuntu', isDefault: true }, 10);
  const discovery = new FakeDiscovery([discovered]);
  const oldAdapter = new FakeAdapter('thread-a');
  oldAdapter.protocolVersion = 0;
  const rejected = new RuntimeBroker({ discovery, autoWarm: false, adapterFactory: () => oldAdapter });
  await assert.rejects(
    rejected.activateTarget('wsl-codex'),
    (error) => error.code === 'unsupported-version',
  );
  assert.equal(rejected.getStatus('wsl-codex').status, 'unsupported-version');

  const readyAdapter = new FakeAdapter('thread-a');
  readyAdapter.runtimeVersion = '0.149.0';
  const accepted = new RuntimeBroker({ discovery, autoWarm: false, adapterFactory: () => readyAdapter });
  await accepted.activateTarget('wsl-codex');
  assert.equal(accepted.getStatus('wsl-codex').runtimeVersion, '0.149.0');
});

test('runtime error classification separates authentication, version, and reachability', () => {
  assert.equal(classifyRuntimeError(new Error('login required')), 'sign-in-required');
  assert.equal(classifyRuntimeError(new Error('unsupported command')), 'unsupported-version');
  assert.equal(classifyRuntimeError(new Error('connection reset')), 'unreachable');
});

test('rejected and ambiguous turns do not mark a healthy Runtime Target unreachable', async () => {
  const discovery = new FakeDiscovery([
    target('wsl-codex', 'codex-app-server', { kind: 'wsl', displayName: 'WSL · Ubuntu', isDefault: true }, 10),
  ]);
  const adapter = new FakeAdapter('thread-a');
  const broker = new RuntimeBroker({ discovery, autoWarm: false, adapterFactory: () => adapter });
  await broker.getChatState();
  adapter.startTurn = async () => { throw new Error('This session already has an active turn.'); };
  await assert.rejects(
    broker.startTurn('conflicting turn', [], [], { clientOperationId: 'client:rejected-turn' }),
    (error) => error.code === 'conflict' && error.outcome === 'rejected',
  );
  assert.equal(broker.getStatus('wsl-codex').status, 'ready');
  adapter.startTurn = async () => { throw ambiguousOutcome(new Error('write timed out'), 'Codex app-server'); };
  await assert.rejects(
    broker.startTurn('ambiguous turn', [], [], { clientOperationId: 'client:ambiguous-turn' }),
    (error) => error.code === 'ambiguous-outcome' && error.outcome === 'unknown' && !error.retryable,
  );
  assert.equal(broker.getStatus('wsl-codex').status, 'ready');
});

test('structured questions stay bound to the exact Runtime Target', async () => {
  const discovery = new FakeDiscovery([
    target('wsl-pi', 'pi-rpc', { kind: 'wsl', displayName: 'WSL · Ubuntu', isDefault: true }, 20),
  ]);
  const adapter = new FakeAdapter('pi-thread');
  adapter.resolveQuestion = (questionId, answer) => ({ resolved: true, questionId, answer });
  const broker = new RuntimeBroker({ discovery, autoWarm: false, adapterFactory: () => adapter });
  const requested = new Promise((resolve) => broker.once('questionRequested', resolve));
  await broker.getChatState();
  adapter.emit('questionRequested', { questionId: 'question-a', threadId: 'pi-thread', method: 'confirm' });
  const runtimeRequest = await requested;
  assert.equal(runtimeRequest.runtimeTargetId, 'wsl-pi');
  assert.equal(runtimeRequest.sessionId, 'pi-thread');
  await assert.rejects(
    broker.resolveQuestion('question-a', { confirmed: true }, {
      runtimeTargetId: 'wsl-pi', sessionId: 'other-thread',
    }),
    (error) => error.code === 'conflict',
  );
  assert.deepEqual(await broker.resolveQuestion('question-a', { confirmed: true }, {
    runtimeTargetId: 'wsl-pi', sessionId: 'pi-thread',
  }), {
    resolved: true, questionId: 'question-a', answer: { confirmed: true },
  });
});

test('one client operation is written at most once and conflicting replay is rejected', async () => {
  const discovery = new FakeDiscovery([
    target('wsl-codex', 'codex-app-server', { kind: 'wsl', displayName: 'WSL · Ubuntu', isDefault: true }, 10),
  ]);
  const adapter = new FakeAdapter('thread-a');
  const broker = new RuntimeBroker({ discovery, autoWarm: false, adapterFactory: () => adapter });
  const options = { clientOperationId: 'client:operation-1' };
  const first = await broker.startTurn('same message', [], [], options);
  const replay = await broker.startTurn('same message', [], [], options);
  assert.equal(adapter.startCalls, 1);
  assert.deepEqual(replay, first);
  await assert.rejects(
    broker.startTurn('different message', [], [], options),
    (error) => error instanceof BrokerProtocolError && error.code === 'conflict',
  );
});

test('normalized broker events carry exact identity and monotonic per-session sequence', async () => {
  const discovery = new FakeDiscovery([
    target('wsl-codex', 'codex-app-server', { kind: 'wsl', displayName: 'WSL · Ubuntu', isDefault: true }, 10),
  ]);
  const adapter = new FakeAdapter('thread-a');
  const broker = new RuntimeBroker({ discovery, autoWarm: false, adapterFactory: () => adapter });
  const events = [];
  const diagnostics = [];
  broker.on('event', (event) => events.push(event));
  broker.on('diagnostic', (diagnostic) => diagnostics.push(diagnostic));
  const turn = await broker.startTurn('hello', [], [], { clientOperationId: 'client:operation-2' });
  adapter.emit('streamUpdate', {
    threadId: 'thread-a', turnId: turn.turnId, kind: 'assistant', lifecycle: 'delta', text: 'hi',
  });
  adapter.emit('turnCompleted', { threadId: 'thread-a', turnId: turn.turnId, status: 'completed' });
  const turnEvents = events.filter((event) => event.sessionId === 'thread-a');
  assert.deepEqual(turnEvents.map((event) => event.type), [
    'turn.accepted', 'turn.started', 'assistant.delta', 'turn.completed',
  ]);
  assert.deepEqual(turnEvents.map((event) => event.sequence), [1, 2, 3, 4]);
  assert.ok(turnEvents.every((event) => event.runtimeTargetId === 'wsl-codex'));
  assert.ok(turnEvents.every((event) => event.clientOperationId === 'client:operation-2'));
  assert.ok(turnEvents.every((event) => event.turnId === 'turn-a'));
  adapter.emit('streamUpdate', {
    threadId: 'thread-a', turnId: turn.turnId, kind: 'assistant', lifecycle: 'delta', text: 'late',
  });
  adapter.emit('turnCompleted', { threadId: 'thread-a', turnId: turn.turnId, status: 'completed' });
  assert.equal(events.filter((event) => event.sessionId === 'thread-a').length, 4);
  assert.deepEqual(diagnostics.map((item) => item.message), [
    'Runtime emitted a late stream event after the turn reached a terminal state.',
    'Runtime emitted a duplicate terminal turn event.',
  ]);
});

test('generic broker envelope returns bounded snapshots and structured errors', async () => {
  const discovery = new FakeDiscovery([
    target('wsl-codex', 'codex-app-server', { kind: 'wsl', displayName: 'WSL · Ubuntu', isDefault: true }, 10),
  ]);
  const broker = new RuntimeBroker({ discovery, autoWarm: false, adapterFactory: fakeAdapterFactory });
  const listed = await broker.request({
    protocolVersion: BROKER_PROTOCOL_VERSION,
    operation: 'session.list',
    runtimeTargetId: 'wsl-codex',
    payload: { limit: 1 },
  });
  assert.equal(listed.ok, true);
  assert.deepEqual(listed.result.data, [{ id: 'thread-a' }]);
  const snapshot = await broker.request({
    protocolVersion: BROKER_PROTOCOL_VERSION,
    operation: 'events.subscribe',
    runtimeTargetId: 'wsl-codex',
    sessionId: 'thread-a',
    payload: {},
  });
  assert.equal(snapshot.result.snapshot.chat.activeThreadId, 'thread-a');
  const invalid = await broker.request({ protocolVersion: 99, operation: 'runtime.listTargets', payload: {} });
  assert.deepEqual(invalid.error.code, 'unsupported-version');
});

test('exact interrupt identity cannot resolve a different session or turn', async () => {
  const discovery = new FakeDiscovery([
    target('wsl-codex', 'codex-app-server', { kind: 'wsl', displayName: 'WSL · Ubuntu', isDefault: true }, 10),
  ]);
  const broker = new RuntimeBroker({ discovery, autoWarm: false, adapterFactory: fakeAdapterFactory });
  await broker.getChatState();
  await assert.rejects(
    broker.interruptTurn({ sessionId: 'wrong-session', turnId: 'turn-a' }),
    (error) => error.code === 'conflict',
  );
});

class FakeDiscovery extends EventEmitter {
  constructor(targets) {
    super();
    this.targets = targets;
    this.discoverOptions = [];
    this.refreshCalls = 0;
  }

  async discover(options) {
    this.discoverOptions.push(options);
    this.emit('targetsChanged', this.targets);
    return this.targets;
  }

  async waitForBackground() {
    return this.targets;
  }

  async refresh() {
    this.refreshCalls += 1;
    return this.targets;
  }

  invalidateTarget() {}
}

class FakeAdapter extends EventEmitter {
  constructor(threadId) {
    super();
    this.threadId = threadId;
    this.startCalls = 0;
    this.capabilities = ['turn.stream.v1'];
    this.protocolVersion = 1;
  }

  async ensureStarted() {}

  async getChatState() {
    return { activeThreadId: this.threadId, sessions: [{ id: this.threadId }], models: [] };
  }

  async createSession() {
    this.threadId = 'thread-new';
    return this.getChatState();
  }

  async switchSession(threadId) {
    this.threadId = threadId;
    return this.getChatState();
  }

  async startTurn() {
    this.startCalls += 1;
    return { accepted: true, threadId: this.threadId, turnId: 'turn-a' };
  }

  async interruptTurn() {
    return { interrupted: true, threadId: this.threadId, turnId: 'turn-a' };
  }

  stop() {}
}

class FailingAdapter extends EventEmitter {
  constructor(message) {
    super();
    this.message = message;
  }

  async ensureStarted() {
    throw new Error(this.message);
  }

  stop() {}
}

class DeferredAdapter extends EventEmitter {
  constructor() {
    super();
    this.stopped = false;
    this.capabilities = ['turn.stream.v1'];
    this.protocolVersion = 1;
    this.started = new Promise((resolve) => { this.signalStarted = resolve; });
    this.ready = new Promise((resolve) => { this.finish = resolve; });
  }

  async ensureStarted() {
    this.signalStarted();
    await this.ready;
  }

  stop() {
    this.stopped = true;
  }
}

function fakeAdapterFactory() {
  return new FakeAdapter('thread-a');
}

function target(id, adapterId, executionHost, priority) {
  return {
    id,
    adapterId,
    runtimeId: adapterId.split('-')[0],
    displayName: adapterId.startsWith('pi') ? 'Pi' : 'Codex',
    protocolName: adapterId.startsWith('pi') ? 'RPC' : 'app-server',
    classification: 'native',
    priority,
    capabilities: [],
    capabilityHints: ['turn.stream.v1'],
    minimumProtocolVersion: 1,
    executableName: adapterId.startsWith('pi') ? 'pi' : 'codex',
    executablePath: adapterId.startsWith('pi') ? '/home/user/pi' : '/home/user/codex',
    executionHost,
    status: 'detected',
  };
}
