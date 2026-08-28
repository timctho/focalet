import { randomBytes, randomUUID } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { spawn } from 'node:child_process';
import { homedir } from 'node:os';
import { buildContextHandoff } from './context-handoff.mjs';
import { ambiguousOutcome, normalizeClientOperationId, sanitizeDiagnostic } from './broker-protocol.mjs';
import { recordNativeDiagnostic } from './adapter-diagnostics.mjs';
import { emitProtocolWrite } from './transport-metrics.mjs';

const DEFAULT_REQUEST_TIMEOUT_MS = 30_000;
const DEFAULT_STARTUP_TIMEOUT_MS = 45_000;
const MAX_FRAME_BYTES = 16 * 1024 * 1024;
const REASONING_EFFORTS = ['none', 'low', 'medium', 'high', 'max'];

export class HermesGatewayAdapter extends EventEmitter {
  constructor(options = {}) {
    super();
    this.command = options.command;
    this.commandArgs = options.commandArgs || [];
    this.executionHost = options.executionHost || { kind: 'native' };
    this.cwd = options.cwd || homedir();
    this.preferredSessionId = options.preferredSessionId || null;
    this.spawnProcess = options.spawnProcess || spawn;
    this.fetchImpl = options.fetchImpl || globalThis.fetch;
    this.WebSocketImpl = options.WebSocketImpl || globalThis.WebSocket;
    this.processEnv = options.env || process.env;
    this.sessionToken = options.sessionToken || randomBytes(32).toString('base64url');
    this.requestTimeoutMs = options.requestTimeoutMs || DEFAULT_REQUEST_TIMEOUT_MS;
    this.startupTimeoutMs = options.startupTimeoutMs || DEFAULT_STARTUP_TIMEOUT_MS;
    this.process = null;
    this.socket = null;
    this.startPromise = null;
    this.pending = new Map();
    this.nextId = 0;
    this.stdoutBuffer = '';
    this.stderr = '';
    this.port = null;
    this.stopping = false;
    this.gatewayReady = false;
    this.gatewayReadyWaiter = null;
    this.runtimeSessionId = null;
    this.activeSessionId = null;
    this.sessions = [];
    this.messages = [];
    this.models = [];
    this.sessionInfo = {};
    this.runtimeSessionIds = new Map();
    this.activeTurns = new Map();
    this.turnClientOperations = new Map();
    this.streamedAssistant = new Map();
    this.pendingApprovals = new Map();
    this.pendingQuestions = new Map();
    this.protocolVersion = null;
    this.runtimeVersion = null;
    this.capabilities = [
      'session.list.v1', 'session.create.v1', 'session.resume.v1', 'history.read.v1',
      'turn.stream.v1', 'turn.interrupt.v1', 'input.image.v1', 'model.select.v1',
      'reasoning.select.v1', 'approval.resolve.v1', 'question.resolve.v1',
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
    await this.#request('session.list', {}, options);
    return { ok: true };
  }

  async createSession(options = {}) {
    await this.ensureStarted();
    await this.#createSession(options);
    await this.#refreshSessions();
    return this.#chatState();
  }

  async switchSession(sessionId) {
    await this.ensureStarted();
    const exact = this.sessions.find((session) => session.id === String(sessionId));
    if (!exact && ![...this.runtimeSessionIds.values()].includes(String(sessionId))) {
      throw new Error(`Hermes session '${sessionId}' was not returned by this Gateway.`);
    }
    await this.#resumeSession(String(sessionId));
    await this.#refreshModels();
    return this.#chatState();
  }

  async startTurn(message, snapshots = [], images = [], options = {}) {
    await this.ensureStarted();
    if (!this.runtimeSessionId || !this.activeSessionId) throw new Error('Hermes Gateway has no active session.');
    if (this.activeTurns.has(this.activeSessionId)) throw new Error('This Hermes session already has an active turn.');
    await this.#applyOptions(options);
    for (let index = 0; index < images.length; index += 1) {
      const image = parseImageDataUrl(images[index]);
      await this.#request('image.attach_bytes', {
        session_id: this.runtimeSessionId,
        content_base64: image.base64,
        filename: `zommi-${index + 1}.${image.extension}`,
      });
    }
    const turnId = randomUUID();
    const clientOperationId = normalizeClientOperationId(options.clientOperationId);
    this.activeTurns.set(this.activeSessionId, turnId);
    this.turnClientOperations.set(this.activeSessionId, clientOperationId);
    this.streamedAssistant.set(this.activeSessionId, '');
    this.messages.push({ role: 'user', text: String(message) });
    const metric = { clientOperationId, transport: options.transport };
    let metricWritten = false;
    try {
      const result = await this.#request('prompt.submit', {
        session_id: this.runtimeSessionId,
        text: buildContextHandoff(message, snapshots, images.length),
      }, metricWritten ? null : metric);
      metricWritten = true;
      if (!['streaming', 'queued', 'steered'].includes(String(result?.status || ''))) {
        throw new Error(`Hermes did not acknowledge the turn (${result?.status || 'unknown status'}).`);
      }
    } catch (error) {
      if (/timed? out|did not respond/i.test(String(error?.message || error))) {
        throw ambiguousOutcome(error, 'Hermes Gateway');
      }
      this.activeTurns.delete(this.activeSessionId);
      this.streamedAssistant.delete(this.activeSessionId);
      this.turnClientOperations.delete(this.activeSessionId);
      this.messages.pop();
      throw error;
    }
    return {
      accepted: true,
      threadId: this.activeSessionId,
      turnId,
      clientOperationId,
      sessionMetadata: { sessionKey: this.activeSessionId },
    };
  }

  async interruptTurn() {
    await this.ensureStarted();
    const sessionId = this.activeSessionId;
    const turnId = this.activeTurns.get(sessionId);
    if (!sessionId || !this.runtimeSessionId || !turnId) throw new Error('There is no active Hermes turn to stop.');
    await this.#request('session.interrupt', { session_id: this.runtimeSessionId });
    return {
      interrupted: true,
      threadId: sessionId,
      turnId,
      clientOperationId: this.turnClientOperations.get(sessionId) || null,
    };
  }

  async resolveApproval(approvalId, optionId = null) {
    const pending = this.pendingApprovals.get(String(approvalId));
    if (!pending) throw new Error(`Unknown Hermes approval '${approvalId}'.`);
    const decision = optionId && pending.choices.includes(String(optionId)) ? String(optionId) : 'deny';
    await this.#request('approval.respond', { request_id: pending.requestId, decision });
    this.pendingApprovals.delete(String(approvalId));
    return { resolved: true, approvalId: String(approvalId), decision };
  }

  async resolveQuestion(questionId, answer = {}) {
    const pending = this.pendingQuestions.get(String(questionId));
    if (!pending) throw new Error(`Unknown Hermes question '${questionId}'.`);
    const value = typeof answer.value === 'string' ? answer.value : '';
    const params = { request_id: pending.requestId };
    if (pending.kind === 'sudo') params.password = value;
    else if (pending.kind === 'secret') params.value = value;
    else params.answer = value;
    await this.#request(`${pending.kind}.respond`, params);
    this.pendingQuestions.delete(String(questionId));
    return { resolved: true, questionId: String(questionId) };
  }

  stop() {
    this.stopping = true;
    this.startPromise = null;
    this.#rejectPending(new Error('Hermes Gateway stopped.'));
    try { this.socket?.close(); } catch { /* best effort */ }
    if (this.process && !this.process.killed) this.process.kill();
    this.socket = null;
    this.process = null;
    this.gatewayReady = false;
    this.gatewayReadyWaiter?.reject(new Error('Hermes Gateway stopped before it became ready.'));
    this.gatewayReadyWaiter = null;
    this.pendingApprovals.clear();
    this.pendingQuestions.clear();
    this.activeTurns.clear();
    this.turnClientOperations.clear();
  }

  async #start() {
    if (!this.command) throw new Error('Hermes Gateway launch command is missing.');
    if (typeof this.fetchImpl !== 'function' || typeof this.WebSocketImpl !== 'function') {
      throw new Error('This Zommi build does not provide the HTTP and WebSocket APIs required by Hermes Gateway.');
    }
    this.stopping = false;
    this.emit('status', 'Starting Hermes Gateway…');
    const launch = buildHermesGatewayLaunch({
      args: this.commandArgs,
      executionHost: this.executionHost,
      sessionToken: this.sessionToken,
    });
    const child = this.spawnProcess(this.command, launch.args, {
      stdio: ['ignore', 'pipe', 'pipe'],
      cwd: this.executionHost.kind === 'wsl' ? undefined : this.cwd,
      env: { ...this.processEnv, ...launch.env },
      windowsHide: true,
    });
    this.process = child;
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => this.#handleProcessOutput(chunk));
    child.stderr.on('data', (chunk) => { this.stderr = (this.stderr + chunk).slice(-12_000); });
    child.once('exit', (code) => this.#handleProcessExit(child, code));
    const port = await this.#waitForBackendReady(child);
    const health = await this.#readHealth(port);
    if (!health?.ok) throw new Error('Hermes Gateway health check did not report ready.');
    if (health.auth_required) {
      throw new Error('Hermes Gateway unexpectedly required public-bind authentication; Zommi only connects to its isolated loopback server.');
    }
    this.runtimeVersion = health.version ? String(health.version) : null;
    await this.#connectWebSocket(port);
    this.protocolVersion = 1;
    await this.#refreshSessions();
    if (this.preferredSessionId && this.sessions.some((session) => session.id === this.preferredSessionId)) {
      await this.#resumeSession(this.preferredSessionId);
    } else {
      await this.#createSession();
    }
    await this.#refreshModels();
    this.emit('status', `Hermes Gateway ready · ${this.activeSessionId.slice(0, 8)}`);
  }

  #waitForBackendReady(child) {
    return new Promise((resolve, reject) => {
      let settled = false;
      const timer = setTimeout(() => finish(new Error(`Hermes Gateway did not announce readiness within ${Math.ceil(this.startupTimeoutMs / 1000)} seconds.`)), this.startupTimeoutMs);
      const finish = (error, port) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        child.off('error', onError);
        child.off('exit', onExit);
        this.off('backendReady', onReady);
        if (error) reject(error);
        else resolve(port);
      };
      const onReady = (port) => finish(null, port);
      const onError = (error) => finish(error);
      const onExit = (code) => finish(new Error(`Hermes Gateway exited with code ${code}.${this.stderr.trim() ? ` ${this.stderr.trim()}` : ''}`));
      this.on('backendReady', onReady);
      child.once('error', onError);
      child.once('exit', onExit);
    });
  }

  #handleProcessOutput(chunk) {
    this.stdoutBuffer += String(chunk);
    let newline;
    while ((newline = this.stdoutBuffer.indexOf('\n')) >= 0) {
      const line = this.stdoutBuffer.slice(0, newline).trim();
      this.stdoutBuffer = this.stdoutBuffer.slice(newline + 1);
      const match = /^HERMES_BACKEND_READY\s+port=(\d+)$/.exec(line);
      if (match) {
        this.port = Number(match[1]);
        this.emit('backendReady', this.port);
      }
    }
  }

  async #readHealth(port) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.requestTimeoutMs);
    try {
      const response = await this.fetchImpl(`http://127.0.0.1:${port}/api/health`, { signal: controller.signal });
      if (!response?.ok) throw new Error(`Hermes Gateway health check returned HTTP ${response?.status || 'error'}.`);
      return response.json();
    } finally {
      clearTimeout(timer);
    }
  }

  async #connectWebSocket(port) {
    this.gatewayReady = false;
    const socket = new this.WebSocketImpl(`ws://127.0.0.1:${port}/api/ws?token=${encodeURIComponent(this.sessionToken)}`);
    this.socket = socket;
    socket.addEventListener('message', (event) => this.#handleSocketMessage(event.data));
    socket.addEventListener('close', () => this.#handleSocketClose());
    const opened = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        cleanup();
        reject(new Error('Hermes Gateway WebSocket connection timed out.'));
      }, this.requestTimeoutMs);
      const cleanup = () => {
        clearTimeout(timer);
        socket.removeEventListener('open', onOpen);
        socket.removeEventListener('error', onError);
      };
      const onOpen = () => { cleanup(); resolve(); };
      const onError = () => { cleanup(); reject(new Error('Hermes Gateway WebSocket connection failed.')); };
      socket.addEventListener('open', onOpen, { once: true });
      socket.addEventListener('error', onError, { once: true });
    });
    const ready = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.gatewayReadyWaiter = null;
        reject(new Error('Hermes Gateway did not emit gateway.ready.'));
      }, this.requestTimeoutMs);
      this.gatewayReadyWaiter = {
        resolve: () => { clearTimeout(timer); this.gatewayReadyWaiter = null; resolve(); },
        reject: (error) => { clearTimeout(timer); this.gatewayReadyWaiter = null; reject(error); },
      };
    });
    await opened;
    await ready;
  }

  #handleSocketMessage(raw) {
    const text = typeof raw === 'string' ? raw : String(raw);
    if (Buffer.byteLength(text, 'utf8') > MAX_FRAME_BYTES) {
      this.emit('status', 'Hermes Gateway emitted an oversized frame.');
      return;
    }
    let frame;
    try {
      frame = JSON.parse(text);
    } catch {
      this.emit('status', 'Hermes Gateway emitted invalid JSON.');
      return;
    }
    if (frame.id !== undefined && frame.id !== null) {
      const call = this.pending.get(String(frame.id));
      if (!call) return;
      this.pending.delete(String(frame.id));
      clearTimeout(call.timer);
      if (frame.error) call.reject(new Error(frame.error.message || `Hermes ${call.method} failed.`));
      else call.resolve(frame.result);
      return;
    }
    if (frame.method === 'event' && frame.params) this.#handleGatewayEvent(frame.params);
  }

  #handleGatewayEvent(event) {
    const type = String(event.type || '');
    const payload = event.payload && typeof event.payload === 'object' ? event.payload : {};
    if (type === 'gateway.ready') {
      this.gatewayReady = true;
      this.gatewayReadyWaiter?.resolve();
      return;
    }
    const sessionId = this.runtimeSessionIds.get(String(event.session_id || ''));
    if (!sessionId) {
      recordNativeDiagnostic(this, 'Hermes Gateway', type, event);
      return;
    }
    const turnId = this.activeTurns.get(sessionId);
    const clientOperationId = this.turnClientOperations.get(sessionId) || null;
    if (type === 'session.info') {
      if (sessionId === this.activeSessionId) this.sessionInfo = { ...this.sessionInfo, ...payload };
      return;
    }
    if (type === 'message.start') {
      if (!turnId) this.activeTurns.set(sessionId, randomUUID());
      this.streamedAssistant.set(sessionId, '');
      return;
    }
    if (type === 'message.delta' || type === 'message.interim') {
      const text = String(payload.text || '');
      this.streamedAssistant.set(sessionId, `${this.streamedAssistant.get(sessionId) || ''}${text}`);
      this.emit('streamUpdate', {
        threadId: sessionId,
        turnId: turnId || null,
        clientOperationId,
        kind: 'assistant',
        lifecycle: 'delta',
        text,
      });
      return;
    }
    if (type === 'reasoning.delta' || type === 'thinking.delta' || type === 'reasoning.available') {
      this.emit('streamUpdate', {
        threadId: sessionId, kind: 'thinking', lifecycle: 'delta', text: String(payload.text || ''),
        itemId: `${sessionId}-thinking`, title: 'Thinking',
        turnId: turnId || null, clientOperationId,
      });
      return;
    }
    if (type === 'tool.start' || type === 'tool.progress' || type === 'tool.complete') {
      const lifecycle = type === 'tool.start' ? 'started' : type === 'tool.complete' ? 'completed' : 'delta';
      this.emit('streamUpdate', {
        threadId: sessionId,
        kind: 'tool',
        lifecycle,
        itemId: String(payload.tool_id || `${sessionId}-${payload.name || 'tool'}`),
        title: String(payload.name || 'Tool'),
        text: toolEventText(payload),
        turnId: turnId || null,
        clientOperationId,
      });
      return;
    }
    if (type === 'status.update') {
      if (payload.text) this.emit('status', sanitizeDiagnostic(payload.text));
      return;
    }
    if (type === 'approval.request') {
      this.#emitApproval(sessionId, payload);
      return;
    }
    if (['clarify.request', 'secret.request', 'sudo.request'].includes(type)) {
      this.#emitQuestion(sessionId, type.split('.')[0], payload);
      return;
    }
    if (type.endsWith('.expire')) {
      const requestId = String(payload.request_id || '');
      for (const [id, question] of this.pendingQuestions) {
        if (question.requestId === requestId) this.pendingQuestions.delete(id);
      }
      return;
    }
    if (type === 'message.complete') {
      this.#completeTurn(sessionId, payload);
      return;
    }
    if (type === 'error' && payload.message) {
      this.emit('status', `Hermes: ${sanitizeDiagnostic(payload.message)}`);
      return;
    }
    recordNativeDiagnostic(this, 'Hermes Gateway', type, event);
  }

  #emitApproval(sessionId, payload) {
    const approvalId = String(payload.request_id || randomUUID());
    const choices = (payload.choices || ['once', 'session', 'deny']).map(String);
    this.pendingApprovals.set(approvalId, { requestId: String(payload.request_id || approvalId), choices });
    this.emit('approvalRequested', {
      approvalId,
      threadId: sessionId,
      options: choices.map((choice) => ({
        optionId: choice,
        name: approvalChoiceLabel(choice),
        kind: choice === 'deny' ? 'reject' : `allow_${choice}`,
      })),
      toolCall: {
        title: String(payload.description || payload.reason || 'Hermes command'),
        rawInput: payload.command ? { command: payload.command } : payload,
      },
    });
  }

  #emitQuestion(sessionId, kind, payload) {
    const questionId = String(payload.request_id || randomUUID());
    this.pendingQuestions.set(questionId, { requestId: String(payload.request_id || questionId), kind });
    const choices = Array.isArray(payload.choices) ? payload.choices.map(String) : [];
    this.emit('questionRequested', {
      questionId,
      threadId: sessionId,
      method: choices.length ? 'select' : 'input',
      title: kind === 'clarify' ? 'Hermes needs clarification' : kind === 'sudo' ? 'Hermes requests sudo authentication' : 'Hermes requests a secret',
      message: String(payload.question || payload.prompt || payload.message || ''),
      options: choices,
      sensitive: kind === 'sudo' || kind === 'secret',
    });
  }

  #completeTurn(sessionId, payload) {
    const turnId = this.activeTurns.get(sessionId);
    if (!turnId) return;
    const clientOperationId = this.turnClientOperations.get(sessionId) || null;
    const finalText = String(payload.text || '');
    const streamed = this.streamedAssistant.get(sessionId) || '';
    if (finalText && !streamed) {
      this.emit('streamUpdate', { threadId: sessionId, turnId, clientOperationId, kind: 'assistant', lifecycle: 'completed', text: finalText });
    } else if (finalText.startsWith(streamed) && finalText.length > streamed.length) {
      this.emit('streamUpdate', { threadId: sessionId, turnId, clientOperationId, kind: 'assistant', lifecycle: 'completed', text: finalText.slice(streamed.length) });
    }
    if (payload.reasoning) {
      this.emit('streamUpdate', {
        threadId: sessionId, kind: 'thinking', lifecycle: 'completed', text: String(payload.reasoning),
        itemId: `${sessionId}-thinking`, title: 'Thinking',
        turnId, clientOperationId,
      });
    }
    this.messages.push({ role: 'assistant', text: finalText, ...(payload.reasoning ? { reasoning: String(payload.reasoning) } : {}) });
    this.activeTurns.delete(sessionId);
    this.turnClientOperations.delete(sessionId);
    this.streamedAssistant.delete(sessionId);
    this.emit('turnCompleted', {
      threadId: sessionId,
      turnId,
      clientOperationId,
      status: normalizeCompletionStatus(payload.status),
      ...(payload.error ? { error: String(payload.error) } : {}),
    });
  }

  async #refreshSessions() {
    const result = await this.#request('session.list', { limit: 200 });
    this.sessions = (result?.sessions || []).map((session) => ({
      id: String(session.id),
      name: session.title || null,
      preview: session.preview || session.title || 'Hermes session',
      updatedAt: Number(session.started_at || 0),
      messageCount: Number(session.message_count || 0),
    }));
    if (this.activeSessionId && !this.sessions.some((session) => session.id === this.activeSessionId)) {
      this.sessions.unshift({ id: this.activeSessionId, preview: 'New Hermes chat', updatedAt: Math.floor(Date.now() / 1000) });
    }
  }

  async #refreshModels() {
    try {
      const payload = await this.#request('model.options', { session_id: this.runtimeSessionId || '' });
      this.models = hermesModelsForRenderer(payload);
    } catch (error) {
      this.models = [];
      this.capabilities = this.capabilities.filter((capability) => !['model.select.v1', 'reasoning.select.v1'].includes(capability));
      this.emit('status', `Hermes model inventory unavailable: ${error.message}`);
    }
  }

  async #createSession(options = {}) {
    const selected = this.#selectedModel(options.model);
    const result = await this.#request('session.create', {
      source: 'zommi',
      close_on_disconnect: false,
      ...(selected ? { model: selected.rawModelId, provider: selected.provider } : {}),
      ...(options.effort ? { reasoning_effort: options.effort } : {}),
    });
    this.#bindSession(result, String(result?.stored_session_id || ''));
  }

  async #resumeSession(sessionId) {
    const result = await this.#request('session.resume', {
      session_id: sessionId,
      source: 'zommi',
      close_on_disconnect: false,
    });
    this.#bindSession(result, String(result?.session_key || result?.resumed || sessionId));
  }

  #bindSession(result, sessionId) {
    const runtimeSessionId = String(result?.session_id || '');
    if (!runtimeSessionId || !sessionId) throw new Error('Hermes Gateway returned an invalid session binding.');
    this.runtimeSessionId = runtimeSessionId;
    this.activeSessionId = sessionId;
    this.runtimeSessionIds.set(runtimeSessionId, sessionId);
    this.messages = Array.isArray(result.messages) ? result.messages : [];
    this.sessionInfo = result.info && typeof result.info === 'object' ? result.info : {};
    if (result.running) this.activeTurns.set(sessionId, `gateway-inflight-${sessionId}`);
  }

  async #applyOptions(options) {
    const selected = this.#selectedModel(options.model);
    if (selected && selected.id !== this.#activeModelId()) {
      const result = await this.#request('config.set', {
        session_id: this.runtimeSessionId,
        key: 'model',
        value: `${selected.rawModelId} --provider ${selected.provider} --session`,
      });
      if (result?.confirm_required) throw new Error(result.confirm_message || 'Hermes requires confirmation for this model switch.');
      this.sessionInfo = { ...this.sessionInfo, model: selected.rawModelId, provider: selected.provider };
    }
    if (options.effort && options.effort !== this.sessionInfo.reasoning_effort) {
      await this.#request('config.set', {
        session_id: this.runtimeSessionId,
        key: 'reasoning',
        value: options.effort,
      });
      this.sessionInfo = { ...this.sessionInfo, reasoning_effort: options.effort };
    }
  }

  #selectedModel(modelId) {
    return this.models.find((model) => model.id === modelId || model.model === modelId) || null;
  }

  #activeModelId() {
    return encodeModelId(this.sessionInfo.provider, this.sessionInfo.model);
  }

  #chatState() {
    const activeThreadId = this.activeSessionId || '';
    return {
      activeThreadId,
      activeModel: this.#activeModelId() || null,
      activeEffort: this.sessionInfo.reasoning_effort || null,
      models: this.models.map((model) => ({ ...model })),
      sessions: this.sessions.map((session) => ({ ...session })),
      activeTurns: [...this.activeTurns].map(([threadId, turnId]) => ({ threadId, turnId })),
      thread: { id: activeThreadId, turns: hermesMessagesToTurns(this.messages) },
      sessionMetadata: activeThreadId ? { sessionKey: activeThreadId } : null,
    };
  }

  #request(method, params = {}, metric = null) {
    if (!this.socket || this.socket.readyState !== 1 || !this.gatewayReady) {
      return Promise.reject(new Error('Hermes Gateway is not connected.'));
    }
    const id = `zommi-${++this.nextId}`;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        if (!this.pending.delete(id)) return;
        reject(new Error(`Hermes Gateway did not respond to '${method}' within ${Math.ceil(this.requestTimeoutMs / 1000)} seconds.`));
      }, this.requestTimeoutMs);
      this.pending.set(id, { method, resolve, reject, timer });
      try {
        if (metric) emitProtocolWrite(this, method, metric.clientOperationId, metric.transport);
        this.socket.send(JSON.stringify({ jsonrpc: '2.0', id, method, params }));
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(error);
      }
    });
  }

  #handleSocketClose() {
    this.socket = null;
    this.gatewayReady = false;
    const error = new Error('Hermes Gateway WebSocket closed. Accepted turns were not retried automatically.');
    this.gatewayReadyWaiter?.reject(error);
    this.gatewayReadyWaiter = null;
    this.#rejectPending(error);
    this.#finishUnknownTurns(error);
    if (!this.stopping) this.emit('status', error.message);
  }

  #handleProcessExit(child, code) {
    if (this.process !== child) return;
    this.process = null;
    if (this.stopping) return;
    const detail = this.stderr.trim();
    const error = new Error(sanitizeDiagnostic(`Hermes Gateway exited with code ${code}.${detail ? ` ${detail}` : ''}`));
    this.#rejectPending(error);
    this.#finishUnknownTurns(error);
    this.gatewayReadyWaiter?.reject(error);
    this.gatewayReadyWaiter = null;
    this.emit('status', error.message);
  }

  #rejectPending(error) {
    for (const call of this.pending.values()) {
      clearTimeout(call.timer);
      call.reject(error);
    }
    this.pending.clear();
  }

  #finishUnknownTurns(error) {
    for (const [threadId, turnId] of this.activeTurns) {
      this.emit('turnCompleted', {
        threadId,
        turnId,
        clientOperationId: this.turnClientOperations.get(threadId) || null,
        status: 'unknown',
        error: sanitizeDiagnostic(error),
      });
    }
    this.activeTurns.clear();
    this.turnClientOperations.clear();
    this.streamedAssistant.clear();
  }
}

