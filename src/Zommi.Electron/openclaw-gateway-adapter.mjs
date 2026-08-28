import { execFile as nodeExecFile, spawn as nodeSpawn } from 'node:child_process';
import { EventEmitter } from 'node:events';
import { promisify } from 'node:util';
import {
  GatewayClient,
  GatewaySessionMessageSubscriptionCoordinator,
  createSessionProjection,
  reduceSessionProjectionRunEvent,
} from '@openclaw/gateway-client';
import {
  ApprovalResolveParamsSchema,
  ChatEventSchema,
  PROTOCOL_VERSION,
  QuestionResolveParamsSchema,
  validateChatAbortParams,
  validateChatHistoryParams,
  validateChatSendParams,
  validateModelsListParams,
  validateSessionsCreateParams,
  validateSessionsListParams,
} from '@openclaw/gateway-protocol';
import { Value } from 'typebox/value';
import { buildContextHandoff } from './context-handoff.mjs';
import { recordNativeDiagnostic } from './adapter-diagnostics.mjs';
import { emitProtocolWrite } from './transport-metrics.mjs';
import { ambiguousOutcome, normalizeClientOperationId, sanitizeDiagnostic } from './broker-protocol.mjs';

const DEFAULT_REQUEST_TIMEOUT_MS = 30_000;
const DEFAULT_LIFECYCLE_TIMEOUT_MS = 15_000;
const execFileAsync = promisify(nodeExecFile);

export class OpenClawGatewayAdapter extends EventEmitter {
  constructor(options = {}) {
    super();
    this.env = options.env || process.env;
    this.explicitUrl = options.url || this.env.OPENCLAW_GATEWAY_URL || null;
    this.url = this.explicitUrl || 'ws://127.0.0.1:18789';
    this.token = options.token ?? this.env.OPENCLAW_GATEWAY_TOKEN;
    this.password = options.password ?? this.env.OPENCLAW_GATEWAY_PASSWORD;
    this.command = options.command || null;
    this.commandArgs = options.commandArgs || [];
    this.execFile = options.execFile || defaultExecFile;
    this.spawnProcess = options.spawnProcess || nodeSpawn;
    this.lifecycleTimeoutMs = options.lifecycleTimeoutMs || DEFAULT_LIFECYCLE_TIMEOUT_MS;
    this.manageLocalLifecycle = options.manageLocalLifecycle ?? Boolean(this.command && !this.explicitUrl);
    this.lifecycleProcess = null;
    this.foregroundGatewayStarted = false;
    this.lifecycleStderr = '';
    this.preferredSessionId = options.preferredSessionId || null;
    this.GatewayClientClass = options.GatewayClientClass || GatewayClient;
    this.requestTimeoutMs = options.requestTimeoutMs || DEFAULT_REQUEST_TIMEOUT_MS;
    this.client = null;
    this.startPromise = null;
    this.hello = null;
    this.helloWaiter = null;
    this.connectedOnce = false;
    this.stopping = false;
    this.sessions = [];
    this.models = [];
    this.activeSessionId = null;
    this.activeTurns = new Map();
    this.turnClientOperations = new Map();
    this.runSequences = new Map();
    this.terminalRuns = new Set();
    this.streamedText = new Map();
    this.histories = new Map();
    this.projections = new Map();
    this.pendingApprovals = new Map();
    this.pendingQuestions = new Map();
    this.pendingRequests = new Set();
    this.protocolVersion = null;
    this.runtimeVersion = null;
    this.subscriptionCoordinator = null;
    this.subscription = null;
    this.capabilities = [
      'session.list.v1', 'session.create.v1', 'session.resume.v1', 'history.read.v1',
      'turn.stream.v1', 'turn.interrupt.v1', 'input.image.v1', 'model.select.v1',
      'approval.resolve.v1', 'question.resolve.v1', 'operation.idempotency.v1',
    ];
  }

