import { randomUUID } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { spawn } from 'node:child_process';
import { homedir } from 'node:os';
import { buildContextHandoff } from './context-handoff.mjs';
import { ambiguousOutcome, normalizeClientOperationId, sanitizeDiagnostic } from './broker-protocol.mjs';
import { recordNativeDiagnostic } from './adapter-diagnostics.mjs';
import { emitProtocolWrite } from './transport-metrics.mjs';

const DEFAULT_REQUEST_TIMEOUT_MS = 30_000;
const MAX_FRAME_BYTES = 16 * 1024 * 1024;

export class PiRpcAdapter extends EventEmitter {
  constructor(options = {}) {
    super();
    this.command = options.command;
    this.commandArgs = options.commandArgs || [];
    this.cwd = options.cwd || homedir();
    this.preferredSessionFile = options.preferredSessionFile || null;
    this.spawnProcess = options.spawnProcess || spawn;
    this.processEnv = options.env || process.env;
    this.requestTimeoutMs = options.requestTimeoutMs || DEFAULT_REQUEST_TIMEOUT_MS;
    this.process = null;
    this.startPromise = null;
    this.pending = new Map();
    this.nextId = 0;
    this.stdoutBuffer = '';
    this.stderr = '';
    this.state = null;
    this.messages = [];
    this.models = [];
    this.thinkingLevels = [];
    this.activeTurns = new Map();
    this.turnClientOperations = new Map();
    this.sessionsById = new Map();
    this.pendingQuestions = new Map();
    this.protocolVersion = null;
    this.runtimeVersion = null;
    this.capabilities = [
      'session.create.v1', 'session.resume.v1', 'history.read.v1', 'turn.stream.v1',
      'turn.interrupt.v1', 'turn.steer.v1', 'input.image.v1', 'model.select.v1',
      'reasoning.select.v1', 'question.resolve.v1',
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
    await this.#refreshState();
    return this.#chatState();
  }

  async probeTransportWrite(options = {}) {
    await this.ensureStarted();
    await this.#request({ type: 'get_state' }, options);
    return { ok: true };
  }

  async createSession(options = {}) {
    await this.ensureStarted();
    const result = await this.#request({ type: 'new_session' });
    if (result?.data?.cancelled) throw new Error('Pi cancelled the new session.');
    await this.#refreshState();
    await this.#applyOptions(options);
    return this.#chatState();
  }

  async switchSession(sessionId) {
    await this.ensureStarted();
    const session = this.sessionsById.get(String(sessionId));
    if (!session?.sessionFile) throw new Error('Pi can resume only an exact session file previously returned by Pi.');
    const result = await this.#request({ type: 'switch_session', sessionPath: session.sessionFile });
    if (result?.data?.cancelled) throw new Error('Pi cancelled the session switch.');
    await this.#refreshState();
    return this.#chatState();
  }

  async startTurn(message, snapshots = [], images = [], options = {}) {
    await this.ensureStarted();
    await this.#applyOptions(options);
    const sessionId = this.state?.sessionId;
    if (!sessionId) throw new Error('Pi did not expose a session id.');
    if (this.activeTurns.has(sessionId)) throw new Error('This Pi session already has an active turn.');
    const turnId = randomUUID();
    const clientOperationId = normalizeClientOperationId(options.clientOperationId);
    this.activeTurns.set(sessionId, turnId);
    this.turnClientOperations.set(sessionId, clientOperationId);
    const command = {
      type: 'prompt',
      message: buildContextHandoff(message, snapshots, images.length),
      ...(images.length ? { images: images.map(imageFromDataUrl) } : {}),
    };
    try {
      await this.#request(command, { clientOperationId, transport: options.transport });
    } catch (error) {
      if (/timed? out|did not respond/i.test(String(error?.message || error))) {
        throw ambiguousOutcome(error, 'Pi RPC');
      }
      this.activeTurns.delete(sessionId);
      this.turnClientOperations.delete(sessionId);
      throw error;
    }
    return {
      accepted: true,
      threadId: sessionId,
      turnId,
      clientOperationId,
      sessionMetadata: this.state?.sessionFile ? { sessionFile: this.state.sessionFile } : null,
    };
  }

  async steerTurn(message, images = [], identity = {}) {
    await this.ensureStarted();
    const sessionId = String(this.state?.sessionId || '');
    const turnId = this.activeTurns.get(sessionId);
    if (!sessionId || !turnId) throw new Error('There is no active Pi turn to steer.');
    if (identity.sessionId && String(identity.sessionId) !== sessionId) {
      throw new Error('Pi steering Session identity does not match the active Session.');
    }
    if (identity.turnId && String(identity.turnId) !== String(turnId)) {
      throw new Error('Pi steering turn identity does not match the active turn.');
    }
    const result = await this.#request({
      type: 'steer', message: String(message),
      ...(images.length ? { images: images.map(imageFromDataUrl) } : {}),
    });
    return {
      accepted: Boolean(result?.success),
      threadId: sessionId,
      turnId,
      clientOperationId: this.turnClientOperations.get(sessionId) || null,
    };
  }

  async interruptTurn() {
    await this.ensureStarted();
    const sessionId = this.state?.sessionId;
    const turnId = this.activeTurns.get(sessionId);
    if (!sessionId || !turnId) throw new Error('There is no active Pi turn to stop.');
    await this.#request({ type: 'clear_queue' });
    await this.#request({ type: 'abort' });
    return {
      interrupted: true,
      threadId: sessionId,
      turnId,
      clientOperationId: this.turnClientOperations.get(sessionId) || null,
    };
  }

  resolveQuestion(questionId, answer = {}) {
    const question = this.pendingQuestions.get(String(questionId));
    if (!question) throw new Error(`Unknown Pi question '${questionId}'.`);
    this.pendingQuestions.delete(String(questionId));
    let response = { type: 'extension_ui_response', id: question.rpcId, cancelled: true };
    if (question.method === 'confirm' && typeof answer.confirmed === 'boolean') {
      response = { type: 'extension_ui_response', id: question.rpcId, confirmed: answer.confirmed };
    } else if (typeof answer.value === 'string') {
      response = { type: 'extension_ui_response', id: question.rpcId, value: answer.value };
    }
    this.#write(response);
    return { resolved: true, questionId: String(questionId) };
  }

  stop() {
    if (this.process && !this.process.killed) this.process.kill();
    this.#rejectPending(new Error('Pi RPC process stopped.'));
    this.pendingQuestions.clear();
    this.activeTurns.clear();
    this.turnClientOperations.clear();
    this.process = null;
    this.startPromise = null;
  }

  async #start() {
    if (!this.command) throw new Error('Pi RPC launch command is missing.');
    this.emit('status', 'Connecting to Pi RPC…');
    const child = this.spawnProcess(this.command, this.commandArgs, {
      stdio: ['pipe', 'pipe', 'pipe'],
      cwd: this.command.toLowerCase().endsWith('wsl.exe') ? undefined : this.cwd,
      env: this.processEnv,
      windowsHide: true,
    });
    this.process = child;
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => this.#handleStdout(chunk));
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => { this.stderr = (this.stderr + chunk).slice(-8_000); });
    child.once('error', (error) => this.#rejectPending(error));
    child.once('exit', (code) => {
      const detail = this.stderr.trim();
      const error = new Error(sanitizeDiagnostic(`Pi RPC exited with code ${code}.${detail ? ` ${detail}` : ''}`));
      this.#rejectPending(error);
      this.#failActiveTurns(error);
      this.process = null;
      this.startPromise = null;
      this.emit('status', error.message);
    });
    await this.#refreshState({ includeMessages: false });
    this.protocolVersion = 1;
    this.runtimeVersion = this.state?.version ? String(this.state.version) : null;
    if (this.preferredSessionFile && this.preferredSessionFile !== this.state?.sessionFile) {
      const switched = await this.#request({ type: 'switch_session', sessionPath: this.preferredSessionFile });
      if (switched?.data?.cancelled) throw new Error('Pi cancelled the bound session resume.');
    }
    await this.#refreshState();
    if (!this.state?.model || !this.models.length) {
      throw new Error('Pi sign-in required; open Pi and use /login or configure an API key.');
    }
    this.emit('status', `Pi ready · ${String(this.state.sessionId).slice(0, 8)}`);
  }

  async #refreshState({ includeMessages = true } = {}) {
    const stateResponse = await this.#request({ type: 'get_state' });
    this.state = stateResponse.data || {};
    if (this.state.sessionId) {
      this.sessionsById.set(String(this.state.sessionId), {
        id: String(this.state.sessionId),
        name: this.state.sessionName || null,
        preview: this.state.sessionName || 'Pi session',
        sessionFile: this.state.sessionFile || null,
      });
    }
    const [modelsResponse, messagesResponse] = await Promise.all([
      this.#request({ type: 'get_available_models' }),
      includeMessages ? this.#request({ type: 'get_messages' }) : Promise.resolve(null),
    ]);
    this.models = (modelsResponse?.data?.models || []).map(piModelForRenderer);
    const activeModel = this.models.find((model) => model.id === `${this.state?.model?.provider}/${this.state?.model?.id}`);
    this.thinkingLevels = activeModel?.supportedReasoningEfforts.map((item) => item.reasoningEffort) || [];
    if (messagesResponse) this.messages = messagesResponse?.data?.messages || [];
  }

  async #applyOptions(options) {
    if (options.model) {
      const model = this.models.find((candidate) => candidate.id === options.model || candidate.model === options.model);
      if (model && `${model.provider}/${model.rawModelId}` !== `${this.state?.model?.provider}/${this.state?.model?.id}`) {
        await this.#request({ type: 'set_model', provider: model.provider, modelId: model.rawModelId });
        this.state.model = { provider: model.provider, id: model.rawModelId };
        this.thinkingLevels = model.supportedReasoningEfforts.map((item) => item.reasoningEffort);
      }
    }
    if (options.effort && this.thinkingLevels.includes(options.effort) && options.effort !== this.state?.thinkingLevel) {
      await this.#request({ type: 'set_thinking_level', level: options.effort });
      this.state.thinkingLevel = options.effort;
    }
  }

  #chatState() {
    const sessionId = String(this.state?.sessionId || '');
    return {
      activeThreadId: sessionId,
      activeModel: this.state?.model ? `${this.state.model.provider}/${this.state.model.id}` : null,
      activeEffort: this.state?.thinkingLevel || null,
      models: this.models.map((model) => ({
        ...model,
        supportedReasoningEfforts: model.supportedReasoningEfforts.map((item) => ({ ...item })),
      })),
      sessions: [...this.sessionsById.values()],
      activeTurns: [...this.activeTurns].map(([threadId, turnId]) => ({ threadId, turnId })),
      thread: { id: sessionId, turns: piMessagesToTurns(this.messages) },
      sessionMetadata: this.state?.sessionFile ? { sessionFile: this.state.sessionFile } : null,
    };
  }

  #request(command, metric = null) {
    const id = `zommi-${++this.nextId}`;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        if (!this.pending.delete(id)) return;
        reject(new Error(`Pi RPC did not respond to '${command.type}' within ${Math.ceil(this.requestTimeoutMs / 1000)} seconds.`));
      }, this.requestTimeoutMs);
      this.pending.set(id, { command: command.type, resolve, reject, timer });
      try {
        if (metric) emitProtocolWrite(this, command.type, metric.clientOperationId, metric.transport);
        this.#write({ ...command, id });
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(error);
      }
    });
  }

  #write(message) {
    if (!this.process?.stdin) throw new Error('Pi RPC process is not running.');
    this.process.stdin.write(`${JSON.stringify(message)}\n`);
  }

  #handleStdout(chunk) {
    this.stdoutBuffer += String(chunk);
    if (Buffer.byteLength(this.stdoutBuffer, 'utf8') > MAX_FRAME_BYTES) {
      this.stdoutBuffer = '';
      this.emit('status', 'Pi RPC emitted an oversized frame.');
      return;
    }
    let newline;
    while ((newline = this.stdoutBuffer.indexOf('\n')) >= 0) {
      let line = this.stdoutBuffer.slice(0, newline);
      this.stdoutBuffer = this.stdoutBuffer.slice(newline + 1);
      if (line.endsWith('\r')) line = line.slice(0, -1);
      if (line) this.#handleLine(line);
    }
  }

  #handleLine(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      this.emit('status', 'Pi RPC emitted invalid JSON.');
      return;
    }
    if (message.type === 'response' && message.id) {
      const completion = this.pending.get(String(message.id));
      if (!completion) return;
      this.pending.delete(String(message.id));
      clearTimeout(completion.timer);
      if (message.success) completion.resolve(message);
      else completion.reject(new Error(message.error || `Pi ${completion.command} failed.`));
      return;
    }
    if (message.type === 'extension_ui_request') {
      this.#handleExtensionRequest(message);
      return;
    }
    this.#handleEvent(message);
  }

  #handleExtensionRequest(message) {
    if (['notify', 'setStatus'].includes(message.method)) {
      if (message.message || message.statusText) this.emit('status', sanitizeDiagnostic(message.message || message.statusText));
      return;
    }
    if (!['select', 'confirm', 'input', 'editor'].includes(message.method)) {
      recordNativeDiagnostic(this, 'Pi RPC extension', message.method, message);
      return;
    }
    const questionId = randomUUID();
    this.pendingQuestions.set(questionId, { rpcId: message.id, method: message.method });
    this.emit('questionRequested', {
      questionId,
      threadId: this.state?.sessionId || null,
      method: message.method,
      title: message.title || 'Pi requests input',
      message: message.message || '',
      options: message.options || [],
      placeholder: message.placeholder || '',
      prefill: message.prefill || '',
    });
  }

  #handleEvent(event) {
    const sessionId = String(this.state?.sessionId || '');
    const turnId = this.activeTurns.get(sessionId);
    const clientOperationId = this.turnClientOperations.get(sessionId) || null;
    if (event.type === 'message_update') {
      const update = event.assistantMessageEvent || {};
      if (update.type === 'text_delta' || update.type === 'thinking_delta') {
        this.emit('streamUpdate', {
          threadId: sessionId,
          kind: update.type === 'text_delta' ? 'assistant' : 'thinking',
          lifecycle: 'delta',
          title: update.type === 'text_delta' ? 'Pi' : 'Thinking',
          text: update.delta || '',
          itemId: `${turnId || sessionId}-${update.contentIndex ?? update.type}`,
          turnId: turnId || null,
          clientOperationId,
        });
      }
      if (update.type === 'toolcall_start') {
        this.emit('streamUpdate', {
          threadId: sessionId, kind: 'tool', lifecycle: 'started', title: update.toolName || 'Tool',
          text: '', itemId: update.id,
          turnId: turnId || null, clientOperationId,
        });
      }
      return;
    }
    if (event.type === 'tool_execution_start' || event.type === 'tool_execution_update' || event.type === 'tool_execution_end') {
      const lifecycle = event.type.endsWith('_start') ? 'started' : event.type.endsWith('_end') ? 'completed' : 'delta';
      const payload = event.result || event.partialResult;
      this.emit('streamUpdate', {
        threadId: sessionId,
        kind: lifecycle === 'delta' ? 'toolOutput' : 'tool',
        lifecycle,
        title: event.toolName || 'Tool',
        text: piToolText(payload, event.args),
        itemId: event.toolCallId,
        status: event.isError ? 'failed' : lifecycle === 'completed' ? 'completed' : null,
        turnId: turnId || null,
        clientOperationId,
      });
      return;
    }
    if (event.type === 'agent_end' || event.type === 'agent_settled') {
      if (!turnId) return;
      this.activeTurns.delete(sessionId);
      this.turnClientOperations.delete(sessionId);
      void this.#request({ type: 'get_messages' }).then((response) => {
        this.messages = response?.data?.messages || this.messages;
      }).catch(() => {});
      this.emit('turnCompleted', { threadId: sessionId, turnId, clientOperationId, status: 'completed' });
      return;
    }
    if (event.type === 'extension_error') {
      this.emit('status', sanitizeDiagnostic(event.error || 'Pi extension failed.'));
      return;
    }
    recordNativeDiagnostic(this, 'Pi RPC', event.type, event);
  }

  #rejectPending(error) {
    for (const completion of this.pending.values()) {
      clearTimeout(completion.timer);
      completion.reject(error);
    }
    this.pending.clear();
  }

  #failActiveTurns(error) {
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
  }
}