export function buildHermesGatewayLaunch({ args = [], executionHost = {}, sessionToken }) {
  const required = ['serve', '--port', '0', '--host', '127.0.0.1', '--skip-build', '--isolated'];
  let nextArgs = [...args];
  for (let index = 0; index < required.length; index += 1) {
    const value = required[index];
    if (value === 'serve' && nextArgs.includes('serve')) continue;
    if (value === '--port' && nextArgs.includes('--port')) { index += 1; continue; }
    if (value === '--host' && nextArgs.includes('--host')) { index += 1; continue; }
    if (['--skip-build', '--isolated'].includes(value) && nextArgs.includes(value)) continue;
    nextArgs.push(value);
  }
  if (executionHost.kind === 'wsl') {
    const separator = nextArgs.indexOf('-e');
    if (separator < 0 || separator === nextArgs.length - 1) throw new Error('Invalid WSL Hermes Gateway launch vector.');
    nextArgs = [
      ...nextArgs.slice(0, separator + 1),
      'env', `HERMES_DASHBOARD_SESSION_TOKEN=${sessionToken}`,
      ...nextArgs.slice(separator + 1),
    ];
    return { args: nextArgs, env: {} };
  }
  return { args: nextArgs, env: { HERMES_DASHBOARD_SESSION_TOKEN: sessionToken } };
}