  ensureStarted() {
    this.startPromise ??= this.#start().catch((error) => {
      this.startPromise = null;
      this.stop();
      throw error;
    });
    return this.startPromise;
  }

  async getChatState() {
    await this.ensureStarted();
    await this.#refreshSessions();
    return this.#chatState();
  }

  async probeTransportWrite(options = {}) {
    await this.ensureStarted();
    await this.#request('sessions.list', { limit: 1 }, options);
    return { ok: true };
  }

  async createSession(options = {}) {
    await this.ensureStarted();
    await this.#createNewSession(options);
    await this.#refreshSessions();
    return this.#chatState();
  }

  async #createNewSession(options = {}) {
    const model = this.#selectedModel(options.model);
    const params = {
      label: 'Zommi chat',
      ...(model ? { model: model.rawModelId } : {}),
      ...(options.effort ? { thinkingLevel: options.effort } : {}),
    };
    requireValid(validateSessionsCreateParams, params, 'sessions.create');
    const result = await this.#request('sessions.create', params);
    if (!result?.ok || !result?.key) throw new Error('OpenClaw Gateway returned an invalid session creation result.');
    await this.#bindSession(String(result.key));
  }

  async switchSession(sessionId) {
    await this.ensureStarted();
    const id = String(sessionId || '');
    if (!this.sessions.some((session) => session.id === id)) {
      throw new Error(`OpenClaw session '${id}' was not returned by this Gateway.`);
    }
    await this.#bindSession(id);
    return this.#chatState();
  }

  async startTurn(message, snapshots = [], images = [], options = {}) {
    await this.ensureStarted();
    const sessionKey = this.activeSessionId;
    if (!sessionKey) throw new Error('OpenClaw Gateway has no active session.');
    if (this.activeTurns.has(sessionKey)) throw new Error('This OpenClaw session already has an active turn.');
    const model = this.#selectedModel(options.model);
    const clientOperationId = normalizeClientOperationId(options.clientOperationId);
    const idempotencyKey = clientOperationId;
    const params = {
      sessionKey,
      message: buildContextHandoff(message, snapshots, images.length),
      idempotencyKey,
      ...(options.effort ? { thinking: options.effort } : {}),
      ...(images.length ? { attachments: images.map(openClawAttachment) } : {}),
      ...(model ? { model: model.rawModelId } : {}),
    };
    // Current chat.send does not accept a model field; session creation owns
    // the durable model choice. Drop it only after using the model to detect a
    // requested change, and refuse silent cross-model sends.
    if (model && model.id !== this.#activeModelId()) {
      throw new Error('OpenClaw changes models when a session is created. Start a new chat with the selected model.');
    }
    delete params.model;
    requireValid(validateChatSendParams, params, 'chat.send');
    let result;
    try {
      result = await this.#request('chat.send', params, { clientOperationId, transport: options.transport });
    } catch (error) {
      if (/timed? out|timeout/i.test(String(error?.message || error))) {
        throw ambiguousOutcome(error, 'OpenClaw Gateway');
      }
      throw error;
    }
    const runId = String(result?.runId || '');
    if (!runId || !['started', 'queued', 'steered', 'accepted'].includes(String(result?.status || 'started'))) {
      throw new Error(`OpenClaw did not acknowledge the run (${result?.status || 'missing run id'}).`);
    }
    this.activeTurns.set(sessionKey, runId);
    this.turnClientOperations.set(sessionKey, clientOperationId);
    this.streamedText.set(runId, '');
    return { accepted: true, threadId: sessionKey, turnId: runId, clientOperationId, sessionMetadata: { sessionKey } };
  }

  async interruptTurn() {
    await this.ensureStarted();
    const sessionKey = this.activeSessionId;
    const runId = this.activeTurns.get(sessionKey);
    if (!sessionKey || !runId) throw new Error('There is no active OpenClaw run to stop.');
    const params = { sessionKey, runId };
    requireValid(validateChatAbortParams, params, 'chat.abort');
    await this.#request('chat.abort', params);
    return {
      interrupted: true,
      threadId: sessionKey,
      turnId: runId,
      clientOperationId: this.turnClientOperations.get(sessionKey) || null,
    };
  }

  async resolveApproval(approvalId, optionId = null) {
    const approval = this.pendingApprovals.get(String(approvalId));
    if (!approval) throw new Error(`Unknown OpenClaw approval '${approvalId}'.`);
    const params = {
      id: String(approvalId),
      kind: approval.kind,
      decision: optionId === 'allow-always' ? 'allow-always' : optionId === 'allow-once' ? 'allow-once' : 'deny',
    };
    requireSchema(ApprovalResolveParamsSchema, params, 'approval.resolve');
    const result = await this.#request('approval.resolve', params);
    this.pendingApprovals.delete(String(approvalId));
    return { resolved: true, approvalId: String(approvalId), result };
  }

  async resolveQuestion(questionId, answer = {}) {
    const question = this.pendingQuestions.get(String(questionId));
    if (!question) throw new Error(`Unknown OpenClaw question '${questionId}'.`);
    const answers = answer.answers && typeof answer.answers === 'object'
      ? answer.answers
      : { [question.questions[0]?.questionId || 'answer']: [String(answer.value || '')] };
    const params = Object.keys(answer).length
      ? { id: String(questionId), answers: { answers }, resolvedBy: 'zommi' }
      : { id: String(questionId), cancel: true, resolvedBy: 'zommi' };
    requireSchema(QuestionResolveParamsSchema, params, 'question.resolve');
    const result = await this.#request('question.resolve', params);
    this.pendingQuestions.delete(String(questionId));
    return { resolved: true, questionId: String(questionId), result };
  }

  stop() {
    this.stopping = true;
    this.#rejectPendingRequests(new Error('OpenClaw Gateway stopped.'));
    this.startPromise = null;
    this.subscriptionCoordinator?.reset();
    this.subscriptionCoordinator = null;
    this.subscription = null;
    this.client?.stop?.();
    this.client = null;
    if (this.lifecycleProcess && !this.lifecycleProcess.killed) this.lifecycleProcess.kill();
    this.lifecycleProcess = null;
    this.foregroundGatewayStarted = false;
    this.hello = null;
    this.helloWaiter?.reject(new Error('OpenClaw Gateway stopped before handshake completion.'));
    this.helloWaiter = null;
    this.pendingApprovals.clear();
    this.pendingQuestions.clear();
    this.activeTurns.clear();
    this.turnClientOperations.clear();
    this.runSequences.clear();
    this.terminalRuns.clear();
  }

  async #start() {
    this.stopping = false;
    if (this.manageLocalLifecycle) await this.#ensureLocalGateway();
    this.emit('status', 'Connecting to OpenClaw Gateway…');
    const hello = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.helloWaiter = null;
        reject(new Error(`OpenClaw Gateway did not complete its challenge handshake within ${Math.ceil(this.requestTimeoutMs / 1000)} seconds.`));
      }, this.requestTimeoutMs);
      this.helloWaiter = {
        resolve: (value) => { clearTimeout(timer); this.helloWaiter = null; resolve(value); },
        reject: (error) => { clearTimeout(timer); this.helloWaiter = null; reject(error); },
      };
    });
    this.client = new this.GatewayClientClass({
      url: this.url,
      token: this.token,
      password: this.password,
      env: this.env,
      minProtocol: PROTOCOL_VERSION,
      maxProtocol: PROTOCOL_VERSION,
      clientName: 'cli',
      clientDisplayName: 'Zommi',
      clientVersion: '0.2.0',
      platform: process.platform,
      mode: 'cli',
      role: 'operator',
      scopes: ['operator.read', 'operator.write', 'operator.approvals', 'operator.questions'],
      caps: ['approvals', 'tool-events', 'session-scoped-events'],
      deviceIdentity: null,
      requestTimeoutMs: this.requestTimeoutMs,
      onHelloOk: (value) => this.#handleHello(value),
      onConnectError: (error) => this.helloWaiter?.reject(normalizeConnectError(error)),
      onReconnectPaused: (info) => this.#handleReconnectPaused(info),
      onClose: (_code, reason) => {
        if (!this.stopping) this.emit('status', sanitizeDiagnostic(`OpenClaw Gateway disconnected${reason ? `: ${reason}` : ''}`));
      },
      onGap: (info) => this.#handleGap(info),
      onEvent: (event) => this.#handleEvent(event),
    });
    this.client.start();
    await hello;
    this.subscriptionCoordinator = new GatewaySessionMessageSubscriptionCoordinator(this.client);
    await Promise.all([this.#refreshSessions(), this.#refreshModels()]);
    if (this.preferredSessionId && this.sessions.some((session) => session.id === this.preferredSessionId)) {
      await this.#bindSession(this.preferredSessionId);
    } else {
      await this.#createNewSession();
      await this.#refreshSessions();
      if (!this.activeSessionId) throw new Error('OpenClaw Gateway could not create a fresh session.');
    }
    this.emit('status', `OpenClaw Gateway ready · ${this.activeSessionId.slice(0, 16)}`);
  }

  #handleHello(hello) {
    this.hello = hello;
    this.protocolVersion = Number(hello?.protocol || hello?.protocolVersion || PROTOCOL_VERSION);
    this.runtimeVersion = hello?.server?.version ? String(hello.server.version) : null;
    if (this.protocolVersion !== PROTOCOL_VERSION) {
      this.hello = null;
      this.helloWaiter?.reject(new Error(`Unsupported OpenClaw Gateway protocol version ${this.protocolVersion}.`));
      return;
    }
    this.#negotiateCapabilities(hello?.features?.methods || []);
    this.helloWaiter?.resolve(hello);
    if (this.connectedOnce && this.activeSessionId) void this.#recoverAfterReconnect();
    this.connectedOnce = true;
  }

  #handleReconnectPaused(info = {}) {
    if (this.stopping) return;
    const reason = sanitizeDiagnostic(info.reason || info.detailCode || 'reconnect policy stopped retrying');
    const error = `OpenClaw Gateway disconnected permanently: ${reason}; active run outcome is unknown.`;
    this.emit('status', `OpenClaw reconnect paused: ${reason}`);
    for (const [threadId, turnId] of this.activeTurns) {
      const clientOperationId = this.turnClientOperations.get(threadId) || null;
      this.#markTerminalRun(threadId, turnId);
      this.emit('turnCompleted', { threadId, turnId, clientOperationId, status: 'unknown', error });
    }
    this.activeTurns.clear();
    this.turnClientOperations.clear();
    this.streamedText.clear();
    this.pendingApprovals.clear();
    this.pendingQuestions.clear();
    this.#rejectPendingRequests(new Error(error));
    this.subscriptionCoordinator?.reset();
    this.subscriptionCoordinator = null;
    this.subscription = null;
    this.hello = null;
    this.helloWaiter?.reject(new Error(`OpenClaw Gateway reconnect paused: ${reason}`));
    this.helloWaiter = null;
    this.client?.stop?.();
    this.client = null;
    if (this.lifecycleProcess && !this.lifecycleProcess.killed) this.lifecycleProcess.kill();
    this.lifecycleProcess = null;
    this.foregroundGatewayStarted = false;
    this.startPromise = null;
    this.connectedOnce = false;
  }

  async #ensureLocalGateway() {
    let status = await this.#readGatewayStatus();
    if (status?.rpc?.ok === true) {
      this.#applyGatewayStatus(status);
      return;
    }
    const serviceInstalled = Boolean(status?.service?.command || status?.service?.loadState?.status === 'loaded');
    if (serviceInstalled) {
      this.emit('status', 'Starting the runtime-owned OpenClaw Gateway service…');
      await this.#execCli(['gateway', 'start', '--json']);
    } else {
      this.emit('status', 'Starting a local OpenClaw Gateway…');
      this.#startForegroundGateway();
    }
    const deadline = Date.now() + this.lifecycleTimeoutMs;
    do {
      await delay(250);
      status = await this.#readGatewayStatus();
      if (status?.rpc?.ok === true) {
        this.#applyGatewayStatus(status);
        return;
      }
      if (this.foregroundGatewayStarted && !this.lifecycleProcess) break;
      if (this.lifecycleProcess?.exitCode !== null && this.lifecycleProcess?.exitCode !== undefined) break;
    } while (Date.now() < deadline);
    const detail = sanitizeDiagnostic(
      status?.rpc?.error || this.lifecycleStderr || 'the official RPC health probe did not become ready',
    );
    throw new Error(`OpenClaw Gateway could not be started: ${detail}`);
  }

  async #readGatewayStatus() {
    try {
      const result = await this.#execCli([
        'gateway', 'status', '--json', '--require-rpc', '--timeout',
        String(Math.min(5_000, this.lifecycleTimeoutMs)),
      ]);
      return parseOpenClawGatewayStatus(result.stdout);
    } catch (error) {
      return parseOpenClawGatewayStatus(error?.stdout) || {
        service: { loadState: { status: 'unknown' } },
        rpc: { ok: false, error: sanitizeDiagnostic(error) },
      };
    }
  }

  #applyGatewayStatus(status) {
    const url = status?.rpc?.url || status?.gateway?.probeUrl;
    if (url) this.url = String(url);
    const version = status?.rpc?.server?.version || status?.rpc?.version || status?.gateway?.version;
    if (version) this.runtimeVersion = String(version);
  }

  #startForegroundGateway() {
    const child = this.spawnProcess(this.command, [...this.commandArgs, 'gateway', 'run'], {
      stdio: ['ignore', 'ignore', 'pipe'],
      env: this.env,
      windowsHide: true,
    });
    this.lifecycleProcess = child;
    this.foregroundGatewayStarted = true;
    child.stderr?.setEncoding?.('utf8');
    child.stderr?.on?.('data', (chunk) => {
      this.lifecycleStderr = `${this.lifecycleStderr}${String(chunk)}`.slice(-8_000);
    });
    child.once?.('exit', (code) => {
      if (this.lifecycleProcess !== child) return;
      this.lifecycleProcess = null;
      if (!this.stopping) this.#handleReconnectPaused({ reason: `local Gateway exited with code ${code}` });
    });
  }

  #execCli(args) {
    if (!this.command) return Promise.reject(new Error('OpenClaw CLI launch command is missing.'));
    return this.execFile(this.command, [...this.commandArgs, ...args], {
      env: this.env,
      timeout: this.lifecycleTimeoutMs,
      windowsHide: true,
      maxBuffer: 2 * 1024 * 1024,
    });
  }

  #negotiateCapabilities(methods) {
    const available = new Set(methods);
    const mapping = new Map([
      ['session.list.v1', 'sessions.list'], ['session.create.v1', 'sessions.create'],
      ['session.resume.v1', 'chat.history'], ['history.read.v1', 'chat.history'],
      ['turn.stream.v1', 'chat.send'], ['turn.interrupt.v1', 'chat.abort'],
      ['model.select.v1', 'models.list'], ['approval.resolve.v1', 'approval.resolve'],
      ['question.resolve.v1', 'question.resolve'],
    ]);
    if (available.size) this.capabilities = this.capabilities.filter((capability) => !mapping.has(capability) || available.has(mapping.get(capability)));
    for (const required of ['sessions.list', 'sessions.create', 'chat.history', 'chat.send']) {
      if (available.size && !available.has(required)) throw new Error(`OpenClaw Gateway does not advertise required method '${required}'.`);
    }
  }

  async #recoverAfterReconnect() {
    try {
      this.subscriptionCoordinator?.reset();
      this.subscriptionCoordinator = new GatewaySessionMessageSubscriptionCoordinator(this.client);
      await Promise.all([this.#loadHistory(this.activeSessionId), this.#refreshSessions()]);
      await this.#subscribe(this.activeSessionId);
      const activeRunId = this.activeTurns.get(this.activeSessionId);
      const session = this.sessions.find((candidate) => candidate.id === this.activeSessionId);
      if (activeRunId && session?.status !== 'running') {
        const messages = this.histories.get(this.activeSessionId) || [];
        const last = messages.at(-1);
        const status = String(last?.role || '').toLowerCase() === 'assistant' ? 'completed' : 'unknown';
        this.emit('turnCompleted', {
          threadId: this.activeSessionId,
          turnId: activeRunId,
          clientOperationId: this.turnClientOperations.get(this.activeSessionId) || null,
          status,
        });
        this.#markTerminalRun(this.activeSessionId, activeRunId);
        this.activeTurns.delete(this.activeSessionId);
        this.turnClientOperations.delete(this.activeSessionId);
      }
      this.emit('status', 'OpenClaw Gateway reconnected to the exact session');
    } catch (error) {
      this.emit('status', `OpenClaw reconnect recovery failed: ${sanitizeDiagnostic(error)}`);
    }
  }

  async #handleGap(info) {
    this.emit('status', `OpenClaw event gap detected (${info.expected} → ${info.received}); refreshing exact session`);
    if (this.activeSessionId) await this.#loadHistory(this.activeSessionId).catch((error) => this.emit('status', `OpenClaw history refresh failed: ${sanitizeDiagnostic(error)}`));
  }

  #handleEvent(frame) {
    const name = String(frame?.event || '');
    const payload = frame?.payload;
    if (name === 'chat') {
      if (!Value.Check(ChatEventSchema, payload)) {
        this.emit('status', 'OpenClaw Gateway emitted an invalid chat event.');
        recordNativeDiagnostic(this, 'OpenClaw Gateway', 'invalid chat', payload);
        return;
      }
      this.#handleChatEvent(payload);
      return;
    }
    if (name === 'question.requested') {
      this.#handleQuestion(payload);
      return;
    }
    if (['exec.approval.requested', 'plugin.approval.requested', 'openclaw.approval.requested'].includes(name)) {
      this.#handleApproval(name, payload);
      return;
    }
    if (name === 'session.tool') this.#handleToolEvent(payload);
    else recordNativeDiagnostic(this, 'OpenClaw Gateway', name, payload);
  }

  #handleChatEvent(event) {
    const sessionKey = String(event.sessionKey);
    const runId = String(event.runId);
    const eventSequence = Number(event.seq);
    const sequenceKey = `${sessionKey}:${runId}`;
    if (Number.isSafeInteger(eventSequence)) {
      const previous = this.runSequences.get(sequenceKey);
      if (previous !== undefined && eventSequence <= previous) return;
      this.runSequences.set(sequenceKey, eventSequence);
      while (this.runSequences.size > 1_024) this.runSequences.delete(this.runSequences.keys().next().value);
    }
    if (this.terminalRuns.has(sequenceKey)) {
      this.emit('status', `OpenClaw ignored a late event for terminal run ${runId}.`);
      return;
    }
    const activeRunId = this.activeTurns.get(sessionKey);
    if (activeRunId && activeRunId !== runId) {
      this.emit('status', `OpenClaw ignored a late event for run ${runId}.`);
      return;
    }
    const projection = this.projections.get(sessionKey) || createSessionProjection({ sessionKey }, []);
    const transition = reduceSessionProjectionRunEvent(projection, event, { sessionKey });
    if (transition) this.projections.set(sessionKey, transition.projection);
    if (event.state === 'status') {
      this.emit('status', openClawPhaseLabel(event.phase));
      return;
    }
    if (event.state === 'delta') {
      this.activeTurns.set(sessionKey, runId);
      const text = String(event.deltaText || '');
      const clientOperationId = this.turnClientOperations.get(sessionKey) || null;
      this.streamedText.set(runId, event.replace ? text : `${this.streamedText.get(runId) || ''}${text}`);
      this.emit('streamUpdate', {
        threadId: sessionKey,
        turnId: runId,
        clientOperationId,
        kind: 'assistant',
        lifecycle: 'delta',
        text,
        replace: Boolean(event.replace),
      });
      return;
    }
    if (!this.activeTurns.has(sessionKey)) return;
    const clientOperationId = this.turnClientOperations.get(sessionKey) || null;
    const finalText = openClawMessageText(event.message);
    const streamed = this.streamedText.get(runId) || '';
    if (finalText && !streamed) {
      this.emit('streamUpdate', { threadId: sessionKey, turnId: runId, clientOperationId, kind: 'assistant', lifecycle: 'completed', text: finalText });
    } else if (finalText.startsWith(streamed) && finalText.length > streamed.length) {
      this.emit('streamUpdate', { threadId: sessionKey, turnId: runId, clientOperationId, kind: 'assistant', lifecycle: 'completed', text: finalText.slice(streamed.length) });
    }
    this.activeTurns.delete(sessionKey);
    this.turnClientOperations.delete(sessionKey);
    this.streamedText.delete(runId);
    this.#markTerminalRun(sessionKey, runId);
    this.emit('turnCompleted', {
      threadId: sessionKey,
      turnId: runId,
      clientOperationId,
      status: event.state === 'final' ? 'completed' : event.state === 'aborted' ? 'interrupted' : 'failed',
      ...(event.errorMessage ? { error: String(event.errorMessage) } : {}),
    });
  }

  #handleToolEvent(payload) {
    if (!payload || typeof payload !== 'object') return;
    const sessionKey = String(payload.sessionKey || '');
    if (!sessionKey) return;
    const turnId = this.activeTurns.get(sessionKey) || null;
    this.emit('streamUpdate', {
      threadId: sessionKey,
      turnId,
      clientOperationId: this.turnClientOperations.get(sessionKey) || null,
      kind: 'tool',
      lifecycle: payload.state === 'completed' || payload.state === 'error' ? 'completed' : payload.state === 'started' ? 'started' : 'delta',
      itemId: String(payload.toolCallId || payload.id || payload.name || 'tool'),
      title: String(payload.name || 'Tool'),
      text: openClawMessageText(payload.result || payload.message || payload),
    });
  }

  #handleApproval(eventName, payload) {
    if (!payload || typeof payload !== 'object' || !payload.id) return;
    const kind = eventName.startsWith('exec.') ? 'exec' : eventName.startsWith('plugin.') ? 'plugin' : 'system-agent';
    const id = String(payload.id);
    this.pendingApprovals.set(id, { kind });
    this.emit('approvalRequested', {
      approvalId: id,
      threadId: payload.sessionKey || this.activeSessionId,
      options: [
        { optionId: 'allow-once', name: 'Allow once', kind: 'allow_once' },
        { optionId: 'allow-always', name: 'Always allow', kind: 'allow_always' },
        { optionId: 'deny', name: 'Deny', kind: 'reject' },
      ],
      toolCall: { title: approvalTitle(payload), rawInput: payload.presentation || payload },
    });
  }

  #handleQuestion(payload) {
    if (!payload || typeof payload !== 'object' || !payload.id || !Array.isArray(payload.questions)) return;
    const id = String(payload.id);
    this.pendingQuestions.set(id, { questions: payload.questions });
    this.emit('questionRequested', {
      questionId: id,
      threadId: payload.sessionKey || this.activeSessionId,
      title: 'OpenClaw needs your input',
      questions: payload.questions.map((question) => ({
        questionId: question.questionId,
        header: question.header,
        question: question.question,
        options: question.options || [],
        multiSelect: Boolean(question.multiSelect),
        isOther: Boolean(question.isOther),
        isSecret: Boolean(question.isSecret),
      })),
    });
  }

  async #refreshSessions() {
    const params = { limit: 200, includeDerivedTitles: true, includeLastMessage: true, boardFace: 'chat' };
    requireValid(validateSessionsListParams, params, 'sessions.list');
    const result = await this.#request('sessions.list', params);
    this.sessions = (result?.sessions || []).map((session) => ({
      id: String(session.key),
      name: session.displayName || session.derivedTitle || session.label || null,
      preview: session.lastMessagePreview || session.derivedTitle || session.label || 'OpenClaw session',
      updatedAt: Number(session.updatedAt || session.lastActivityAt || 0),
      model: session.model || null,
      modelProvider: session.modelProvider || null,
      status: session.status || null,
      lastRunId: session.lastRunId || null,
    })).filter((session) => session.id);
    if (this.activeSessionId && !this.sessions.some((session) => session.id === this.activeSessionId)) {
      this.sessions.unshift({ id: this.activeSessionId, preview: 'New OpenClaw chat', updatedAt: Date.now() });
    }
  }

  async #refreshModels() {
    const params = { view: 'configured', includeProviderCapabilities: true };
    requireValid(validateModelsListParams, params, 'models.list');
    try {
      const result = await this.#request('models.list', params);
      this.models = openClawModelsForRenderer(result?.models || []);
    } catch (error) {
      this.models = [];
      this.capabilities = this.capabilities.filter((capability) => capability !== 'model.select.v1');
      this.emit('status', `OpenClaw model inventory unavailable: ${sanitizeDiagnostic(error)}`);
    }
  }

  async #bindSession(sessionKey) {
    await this.#loadHistory(sessionKey);
    this.activeSessionId = sessionKey;
    this.preferredSessionId = sessionKey;
    const row = this.sessions.find((session) => session.id === sessionKey);
    if (row?.status === 'running' && row.lastRunId) this.activeTurns.set(sessionKey, row.lastRunId);
    await this.#subscribe(sessionKey);
  }

  async #loadHistory(sessionKey) {
    const params = { sessionKey, limit: 200, maxChars: 500_000 };
    requireValid(validateChatHistoryParams, params, 'chat.history');
    const result = await this.#request('chat.history', params);
    const messages = Array.isArray(result?.messages) ? result.messages : [];
    this.histories.set(sessionKey, messages);
    this.projections.set(sessionKey, createSessionProjection({ sessionKey }, messages));
  }

  async #subscribe(sessionKey) {
    if (!this.subscriptionCoordinator) return;
    if (this.subscription) await this.subscriptionCoordinator.release(this.subscription).catch(() => {});
    this.subscription = await this.subscriptionCoordinator.acquire(sessionKey, { includeApprovals: true });
  }

  #selectedModel(modelId) {
    return this.models.find((model) => model.id === modelId || model.model === modelId) || null;
  }

  #activeModelId() {
    const session = this.sessions.find((item) => item.id === this.activeSessionId);
    return session?.model ? encodeModelId(session.modelProvider, session.model) : '';
  }

  #chatState() {
    const session = this.sessions.find((item) => item.id === this.activeSessionId);
    return {
      activeThreadId: this.activeSessionId || '',
      activeModel: this.#activeModelId() || null,
      activeEffort: null,
      models: this.models.map((model) => ({ ...model })),
      sessions: this.sessions.map((item) => ({ ...item })),
      activeTurns: [...this.activeTurns].map(([threadId, turnId]) => ({ threadId, turnId })),
      thread: { id: this.activeSessionId || '', turns: openClawMessagesToTurns(this.histories.get(this.activeSessionId) || []) },
      sessionMetadata: this.activeSessionId ? { sessionKey: this.activeSessionId } : null,
      session,
    };
  }

  #request(method, params, metric = null) {
    if (!this.client || !this.hello) return Promise.reject(new Error('OpenClaw Gateway is not connected.'));
    const client = this.client;
    return new Promise((resolve, reject) => {
      const call = { reject };
      this.pendingRequests.add(call);
      Promise.resolve().then(() => {
        if (metric) emitProtocolWrite(this, method, metric.clientOperationId, metric.transport);
        return client.request(method, params, { timeoutMs: this.requestTimeoutMs });
      }).then(
        (value) => {
          if (!this.pendingRequests.delete(call)) return;
          resolve(value);
        },
        (error) => {
          if (!this.pendingRequests.delete(call)) return;
          reject(error);
        },
      );
    });
  }

  #rejectPendingRequests(error) {
    for (const call of this.pendingRequests) {
      if (call.timer) clearTimeout(call.timer);
      call.reject(error);
    }
    this.pendingRequests.clear();
  }

  #markTerminalRun(sessionKey, runId) {
    this.terminalRuns.add(`${sessionKey}:${runId}`);
    while (this.terminalRuns.size > 1_024) this.terminalRuns.delete(this.terminalRuns.values().next().value);
  }
}