export function piMessagesToTurns(messages) {
  const turns = [];
  for (const message of messages || []) {
    const role = message?.role;
    if (role === 'user') {
      turns.push({
        id: message.id || randomUUID(),
        items: [{ id: `${message.id || randomUUID()}-user`, type: 'userMessage', content: [{ type: 'text', text: piMessageText(message) }] }],
      });
      continue;
    }
    if (!turns.length) turns.push({ id: randomUUID(), items: [] });
    if (role === 'assistant') {
      const assistantText = piMessageText(message, 'text');
      const reasoning = piMessageText(message, 'thinking');
      if (reasoning) turns.at(-1).items.push({ id: `${message.id || randomUUID()}-thinking`, type: 'reasoning', status: 'completed', summary: [reasoning] });
      if (assistantText) turns.at(-1).items.push({ id: `${message.id || randomUUID()}-assistant`, type: 'agentMessage', phase: 'final', status: 'completed', text: assistantText });
      for (const content of message.content || []) {
        if (content.type === 'toolCall') turns.at(-1).items.push({
          id: content.id || randomUUID(), type: 'dynamicToolCall', tool: content.name || 'Tool', status: 'completed', rawInput: content.arguments,
        });
      }
    } else if (role === 'toolResult') {
      turns.at(-1).items.push({
        id: message.toolCallId || message.id || randomUUID(), type: 'commandExecution', status: message.isError ? 'failed' : 'completed',
        aggregatedOutput: piMessageText(message),
      });
    }
  }
  return turns;
}

