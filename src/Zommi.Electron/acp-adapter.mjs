import { randomUUID } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { spawn } from 'node:child_process';
import { homedir } from 'node:os';
import { buildContextHandoff } from './context-handoff.mjs';
import { normalizeClientOperationId, sanitizeDiagnostic } from './broker-protocol.mjs';
import { BoundedLineDecoder } from './protocol-framing.mjs';
import { recordNativeDiagnostic } from './adapter-diagnostics.mjs';
import { emitProtocolWrite } from './transport-metrics.mjs';

const ACP_PROTOCOL_VERSION = 1;
const DEFAULT_REQUEST_TIMEOUT_MS = 30_000;
const PROMPT_REQUEST_TIMEOUT_MS = 10 * 60 * 1000;
const PERMISSION_TIMEOUT_MS = 60_000;

export class AcpAdapter extends EventEmitter {
  constructor(options = {}) {
    super();
    this.command = options.command;
    this.commandArgs = options.commandArgs || [];
    this.cwd = options.cwd || homedir();
    this.runtimeDisplayName = options.runtimeDisplayName || 'ACP';
    this.signInHint = options.signInHint || 'complete sign-in in the runtime, then refresh Zommi';
    this.preferredSessionId = options.preferredSessionId || null;
    this.spawnProcess = options.spawnProcess || spawn;
    this.processEnv = options.env || process.env;
    this.requestTimeoutMs = options.requestTimeoutMs || DEFAULT_REQUEST_TIMEOUT_MS;
    this.permissionTimeoutMs = options.permissionTimeoutMs || PERMISSION_TIMEOUT_MS;
    this.process = null;
    this.startPromise = null;
    this.pending = new Map();
    this.pendingPermissions = new Map();
    this.nextId = 0;
    this.stderr = '';
    this.stdoutDecoder = null;
    this.sessionId = null;
    this.sessions = [];
    this.models = [];
    this.activeModel = null;
    this.activeTurns = new Map();
    this.turnClientOperations = new Map();
    this.histories = new Map();
    this.agentCapabilities = {};
    this.protocolVersion = null;
    this.runtimeVersion = null;
    this.capabilities = ['session.create.v1', 'turn.stream.v1', 'turn.interrupt.v1'];
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
    await this.#loadSessions();
    return this.#chatState();
  }

  async probeTransportWrite(options = {}) {
    await this.ensureStarted();
    if (!this.capabilities.includes('session.list.v1')) throw new Error('This ACP runtime has no read-only transport probe.');
    await this.#request('session/list', {}, this.requestTimeoutMs, options);
    return { ok: true };
  }

  async createSession(options = {}) {
    await this.ensureStarted();
    const result = await this.#request('session/new', { cwd: this.cwd, mcpServers: [] });
    this.#selectSession(result.sessionId, result);
    if (options.model) await this.#setModel(options.model);
    await this.#loadSessions();
    return this.#chatState();
  }

