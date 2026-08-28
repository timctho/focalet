import { randomUUID } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { spawn } from 'node:child_process';
import { buildContextHandoff } from './context-handoff.mjs';
import { normalizeClientOperationId } from './broker-protocol.mjs';
import { emitProtocolWrite } from './transport-metrics.mjs';

export class PtyCompatibilityAdapter extends EventEmitter {
  constructor(options = {}) {
    super();
    if (!options.target) throw new Error('PTY compatibility requires an exact Runtime Target.');
    if (!options.profile) throw new Error(`No PTY compatibility profile exists for '${options.target.adapterId}'.`);
    this.target = options.target;
    this.profile = options.profile;
    this.spawnProcess = options.spawnProcess || spawnCompatibilityProcess;
    this.processEnv = options.env || process.env;
    this.startupTimeoutMs = options.startupTimeoutMs || this.profile.startupTimeoutMs || 20_000;
    this.completionSettleMs = options.completionSettleMs || this.profile.completionSettleMs || 650;
    this.protocolVersion = null;
    this.process = null;
    this.startPromise = null;
    this.ready = false;
    this.outputWindow = '';
    this.activeTurn = null;
    this.completionTimer = null;
    this.threadId = `compat-${randomUUID()}`;
    this.capabilities = ['turn.stream.v1'];
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
    return this.#chatState();
  }

  async createSession() {
    this.stop();
    this.threadId = `compat-${randomUUID()}`;
    await this.ensureStarted();
    return this.#chatState();
  }

  async switchSession() {
    throw new Error('Terminal compatibility does not provide canonical session resume.');
  }

  async startTurn(message, snapshots = [], images = [], options = {}) {
    await this.ensureStarted();
    if (this.activeTurn) throw new Error('This terminal compatibility session already has an active input.');
    if (images.length) throw new Error('This terminal compatibility profile does not support image attachments.');
    const turnId = randomUUID();
    const clientOperationId = normalizeClientOperationId(options.clientOperationId);
    this.activeTurn = { turnId, clientOperationId, output: '', sawOutput: false };
    this.outputWindow = '';
    const prompt = safeTerminalPrompt(buildContextHandoff(message, snapshots, 0));
    try {
      if (typeof this.process.write !== 'function') throw new Error('PTY compatibility transport is not writable.');
      emitProtocolWrite(this, 'terminal.input', clientOperationId, options.transport);
      this.process.write(encodeTerminalInput(prompt, this.profile.inputMode));
    } catch (error) {
      this.activeTurn = null;
      throw error;
    }
    this.emit('status', `${this.profile.displayName} input sent · terminal compatibility cannot prove runtime acknowledgement`);
    return {
      accepted: true,
      acknowledgement: 'transport-only',
      threadId: this.threadId,
      turnId,
      clientOperationId,
    };
  }

  async interruptTurn() {
    throw new Error('This terminal compatibility profile does not advertise reliable interruption.');
  }

  stop() {
    clearTimeout(this.completionTimer);
    this.completionTimer = null;
    if (this.process && !this.process.killed) this.process.kill?.();
    this.process = null;
    this.startPromise = null;
    this.ready = false;
    this.activeTurn = null;
  }