function piModelForRenderer(model) {
  const id = `${model.provider}/${model.id}`;
  return {
    id,
    model: id,
    provider: model.provider,
    rawModelId: model.id,
    displayName: model.name || id,
    description: model.provider,
    supportedReasoningEfforts: piThinkingLevels(model).map((reasoningEffort) => ({ reasoningEffort })),
  };
}

function piThinkingLevels(model) {
  if (!model.reasoning) return ['off'];
  return ['off', 'minimal', 'low', 'medium', 'high', 'xhigh'].filter((level) => {
    const mapped = model.thinkingLevelMap?.[level];
    if (mapped === null) return false;
    return level !== 'xhigh' || mapped !== undefined;
  });
}

function imageFromDataUrl(value) {
  const match = /^data:([^;,]+);base64,(.+)$/s.exec(String(value));
  if (!match || !match[1].startsWith('image/')) throw new Error('Pi image context must be a base64 image data URL.');
  return { type: 'image', mimeType: match[1], data: match[2] };
}

function piMessageText(message, contentType = null) {
  if (typeof message?.content === 'string') return contentType && contentType !== 'text' ? '' : message.content;
  return (message?.content || [])
    .filter((content) => !contentType || content.type === contentType)
    .map((content) => content.text || '')
    .filter(Boolean)
    .join('\n');
}

function piToolText(payload, args) {
  const content = (payload?.content || []).map((item) => item.text || '').filter(Boolean).join('\n');
  if (content) return content;
  return args ? JSON.stringify(args) : '';
}