export function openClawModelsForRenderer(models = []) {
  return models.map((model) => {
    const provider = String(model.provider || '');
    const rawModelId = String(model.id || model.model || '');
    const id = encodeModelId(provider, rawModelId);
    const supportsReasoning = model.capabilities?.supportsReasoning ?? model.capabilities?.supports_reasoning ?? true;
    return {
      id, model: id, provider, rawModelId,
      displayName: String(model.name || rawModelId),
      hidden: false,
      supportedReasoningEfforts: supportsReasoning
        ? ['off', 'low', 'medium', 'high'].map((reasoningEffort) => ({ reasoningEffort }))
        : [],
      defaultReasoningEffort: 'medium',
    };
  }).filter((model) => model.rawModelId);
}

export function openClawMessagesToTurns(messages = []) {
  const turns = [];
  let current = null;
  for (let index = 0; index < messages.length; index += 1) {
    const message = messages[index] || {};
    const role = String(message.role || message.identity?.role || '').toLowerCase();
    const text = openClawMessageText(message);
    if (role === 'user') {
      current = { id: `openclaw-turn-${index}`, items: [{ id: `openclaw-user-${index}`, type: 'userMessage', content: [{ type: 'text', text }] }] };
      turns.push(current);
      continue;
    }
    current ||= { id: `openclaw-turn-${index}`, items: [] };
    if (!turns.includes(current)) turns.push(current);
    if (role === 'assistant') {
      if (message.reasoning) current.items.push({ id: `openclaw-thinking-${index}`, type: 'reasoning', status: 'completed', summary: [String(message.reasoning)], content: [] });
      if (text) current.items.push({ id: `openclaw-agent-${index}`, type: 'agentMessage', phase: 'final', status: 'completed', text });
    } else if (text) {
      current.items.push({ id: `openclaw-tool-${index}`, type: 'commandExecution', status: 'completed', title: message.name || 'Tool', text });
    }
  }
  return turns;
}