  async #start() {
    const launch = buildPtyCompatibilityLaunch(this.target, this.profile);
    this.emit('status', `Starting ${this.profile.displayName} in Compatible terminal mode…`);
    const terminal = this.spawnProcess(launch.command, launch.args, {
      name: 'xterm-256color',
      cols: 100,
      rows: 30,
      cwd: launch.cwd,
      env: this.processEnv,
    });
    this.process = terminal;
    const ready = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        cleanup();
        reject(new Error(`${this.profile.displayName} did not expose its configured terminal prompt within ${Math.ceil(this.startupTimeoutMs / 1000)} seconds.`));
      }, this.startupTimeoutMs);
      const cleanup = () => {
        clearTimeout(timer);
        this.off('terminalReady', onReady);
        terminal.off?.('error', onError);
        terminal.off?.('exit', onExit);
      };
      const onReady = () => { cleanup(); resolve(); };
      const onError = (error) => { cleanup(); reject(error); };
      const onExit = (event) => { cleanup(); reject(new Error(`${this.profile.displayName} terminal exited before it became ready (${terminalExitCode(event)}).`)); };
      this.on('terminalReady', onReady);
      terminal.on?.('error', onError);
      terminal.on?.('exit', onExit);
    });
    terminal.onData?.((data) => this.#handleData(data));
    terminal.onExit?.((event) => this.#handleExit(event));
    // Test and alternate transports may expose Node stream-style events.
    terminal.stdout?.setEncoding?.('utf8');
    terminal.stdout?.on?.('data', (data) => this.#handleData(data));
    terminal.stderr?.resume?.();
    terminal.on?.('exit', (code, signal) => this.#handleExit({ exitCode: code, signal }));
    await ready;
    this.ready = true;
    this.emit('status', `${this.profile.displayName} ready · Compatible mode, best-effort output`);
  }

  #handleData(data) {
    const text = stripTerminalControls(data);
    if (!text) return;
    this.outputWindow = `${this.outputWindow}${text}`.slice(-8_000);
    if (!this.ready && matchesAny(this.outputWindow, this.profile.readyPatterns)) this.emit('terminalReady');
    if (!this.activeTurn) return;
    this.activeTurn.output += text;
    this.activeTurn.sawOutput ||= Boolean(text.trim());
    this.emit('streamUpdate', {
      threadId: this.threadId,
      kind: 'assistant',
      lifecycle: 'delta',
      text,
      turnId: this.activeTurn.turnId,
      clientOperationId: this.activeTurn.clientOperationId,
    });
    if (this.activeTurn.sawOutput && matchesAny(this.outputWindow, this.profile.promptPatterns)) {
      clearTimeout(this.completionTimer);
      this.completionTimer = setTimeout(() => this.#completeBestEffort(), this.completionSettleMs);
    }
  }

  #completeBestEffort() {
    const turn = this.activeTurn;
    if (!turn) return;
    this.activeTurn = null;
    this.completionTimer = null;
    this.emit('turnCompleted', {
      threadId: this.threadId,
      turnId: turn.turnId,
      clientOperationId: turn.clientOperationId,
      status: 'completed',
      evidence: 'terminal-prompt-heuristic',
    });
  }

  #handleExit(event) {
    if (!this.process) return;
    const turn = this.activeTurn;
    this.process = null;
    this.startPromise = null;
    this.ready = false;
    this.activeTurn = null;
    clearTimeout(this.completionTimer);
    this.completionTimer = null;
    if (turn) {
      this.emit('turnCompleted', {
        threadId: this.threadId,
        turnId: turn.turnId,
        clientOperationId: turn.clientOperationId,
        status: 'failed',
        error: `${this.profile.displayName} terminal exited (${terminalExitCode(event)}).`,
      });
    }
  }

  #chatState() {
    return {
      activeThreadId: this.threadId,
      activeModel: null,
      activeEffort: null,
      models: [],
      sessions: [{ id: this.threadId, name: `${this.profile.displayName} Compatible`, preview: 'Non-canonical terminal session' }],
      activeTurns: this.activeTurn ? [{ threadId: this.threadId, turnId: this.activeTurn.turnId }] : [],
      thread: { id: this.threadId, turns: [] },
      historyAuthority: 'none',
    };
  }
}

function spawnCompatibilityProcess(command, args, options) {
  const child = spawn(command, args, {
    stdio: ['pipe', 'pipe', 'pipe'],
    cwd: options.cwd,
    env: options.env,
    windowsHide: true,
  });
  child.write = (data) => child.stdin.write(data);
  return child;
}

export function buildPtyCompatibilityLaunch(target, profile) {
  const platform = target.executionHost?.platform || process.platform;
  const agentArgs = [...(profile.launchArgs || [])];
  if (target.executionHost?.kind === 'wsl') {
    const commandText = posixCommand([target.executablePath, ...agentArgs]);
    return {
      command: 'wsl.exe',
      args: [
        '-d', target.executionHost.name,
        ...(target.runtimeHome ? ['--cd', target.runtimeHome] : []),
        '-e', 'script', '-qefc', `exec ${commandText}`, '/dev/null',
      ],
      cwd: undefined,
    };
  }
  if (platform === 'win32') {
    throw new Error('Native Windows terminal compatibility requires a packaged ConPTY backend. Install this CLI in WSL or use a protocol target.');
  }
  if (platform === 'darwin') {
    return {
      command: '/usr/bin/script',
      args: ['-q', '/dev/null', target.executablePath, ...agentArgs],
      cwd: target.runtimeHome,
    };
  }
  return {
    command: 'script',
    args: ['-qefc', `exec ${posixCommand([target.executablePath, ...agentArgs])}`, '/dev/null'],
    cwd: target.runtimeHome,
  };
}

export function stripTerminalControls(value) {
  return String(value || '')
    .replace(/\x1b\][^\x07]*(?:\x07|\x1b\\)/g, '')
    .replace(/\x1bP[\s\S]*?\x1b\\/g, '')
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '')
    .replace(/\r(?!\n)/g, '\n')
    .replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, '');
}

function safeTerminalPrompt(value) {
  return String(value || '').replace(/[\x00\x1b]/g, '');
}

function encodeTerminalInput(prompt, mode) {
  if (mode === 'bracketed-paste') return `\x1b[200~${prompt}\x1b[201~\r`;
  return `${prompt}\r`;
}

function matchesAny(value, patterns = []) {
  return patterns.some((pattern) => {
    pattern.lastIndex = 0;
    return pattern.test(value);
  });
}

function posixCommand(args) {
  return args.map((value) => `'${String(value).replaceAll("'", "'\\''")}'`).join(' ');
}

function terminalExitCode(event) {
  if (event && typeof event === 'object') return event.exitCode ?? event.code ?? event.signal ?? 'unknown';
  return event ?? 'unknown';
}