  async switchSession(sessionId) {
    await this.ensureStarted();
    if (!sessionId) throw new Error('An ACP session id is required.');
    this.histories.set(String(sessionId), []);
    const result = await this.#request('session/load', {
      cwd: this.cwd,
      sessionId: String(sessionId),
      mcpServers: [],
    });
    this.#selectSession(String(sessionId), result || {});
    await this.#loadSessions();
    return this.#chatState();
  }

  async startTurn(message, snapshots = [], images = [], options = {}) {
    await this.ensureStarted();
    if (!this.sessionId) throw new Error('ACP did not create a session.');
    if (this.activeTurns.has(this.sessionId)) throw new Error('This ACP session already has an active turn.');
    if (options.model && options.model !== this.activeModel) await this.#setModel(options.model);
    const turnId = randomUUID();
    const clientOperationId = normalizeClientOperationId(options.clientOperationId);
    const prompt = [{ type: 'text', text: buildContextHandoff(message, snapshots, images.length) }];
    for (const dataUrl of images) prompt.push(imageBlockFromDataUrl(dataUrl));
    this.#appendHistoryItem(this.sessionId, {
      id: `${turnId}-user`,
      type: 'userMessage',
      content: [{ type: 'text', text: prompt[0].text }],
    }, { startTurn: true, turnId });
    this.activeTurns.set(this.sessionId, turnId);
    this.turnClientOperations.set(this.sessionId, clientOperationId);
    const sessionId = this.sessionId;
    const request = this.#request('session/prompt', {
      sessionId,
      prompt,
      messageId: turnId,
    }, PROMPT_REQUEST_TIMEOUT_MS, { clientOperationId, transport: options.transport });
    void request.then((result) => {
      const completedOperationId = this.turnClientOperations.get(sessionId) || clientOperationId;
      this.activeTurns.delete(sessionId);
      this.turnClientOperations.delete(sessionId);
      const stopReason = result?.stopReason || 'end_turn';
      const status = stopReason === 'cancelled' ? 'interrupted'
        : ['end_turn', 'max_tokens', 'max_turn_requests'].includes(stopReason) ? 'completed'
          : 'failed';
      this.emit('turnCompleted', { threadId: sessionId, turnId, clientOperationId: completedOperationId, status, stopReason });
    }).catch((error) => {
      const failedOperationId = this.turnClientOperations.get(sessionId) || clientOperationId;
      this.activeTurns.delete(sessionId);
      this.turnClientOperations.delete(sessionId);
      this.emit('status', `ACP prompt failed: ${sanitizeDiagnostic(error)}`);
      const status = /stopped|exited|closed|disconnect/i.test(String(error?.message || error)) ? 'unknown' : 'failed';
      this.emit('turnCompleted', {
        threadId: sessionId,
        turnId,
        clientOperationId: failedOperationId,
        status,
        error: sanitizeDiagnostic(error),
      });
    });
    return { accepted: true, threadId: sessionId, turnId, clientOperationId };
  }

  async interruptTurn() {
    await this.ensureStarted();
    const sessionId = this.sessionId;
    const turnId = this.activeTurns.get(sessionId);
    if (!sessionId || !turnId) throw new Error('There is no active ACP turn to stop.');
    this.#notify('session/cancel', { sessionId });
    return {
      interrupted: true,
      threadId: sessionId,
      turnId,
      clientOperationId: this.turnClientOperations.get(sessionId) || null,
    };
  }

  resolveApproval(approvalId, optionId = null) {
    const pending = this.pendingPermissions.get(String(approvalId));
    if (!pending) throw new Error(`Unknown ACP approval '${approvalId}'.`);
    clearTimeout(pending.timer);
    this.pendingPermissions.delete(String(approvalId));
    const selected = optionId && pending.options.some((option) => option.optionId === optionId);
    this.#write(selected
      ? { jsonrpc: '2.0', id: pending.rpcId, result: { outcome: { outcome: 'selected', optionId } } }
      : { jsonrpc: '2.0', id: pending.rpcId, result: { outcome: { outcome: 'cancelled' } } });
    return { resolved: true, approvalId: String(approvalId), optionId: selected ? optionId : null };
  }

  stop() {
    if (this.process && !this.process.killed) this.process.kill();
    const error = new Error('ACP process stopped.');
    for (const completion of this.pending.values()) {
      clearTimeout(completion.timer);
      completion.reject(error);
    }
    for (const permission of this.pendingPermissions.values()) {
      clearTimeout(permission.timer);
    }
    this.pending.clear();
    this.pendingPermissions.clear();
    this.stdoutDecoder?.reset();
    this.stdoutDecoder = null;
    this.activeTurns.clear();
    this.turnClientOperations.clear();
    this.process = null;
    this.startPromise = null;
  }

  async #start() {
    if (!this.command) throw new Error('ACP launch command is missing.');
    this.emit('status', `Connecting to ${this.runtimeDisplayName}…`);
    const child = this.spawnProcess(this.command, this.commandArgs, {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: this.processEnv,
      windowsHide: true,
    });
    this.process = child;
    child.stdout.setEncoding?.('utf8');
    this.stdoutDecoder = new BoundedLineDecoder({
      onLine: (line) => this.#handleLine(line),
      onOversized: () => this.emit('status', 'ACP emitted an oversized frame.'),
    });
    child.stdout.on('data', (chunk) => this.stdoutDecoder?.push(chunk));
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => { this.stderr = (this.stderr + chunk).slice(-8_000); });
    child.once('error', (error) => this.#rejectPending(error));
    child.once('exit', (code) => {
      const detail = this.stderr.trim();
      const error = new Error(sanitizeDiagnostic(`ACP process exited with code ${code}.${detail ? ` ${detail}` : ''}`));
      this.#rejectPending(error);
      this.process = null;
      this.startPromise = null;
      this.emit('status', error.message);
    });
    const initialized = await this.#request('initialize', {
      protocolVersion: ACP_PROTOCOL_VERSION,
      clientCapabilities: {},
      clientInfo: { name: 'zommi', version: '0.2.0' },
    });
    if (initialized?.protocolVersion !== ACP_PROTOCOL_VERSION) {
      throw new Error(`Unsupported ACP protocol version ${initialized?.protocolVersion}.`);
    }
    this.protocolVersion = initialized.protocolVersion;
    this.runtimeVersion = initialized.agentInfo?.version ? String(initialized.agentInfo.version) : null;
    this.agentCapabilities = initialized.agentCapabilities || {};
    this.capabilities = capabilitiesFromAcpInitialize(initialized);
    const authMethods = initialized.authMethods || [];
    const agentAuth = authMethods.find((method) => method.type !== 'terminal');
    if (agentAuth?.id) await this.#request('authenticate', { methodId: agentAuth.id });
    else if (authMethods.some((method) => method.type === 'terminal')) {
      throw new Error(`${this.runtimeDisplayName} sign-in required; ${this.signInHint}.`);
    }
    await this.#loadSessions();
    if (this.preferredSessionId && this.agentCapabilities.loadSession) {
      try {
        this.histories.set(this.preferredSessionId, []);
        const result = await this.#request('session/load', {
          cwd: this.cwd,
          sessionId: this.preferredSessionId,
          mcpServers: [],
        });
        this.#selectSession(this.preferredSessionId, result || {});
      } catch (error) {
        this.emit('status', `Bound ACP session could not be resumed: ${error.message}`);
      }
    }
    if (!this.sessionId) {
      const result = await this.#request('session/new', { cwd: this.cwd, mcpServers: [] });
      this.#selectSession(result.sessionId, result);
    }
    this.emit('status', `${this.runtimeDisplayName} ready · ${String(this.sessionId).slice(0, 8)}`);
  }

  async #loadSessions() {
    if (!this.agentCapabilities?.sessionCapabilities?.list) {
      this.sessions = this.sessionId ? [{ id: this.sessionId, preview: `${this.runtimeDisplayName} session` }] : [];
      return;
    }
    const sessions = [];
    let cursor = null;
    for (let page = 0; page < 5; page += 1) {
      const result = await this.#request('session/list', { ...(cursor ? { cursor } : {}), cwd: this.cwd });
      sessions.push(...(result?.sessions || []).map((session) => ({
        id: session.sessionId,
        name: session.title || null,
        preview: session.title || `${this.runtimeDisplayName} session`,
        updatedAt: session.updatedAt || null,
        cwd: session.cwd,
      })));
      cursor = result?.nextCursor;
      if (!cursor) break;
    }
    if (this.sessionId && !sessions.some((session) => session.id === this.sessionId)) {
      sessions.unshift({ id: this.sessionId, preview: 'Current ACP session', cwd: this.cwd });
    }
    this.sessions = sessions;
  }

  async #setModel(modelId) {
    if (!this.sessionId || !this.capabilities.includes('model.select.v1')) return;
    const result = await this.#request('session/set_model', { sessionId: this.sessionId, modelId: String(modelId) });
    this.#applyModelState(result?.models || result);
  }

  #selectSession(sessionId, result) {
    if (!sessionId) throw new Error('ACP returned a session without an id.');
    this.sessionId = String(sessionId);
    if (!this.histories.has(this.sessionId)) this.histories.set(this.sessionId, []);
    this.#applyModelState(result?.models);
  }

  #applyModelState(modelState) {
    if (!modelState) return;
    this.activeModel = modelState.currentModelId || this.activeModel;
    this.models = (modelState.availableModels || []).map((model) => ({
      id: model.modelId,
      model: model.modelId,
      displayName: model.name || model.modelId,
      description: model.description || '',
      supportedReasoningEfforts: [],
    }));
    if (this.models.length && !this.capabilities.includes('model.select.v1')) {
      this.capabilities.push('model.select.v1');
    }
  }

  #chatState() {
    const turns = this.histories.get(this.sessionId) || [];
    return {
      activeThreadId: this.sessionId,
      activeModel: this.activeModel,
      activeEffort: null,
      models: this.models,
      sessions: this.sessions,
      activeTurns: [...this.activeTurns].map(([threadId, turnId]) => ({ threadId, turnId })),
      thread: { id: this.sessionId, turns },
    };
  }

  #request(method, params, timeoutMs = this.requestTimeoutMs, metric = null) {
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        if (!this.pending.delete(id)) return;
        reject(new Error(`ACP did not respond to '${method}' within ${Math.ceil(timeoutMs / 1000)} seconds.`));
      }, timeoutMs);
      this.pending.set(id, { method, resolve, reject, timer });
      try {
        if (metric) emitProtocolWrite(this, method, metric.clientOperationId, metric.transport);
        this.#write({ jsonrpc: '2.0', id, method, params });
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(error);
      }
    });
  }

  #notify(method, params) {
    this.#write({ jsonrpc: '2.0', method, params });
  }

  #write(message) {
    if (!this.process?.stdin) throw new Error('ACP process is not running.');
    this.process.stdin.write(`${JSON.stringify(message)}\n`);
  }

  #handleLine(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      this.emit('status', 'ACP emitted invalid JSON.');
      return;
    }
    if (message.method && Object.hasOwn(message, 'id')) {
      this.#handleIncomingRequest(message);
      return;
    }
    if (message.method) {
      if (message.method === 'session/update') this.#handleSessionUpdate(message.params || {});
      else recordNativeDiagnostic(this, 'ACP', message.method, message.params);
      return;
    }
    const completion = this.pending.get(Number(message.id));
    if (!completion) return;
    this.pending.delete(Number(message.id));
    clearTimeout(completion.timer);
    if (message.error) completion.reject(new Error(`ACP request '${completion.method}' failed: ${JSON.stringify(message.error)}`));
    else completion.resolve(message.result);
  }

  #handleIncomingRequest(message) {
    if (message.method !== 'session/request_permission') {
      recordNativeDiagnostic(this, 'ACP', message.method, message.params);
      this.#write({
        jsonrpc: '2.0',
        id: message.id,
        error: { code: -32601, message: `Unsupported ACP client request ${message.method}` },
      });
      return;
    }
    const approvalId = randomUUID();
    const options = Array.isArray(message.params?.options) ? message.params.options : [];
    const timer = setTimeout(() => {
      if (!this.pendingPermissions.delete(approvalId)) return;
      this.#write({ jsonrpc: '2.0', id: message.id, result: { outcome: { outcome: 'cancelled' } } });
    }, this.permissionTimeoutMs);
    this.pendingPermissions.set(approvalId, { rpcId: message.id, options, timer });
    this.emit('approvalRequested', {
      approvalId,
      threadId: message.params?.sessionId,
      toolCall: message.params?.toolCall || null,
      options,
    });
  }

  #handleSessionUpdate(params) {
    const sessionId = String(params.sessionId || this.sessionId || '');
    const update = params.update || {};
    if (!sessionId) return;
    const turnId = this.activeTurns.get(sessionId) || null;
    const clientOperationId = this.turnClientOperations.get(sessionId) || null;
    const kind = update.sessionUpdate;
    if (kind === 'user_message_chunk') {
      const text = contentText(update.content);
      if (text) this.#appendHistoryItem(sessionId, {
        id: update.messageId || randomUUID(), type: 'userMessage', content: [{ type: 'text', text }],
      }, { startTurn: true });
      return;
    }
    if (kind === 'agent_message_chunk' || kind === 'agent_thought_chunk') {
      const text = contentText(update.content);
      const itemId = update.messageId || `${sessionId}-${kind}`;
      const itemType = kind === 'agent_message_chunk' ? 'agentMessage' : 'reasoning';
      this.#appendOrMergeHistoryItem(sessionId, itemId, itemType, text);
      this.emit('streamUpdate', {
        threadId: sessionId,
        kind: kind === 'agent_message_chunk' ? 'assistant' : 'thinking',
        lifecycle: 'delta',
        title: kind === 'agent_message_chunk' ? this.runtimeDisplayName : 'Thinking',
        text,
        itemId,
        turnId,
        clientOperationId,
      });
      return;
    }
    if (kind === 'tool_call' || kind === 'tool_call_update') {
      const lifecycle = kind === 'tool_call' ? 'started'
        : ['completed', 'failed'].includes(update.status) ? 'completed' : 'delta';
      const text = toolUpdateText(update);
      this.#appendOrMergeHistoryItem(sessionId, update.toolCallId, 'dynamicToolCall', text, {
        status: update.status,
        turnId,
        clientOperationId,
        tool: update.title || update.kind || 'Tool',
      });
      this.emit('streamUpdate', {
        threadId: sessionId,
        kind: lifecycle === 'delta' ? 'toolOutput' : 'tool',
        lifecycle,
        title: update.title || 'Tool',
        text,
        itemId: update.toolCallId,
        status: update.status,
        turnId,
        clientOperationId,
      });
      return;
    }
    if (kind === 'plan') {
      const text = (update.entries || []).map((entry) => `${entry.status}: ${entry.content}`).join('\n');
      this.emit('streamUpdate', {
        threadId: sessionId,
        kind: 'plan',
        lifecycle: 'delta',
        title: 'Plan',
        text,
        itemId: `${sessionId}-plan`,
        turnId,
        clientOperationId,
      });
      return;
    }
    recordNativeDiagnostic(this, 'ACP session/update', kind, params);
  }

  #appendHistoryItem(sessionId, item, { startTurn = false, turnId = null } = {}) {
    const turns = this.histories.get(sessionId) || [];
    if (startTurn || !turns.length) turns.push({ id: turnId || randomUUID(), items: [item] });
    else turns.at(-1).items.push(item);
    this.histories.set(sessionId, turns);
  }

  #appendOrMergeHistoryItem(sessionId, itemId, type, text, extra = {}) {
    const turns = this.histories.get(sessionId) || [];
    if (!turns.length) turns.push({ id: randomUUID(), items: [] });
    const items = turns.at(-1).items;
    let item = items.find((candidate) => candidate.id === itemId);
    if (!item) {
      item = { id: itemId || randomUUID(), type, ...extra };
      if (type === 'agentMessage') item.phase = 'final';
      if (type === 'reasoning') item.summary = [];
      items.push(item);
    }
    if (type === 'reasoning') item.summary = [`${item.summary?.[0] || ''}${text || ''}`];
    else if (type === 'agentMessage') item.text = `${item.text || ''}${text || ''}`;
    else item.aggregatedOutput = `${item.aggregatedOutput || ''}${text || ''}`;
    this.histories.set(sessionId, turns);
  }

  #rejectPending(error) {
    for (const completion of this.pending.values()) {
      clearTimeout(completion.timer);
      completion.reject(error);
    }
    this.pending.clear();
  }
}