function requireValid(validator, value, label) {
  if (!validator(value)) throw new Error(`Zommi produced invalid OpenClaw ${label} parameters.`);
}

function requireSchema(schema, value, label) {
  if (!Value.Check(schema, value)) throw new Error(`Zommi produced invalid OpenClaw ${label} parameters.`);
}

function encodeModelId(provider, model) {
  return provider && model ? `${provider}::${model}` : String(model || '');
}

function openClawAttachment(dataUrl, index) {
  const match = /^data:([^;,]+);base64,([a-z0-9+/=\s]+)$/i.exec(String(dataUrl || ''));
  if (!match) throw new Error('OpenClaw Gateway accepts only base64 data URL attachments.');
  const content = match[2].replace(/\s+/g, '');
  return {
    type: 'image', mimeType: match[1], fileName: `zommi-${(index ?? 0) + 1}.${mimeExtension(match[1])}`,
    content, sizeBytes: Buffer.from(content, 'base64').byteLength,
  };
}

function mimeExtension(mime) {
  const subtype = String(mime).split('/')[1]?.toLowerCase() || 'bin';
  return subtype === 'jpeg' ? 'jpg' : subtype.replace(/[^a-z0-9]/g, '') || 'bin';
}

function openClawMessageText(value) {
  if (typeof value === 'string') return value;
  if (!value || typeof value !== 'object') return '';
  if (typeof value.text === 'string') return value.text;
  if (typeof value.content === 'string') return value.content;
  if (Array.isArray(value.content)) return value.content.map((part) => typeof part === 'string' ? part : part?.text || '').filter(Boolean).join('\n');
  return '';
}

function openClawPhaseLabel(phase) {
  return ({ preparing_workspace: 'Preparing workspace…', provisioning_environment: 'Provisioning environment…', preparing_context: 'Preparing context…', starting_model: 'Starting model…' })[phase] || 'OpenClaw is working…';
}

function approvalTitle(payload) {
  const presentation = payload.presentation || {};
  return String(presentation.title || presentation.command || payload.title || payload.description || 'OpenClaw requests approval');
}

function normalizeConnectError(error) {
  const message = sanitizeDiagnostic(error);
  if (/auth|token|password|unauthorized|forbidden/i.test(message)) {
    return new Error(`OpenClaw Gateway sign-in required. Run openclaw onboard in this Execution Host, then refresh Zommi. (${message})`);
  }
  return error instanceof Error ? error : new Error(message);
}

export function parseOpenClawGatewayStatus(output) {
  const text = String(output || '').trim();
  if (!text) return null;
  try {
    const value = JSON.parse(text);
    return value && typeof value === 'object' && !Array.isArray(value) ? value : null;
  } catch {
    return null;
  }
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function defaultExecFile(command, args, options) {
  return execFileAsync(command, args, { encoding: 'utf8', ...options });
}