export function hermesModelsForRenderer(payload = {}) {
  const models = [];
  for (const provider of payload.providers || []) {
    const providerId = String(provider.slug || provider.id || '');
    if (!providerId) continue;
    for (const entry of provider.models || []) {
      const rawModelId = typeof entry === 'string' ? entry : String(entry.id || entry.model || entry.slug || '');
      if (!rawModelId) continue;
      const supportsReasoning = provider.capabilities?.supports_reasoning !== false
        && (typeof entry === 'string' || entry.capabilities?.supports_reasoning !== false);
      const id = encodeModelId(providerId, rawModelId);
      models.push({
        id,
        model: id,
        rawModelId,
        provider: providerId,
        displayName: typeof entry === 'string' ? rawModelId : String(entry.name || entry.display_name || rawModelId),
        hidden: false,
        supportedReasoningEfforts: supportsReasoning
          ? REASONING_EFFORTS.map((reasoningEffort) => ({ reasoningEffort }))
          : [],
        defaultReasoningEffort: 'medium',
      });
    }
  }
  return models;
}

export function hermesMessagesToTurns(messages = []) {
  const turns = [];
  let current = null;
  for (let index = 0; index < messages.length; index += 1) {
    const message = messages[index] || {};
    const role = String(message.role || '').toLowerCase();
    const text = messageText(message);
    if (role === 'user') {
      current = { id: `hermes-turn-${index}`, items: [{ id: `hermes-user-${index}`, type: 'userMessage', content: [{ type: 'text', text }] }] };
      turns.push(current);
      continue;
    }
    current ||= { id: `hermes-turn-${index}`, items: [] };
    if (!turns.includes(current)) turns.push(current);
    if (role === 'assistant') {
      if (message.reasoning) current.items.push({ id: `hermes-thinking-${index}`, type: 'reasoning', status: 'completed', summary: [String(message.reasoning)], content: [] });
      if (text) current.items.push({ id: `hermes-agent-${index}`, type: 'agentMessage', phase: 'final', status: 'completed', text });
    } else if (text) {
      current.items.push({ id: `hermes-tool-${index}`, type: 'commandExecution', status: 'completed', title: message.name || 'Tool', text });
    }
  }
  return turns;
}