export function capabilitiesFromAcpInitialize(initialized) {
  const agent = initialized?.agentCapabilities || {};
  const session = agent.sessionCapabilities || {};
  const capabilities = ['session.create.v1', 'turn.stream.v1', 'turn.interrupt.v1'];
  if (agent.loadSession) capabilities.push('session.resume.v1', 'history.read.v1');
  if (session.list) capabilities.push('session.list.v1');
  if (agent.promptCapabilities?.image) capabilities.push('input.image.v1');
  capabilities.push('approval.resolve.v1');
  return capabilities;
}

function imageBlockFromDataUrl(value) {
  const match = /^data:([^;,]+);base64,(.+)$/s.exec(String(value));
  if (!match || !match[1].startsWith('image/')) throw new Error('ACP image context must be a base64 image data URL.');
  return { type: 'image', mimeType: match[1], data: match[2] };
}

function contentText(content) {
  if (typeof content === 'string') return content;
  if (content?.type === 'text') return String(content.text || '');
  return '';
}

function toolUpdateText(update) {
  const values = [];
  if (update.rawInput) values.push(JSON.stringify(update.rawInput));
  if (update.rawOutput) values.push(typeof update.rawOutput === 'string' ? update.rawOutput : JSON.stringify(update.rawOutput));
  for (const content of update.content || []) {
    const text = contentText(content?.content || content);
    if (text) values.push(text);
  }
  return values.join('\n');
}