function encodeModelId(provider, model) {
  return provider && model ? `${provider}::${model}` : String(model || '');
}

function messageText(message) {
  if (typeof message.text === 'string') return message.text;
  if (typeof message.content === 'string') return message.content;
  if (Array.isArray(message.content)) return message.content.map((part) => typeof part === 'string' ? part : part?.text || '').filter(Boolean).join('\n');
  return '';
}

function parseImageDataUrl(value) {
  const match = /^data:image\/([a-z0-9.+-]+);base64,([a-z0-9+/=\s]+)$/i.exec(String(value || ''));
  if (!match) throw new Error('Hermes Gateway accepts only base64 image data URLs.');
  const extension = match[1].toLowerCase() === 'jpeg' ? 'jpg' : match[1].toLowerCase();
  return { extension, base64: match[2].replace(/\s+/g, '') };
}

function toolEventText(payload) {
  if (payload.summary) return String(payload.summary);
  if (payload.preview) return String(payload.preview);
  if (payload.context) return typeof payload.context === 'string' ? payload.context : JSON.stringify(payload.context, null, 2);
  if (payload.result_text) return String(payload.result_text);
  if (payload.result !== undefined) return typeof payload.result === 'string' ? payload.result : JSON.stringify(payload.result, null, 2);
  return '';
}

function approvalChoiceLabel(choice) {
  return ({ once: 'Allow once', session: 'Allow for session', always: 'Always allow', deny: 'Deny' })[choice] || choice;
}

function normalizeCompletionStatus(status) {
  const value = String(status || 'complete').toLowerCase();
  if (value === 'interrupted' || value === 'cancelled') return 'interrupted';
  if (value === 'error' || value === 'failed') return 'failed';
  return 'completed';
}
