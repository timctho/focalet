import { EventEmitter } from 'node:events';
import { readFile, writeFile } from 'node:fs/promises';
import { AcpAdapter } from './acp-adapter.mjs';
import { HermesGatewayAdapter } from './hermes-gateway-adapter.mjs';
import { OpenClawGatewayAdapter } from './openclaw-gateway-adapter.mjs';
import { PiRpcAdapter } from './pi-rpc-adapter.mjs';
import { PtyCompatibilityAdapter } from './pty-compatibility-adapter.mjs';
import { ptyCompatibilityProfile } from './pty-profiles.mjs';
import { CodexAppServerAdapter } from './codex-bridge.mjs';
import { RUNTIME_CATALOG, catalogEntry } from './runtime-catalog.mjs';
import { commandForTarget, selectDefaultTarget } from './runtime-discovery.mjs';
import {
  BROKER_PROTOCOL_VERSION,
  BrokerProtocolError,
  boundedPage,
  createClientOperationId,
  normalizeClientOperationId,
  operationFingerprint,
  sanitizeDiagnostic,
  serializeBrokerError,
  toBrokerProtocolError,
  validateBrokerRequest,
  validateCapabilities,
  validateTurnInput,
  validateTurnResult,
} from './broker-protocol.mjs';

const PREFERENCE_VERSION = 1;

export class RuntimeBroker extends EventEmitter {
  constructor(options = {}) {
    super();
    if (!options.discovery) throw new Error('RuntimeBroker requires RuntimeDiscovery.');
    this.discovery = options.discovery;
    this.catalog = options.catalog ?? RUNTIME_CATALOG;
    this.preferencePath = options.preferencePath ?? null;
    this.adapterFactory = options.adapterFactory ?? createDefaultRuntimeAdapter;
    this.autoWarm = options.autoWarm ?? true;
    this.targets = [];
    this.activeTargetId = null;
    this.adapters = new Map();
    this.activationPromises = new Map();
    this.activationTokens = new Map();
    this.initializationPromise = null;
    this.activeTargetPinned = false;
    this.operations = new Map();
    this.turnOperations = new Map();
    this.eventSequences = new Map();
    this.startedTurns = new Set();
    this.terminalTurns = new Set();
    this.pendingApprovals = new Map();
    this.pendingQuestions = new Map();
    this.transportMetrics = [];
    this.preferencesLoaded = false;
    this.preferences = {
      version: PREFERENCE_VERSION,
      lastSelectedTargetId: null,
      bindings: {},
    };
    this.discovery.on('targetsChanged', (targets) => this.#applyDiscoveredTargets(targets));
    this.discovery.on('hostError', ({ host, error }) => {
      const payload = {
        targetId: null,
        status: 'unreachable',
        message: `${host.displayName} discovery unavailable: ${error}`,
        warning: true,
      };
      if (host.isDefault || host.kind === 'native') this.emit('status', payload);
      else this.emit('diagnostic', payload);
    });
  }

  initialize() {
    this.initializationPromise ??= this.#initialize().catch((error) => {
      this.initializationPromise = null;
      throw error;
    });
    return this.initializationPromise;
  }

  listTargets() {
    return this.targets.map((target) => ({
      ...target,
      executionHost: { ...target.executionHost },
      handshake: target.handshake ? { ...target.handshake } : null,
      capabilities: [...(target.capabilities || [])],
      capabilityHints: [...(target.capabilityHints || [])],
    }));
  }

  getRuntimeState() {
    const activeTarget = this.targets.find((target) => target.id === this.activeTargetId) || null;
    return {
      protocolVersion: BROKER_PROTOCOL_VERSION,
      targets: this.listTargets(),
      activeTargetId: activeTarget?.id || null,
      activeTarget,
      capabilities: activeTarget ? [...activeTarget.capabilities] : [],
      settings: this.discovery.getSettingsState?.() || { hosts: [], adapters: [], overrides: [] },
    };
  }

  getStatus(targetId = this.activeTargetId) {
    return this.targets.find((target) => target.id === targetId) || null;
  }

  getTransportMetrics() {
    return this.transportMetrics.map((metric) => ({ ...metric }));
  }

  async probeTransportWrite(transport = {}) {
    const { adapter, target } = await this.#activeAdapter();
    if (typeof adapter.probeTransportWrite !== 'function') {
      throw new BrokerProtocolError('capability-unavailable', 'This runtime has no read-only transport diagnostic.');
    }
    const clientOperationId = createClientOperationId();
    await adapter.probeTransportWrite({ clientOperationId, transport });
    const metric = [...this.transportMetrics].reverse().find((value) => value.clientOperationId === clientOperationId);
    if (!metric) throw new Error('Runtime did not report its protocol write boundary.');
    return { ok: true, runtimeTargetId: target.id, metric };
  }

  async refreshTargets(hostId = null) {
    await this.initialize();
    const targets = await this.discovery.refresh(hostId);
    this.#applyDiscoveredTargets(targets);
    return this.getRuntimeState();
  }

  async rediscoverTargets() {
    await this.initialize();
    const targets = await this.discovery.discover({ force: false });
    this.#applyDiscoveredTargets(targets);
    void this.discovery.waitForBackground().then((complete) => this.#applyDiscoveredTargets(complete));
    return this.getRuntimeState();
  }

  async saveRuntimeOverride(value) {
    await this.initialize();
    const targets = await this.discovery.upsertOverride(value);
    this.#applyDiscoveredTargets(targets);
    return this.getRuntimeState();
  }

  async removeRuntimeOverride(id) {
    await this.initialize();
    const targets = await this.discovery.removeOverride(id);
    this.#applyDiscoveredTargets(targets);
    return this.getRuntimeState();
  }

  async selectTarget(targetId, { activate = true } = {}) {
    await this.initialize();
    const target = this.targets.find((candidate) => candidate.id === targetId);
    if (!target) throw new Error(`Unknown Runtime Target '${targetId}'.`);
    if (this.activeTargetId && this.activeTargetId !== target.id) {
      this.#cancelActivation(this.activeTargetId);
    }
    this.activeTargetId = target.id;
    this.activeTargetPinned = true;
    this.preferences.lastSelectedTargetId = target.id;
    await this.#savePreferences();
    this.emit('targetsChanged', this.getRuntimeState());
    if (activate) await this.activateTarget(target.id);
    return this.getRuntimeState();
  }

  async activateTarget(targetId = this.activeTargetId) {
    await this.initialize();
    const target = this.targets.find((candidate) => candidate.id === targetId);
    if (!target) throw new Error('No supported agent runtime was found. Install a supported CLI, then refresh.');
    if (this.adapters.has(target.id) && target.status === 'ready') return this.adapters.get(target.id);
    if (this.activationPromises.has(target.id)) return this.activationPromises.get(target.id);
    const token = {};
    this.activationTokens.set(target.id, token);
    const promise = this.#activate(target, token).finally(() => {
      if (this.activationTokens.get(target.id) === token) this.activationTokens.delete(target.id);
      if (this.activationPromises.get(target.id) === promise) this.activationPromises.delete(target.id);
    });
    this.activationPromises.set(target.id, promise);
    return promise;
  }

  async warmSelectedTarget() {
    await this.initialize();
    const attempted = new Set();
    while (this.activeTargetId && !attempted.has(this.activeTargetId)) {
      const target = this.targets.find((candidate) => candidate.id === this.activeTargetId);
      if (!target) break;
      attempted.add(target.id);
      try {
        return await this.activateTarget(target.id);
      } catch (error) {
        const canFallback = !this.activeTargetPinned
          && !this.preferences.bindings[target.id]
          && classifyRuntimeError(error) === 'unsupported-version';
        const next = canFallback
          ? selectDefaultTarget(this.targets.filter((candidate) => candidate.runtimeId === target.runtimeId
            && !attempted.has(candidate.id)))
          : null;
        if (!next) throw error;
        this.activeTargetId = next.id;
        this.emit('targetsChanged', this.getRuntimeState());
      }
    }
    throw new Error('No supported agent runtime could complete its machine-protocol handshake.');
  }

  async getChatState() {
    const { adapter, target } = await this.#activeAdapter();
    const state = await adapter.getChatState();
    await this.#recordBinding(target.id, state?.activeThreadId || state?.thread?.id, state?.sessionMetadata);
    return this.#decorateChatState(state, target);
  }

  async createSession(options = {}) {
    const { adapter, target } = await this.#activeAdapter();
    const state = await adapter.createSession(options);
    await this.#recordBinding(target.id, state?.activeThreadId || state?.thread?.id, state?.sessionMetadata);
    return this.#decorateChatState(state, target);
  }

  async switchSession(sessionId) {
    if (!sessionId) throw new Error('An Agent Session id is required.');
    const { adapter, target } = await this.#activeAdapter();
    const state = await adapter.switchSession(sessionId);
    await this.#recordBinding(target.id, state?.activeThreadId || state?.thread?.id, state?.sessionMetadata);
    return this.#decorateChatState(state, target);
  }

  async startTurn(message, snapshots = [], images = [], options = {}) {
    const { adapter, target } = await this.#activeAdapter();
    const input = validateTurnInput(message, snapshots, images);
    const clientOperationId = normalizeClientOperationId(options.clientOperationId);
    const fingerprint = operationFingerprint({
      runtimeTargetId: target.id,
      message: input.message,
      snapshots: input.snapshots,
      images: input.images,
      options: { ...options, clientOperationId: undefined, transport: undefined },
    });
    const previous = this.operations.get(clientOperationId);
    if (previous) {
      if (previous.fingerprint !== fingerprint) {
        throw new BrokerProtocolError('conflict', 'clientOperationId was reused for a different turn.');
      }
      if (previous.error) throw previous.error;
      if (previous.result) return previous.result;
      return previous.promise;
    }

    const record = { fingerprint, promise: null, result: null, error: null };
    const promise = (async () => {
      try {
        const nativeResult = await adapter.startTurn(
          input.message,
          input.snapshots,
          input.images,
          { ...options, clientOperationId },
        );
        const result = {
          ...validateTurnResult(nativeResult),
          runtimeTargetId: target.id,
          clientOperationId,
        };
        await this.#recordBinding(target.id, result.threadId, result.sessionMetadata);
        this.#rememberTurnOperation(target.id, result.threadId, result.turnId, clientOperationId);
        this.#emitBrokerEvent(target, 'turn.accepted', result);
        record.result = result;
        return result;
      } catch (error) {
        const normalized = toBrokerProtocolError(error);
        record.error = normalized;
        this.#applyOperationError(target.id, normalized);
        throw normalized;
      } finally {
        this.#pruneOperations();
      }
    })();
    record.promise = promise;
    this.operations.set(clientOperationId, record);
    return promise;
  }

  async steerTurn(message, images = [], identity = {}) {
    const { adapter, target } = await this.#activeAdapter();
    this.#assertIdentityTarget(identity.runtimeTargetId, target.id);
    if (!target.capabilities.includes('turn.steer.v1') || typeof adapter.steerTurn !== 'function') {
      throw new BrokerProtocolError('capability-unavailable', 'The selected runtime does not support same-turn steering.');
    }
    const input = validateTurnInput(message, [], images);
    const result = await adapter.steerTurn(input.message, input.images, identity);
    if (identity.sessionId && String(result?.threadId) !== String(identity.sessionId)) {
      throw new BrokerProtocolError('conflict', 'Runtime steering resolved a different Agent Session.');
    }
    if (identity.turnId && String(result?.turnId) !== String(identity.turnId)) {
      throw new BrokerProtocolError('conflict', 'Runtime steering resolved a different turn.');
    }
    return { ...result, runtimeTargetId: target.id };
  }

  async interruptTurn(identity = {}) {
    const { adapter, target } = await this.#activeAdapter();
    this.#assertIdentityTarget(identity.runtimeTargetId, target.id);
    const result = await adapter.interruptTurn(identity);
    if (identity.sessionId && String(result?.threadId) !== String(identity.sessionId)) {
      throw new BrokerProtocolError('conflict', 'Runtime interruption resolved a different Agent Session.');
    }
    if (identity.turnId && String(result?.turnId) !== String(identity.turnId)) {
      throw new BrokerProtocolError('conflict', 'Runtime interruption resolved a different turn.');
    }
    return { ...result, runtimeTargetId: target.id };
  }

  async request(request) {
    let envelope;
    try {
      envelope = validateBrokerRequest(request);
      const result = await this.#dispatchRequest(envelope);
      return {
        protocolVersion: BROKER_PROTOCOL_VERSION,
        clientOperationId: envelope.clientOperationId,
        ok: true,
        result,
      };
    } catch (error) {
      return {
        protocolVersion: BROKER_PROTOCOL_VERSION,
        clientOperationId: envelope?.clientOperationId || request?.clientOperationId || null,
        ok: false,
        error: serializeBrokerError(error),
      };
    }
  }

  async resolveApproval(approvalId, optionId = null, identity = {}) {
    const resolvedIdentity = normalizeResolutionIdentity(identity, this.activeTargetId);
    this.#assertPendingResolution(this.pendingApprovals, approvalId, resolvedIdentity);
    const targetId = resolvedIdentity.runtimeTargetId;
    const adapter = await this.activateTarget(targetId);
    if (typeof adapter.resolveApproval !== 'function') throw new Error('This runtime does not support structured approvals.');
    const result = await adapter.resolveApproval(approvalId, optionId);
    this.pendingApprovals.delete(String(approvalId));
    return result;
  }

  async resolveQuestion(questionId, answer = {}, identity = {}) {
    const resolvedIdentity = normalizeResolutionIdentity(identity, this.activeTargetId);
    this.#assertPendingResolution(this.pendingQuestions, questionId, resolvedIdentity);
    const targetId = resolvedIdentity.runtimeTargetId;
    const adapter = await this.activateTarget(targetId);
    if (typeof adapter.resolveQuestion !== 'function') throw new Error('This runtime does not support structured questions.');
    const result = await adapter.resolveQuestion(questionId, answer);
    this.pendingQuestions.delete(String(questionId));
    return result;
  }

  getSignInLaunch(targetId = this.activeTargetId) {
    const target = this.targets.find((candidate) => candidate.id === targetId);
    if (!target) throw new Error(`Unknown Runtime Target '${targetId}'.`);
    const entry = catalogEntry(target.adapterId, this.catalog);
    if (!entry?.signInArgs?.length) return null;
    if (target.executionHost.kind === 'wsl') {
      return {
        command: 'wsl.exe',
        args: ['-d', target.executionHost.name, '-e', target.executablePath, ...entry.signInArgs],
        displayCommand: `${target.executableName} ${entry.signInArgs.join(' ')}`,
        executionHost: target.executionHost,
      };
    }
    return {
      command: target.executablePath,
      args: [...entry.signInArgs],
      displayCommand: `${target.executableName} ${entry.signInArgs.join(' ')}`,
      executionHost: target.executionHost,
    };
  }

  stop() {
    this.activationTokens.clear();
    for (const adapter of this.adapters.values()) adapter.stop?.();
    this.adapters.clear();
    this.activationPromises.clear();
    this.operations.clear();
    this.turnOperations.clear();
    this.startedTurns.clear();
    this.terminalTurns.clear();
    this.pendingApprovals.clear();
    this.pendingQuestions.clear();
  }

  async #initialize() {
    await this.#loadPreferences();
    const targets = await this.discovery.discover();
    this.#applyDiscoveredTargets(targets);
    if (this.autoWarm && this.activeTargetId) {
      void this.warmSelectedTarget().catch(() => {});
    }
    void this.discovery.waitForBackground().then((complete) => this.#applyDiscoveredTargets(complete));
    return this.getRuntimeState();
  }

  async #activate(target, token) {
    this.#setTargetStatus(target.id, 'starting', `Starting ${target.displayName} ${target.protocolName}…`);
    let adapter = this.adapters.get(target.id);
    if (!adapter) {
      const entry = catalogEntry(target.adapterId, this.catalog);
      if (!entry) throw new Error(`Runtime catalog entry '${target.adapterId}' is missing.`);
      adapter = await this.adapterFactory(target, {
        entry,
        binding: this.preferences.bindings[target.id] || null,
      });
      this.#wireAdapter(target, adapter);
      this.adapters.set(target.id, adapter);
    }
    try {
      await adapter.ensureStarted();
      if (this.activationTokens.get(target.id) !== token) {
        throw new BrokerProtocolError('operation-cancelled', 'Runtime warm-up was cancelled.');
      }
      if (Array.isArray(adapter.capabilities)) {
        const capabilities = validateCapabilities(adapter.capabilities);
        const protocolVersion = adapter.protocolVersion;
        if (candidateMinimumProtocolVersion(target) !== null
          && (!Number.isFinite(Number(protocolVersion))
            || Number(protocolVersion) < candidateMinimumProtocolVersion(target))) {
          throw new BrokerProtocolError(
            'unsupported-version',
            `${target.displayName} ${target.protocolName} negotiated unsupported protocol version ${String(protocolVersion)}.`,
          );
        }
        this.targets = this.targets.map((candidate) => candidate.id === target.id
          ? {
            ...candidate,
            capabilities,
            protocolVersion: protocolVersion ?? null,
            runtimeVersion: adapter.runtimeVersion ?? candidate.runtimeVersion ?? null,
          }
          : candidate);
      }
      this.#setTargetStatus(target.id, 'ready', `${target.displayName} ready · ${target.executionHost.displayName}`);
      return adapter;
    } catch (error) {
      this.adapters.delete(target.id);
      adapter.stop?.();
      if (this.activationTokens.get(target.id) !== token) {
        if (this.getStatus(target.id)?.status === 'starting') {
          this.#setTargetStatus(target.id, 'detected', `${target.displayName} detected`);
        }
        throw new BrokerProtocolError('operation-cancelled', 'Runtime warm-up was cancelled.');
      }
      this.#applyOperationError(target.id, error);
      if (isExecutableMissingError(error)) this.discovery.invalidateTarget(target);
      throw error;
    }
  }

  async #activeAdapter() {
    await this.initialize();
    if (!this.activeTargetId) throw new Error('No supported agent runtime was found. Install a supported CLI, then refresh.');
    const adapter = this.activeTargetPinned
      ? await this.activateTarget(this.activeTargetId)
      : await this.warmSelectedTarget();
    const target = this.targets.find((candidate) => candidate.id === this.activeTargetId);
    if (!target) throw new Error('The active Runtime Target disappeared during activation.');
    return { adapter, target };
  }

  #wireAdapter(target, adapter) {
    adapter.on?.('status', (message) => {
      const payload = {
        targetId: target.id,
        status: this.getStatus(target.id)?.status || 'starting',
        message: sanitizeDiagnostic(message),
        warning: isWarningStatus(message),
      };
      this.emit('status', this.#decorateLegacyEvent(target, 'runtime.status', payload));
    });
    adapter.on?.('diagnostic', (diagnostic = {}) => {
      this.emit('diagnostic', {
        targetId: target.id,
        status: this.getStatus(target.id)?.status || 'starting',
        message: sanitizeDiagnostic(diagnostic.message || 'Runtime retained an unknown native event.'),
        warning: false,
        ...(diagnostic.nativeEvent ? { nativeEvent: diagnostic.nativeEvent } : {}),
      });
    });
    adapter.on?.('protocolWrite', (metric = {}) => {
      const decorated = {
        ...metric,
        runtimeTargetId: target.id,
        adapterId: target.adapterId,
        classification: target.classification,
      };
      this.transportMetrics.push(decorated);
      while (this.transportMetrics.length > 512) this.transportMetrics.shift();
      this.emit('transportMetric', decorated);
    });
    adapter.on?.('streamUpdate', (update) => {
      if (this.#isTerminalTurn(target, update)) {
        this.emit('diagnostic', {
          targetId: target.id,
          status: this.getStatus(target.id)?.status || 'ready',
          message: 'Runtime emitted a late stream event after the turn reached a terminal state.',
          warning: false,
        });
        return;
      }
      this.#emitTurnStarted(target, update);
      const type = streamEventType(update);
      this.emit('streamUpdate', this.#decorateLegacyEvent(target, type, update));
    });
    adapter.on?.('turnCompleted', (completion) => {
      if (this.#isTerminalTurn(target, completion)) {
        this.emit('diagnostic', {
          targetId: target.id,
          status: this.getStatus(target.id)?.status || 'ready',
          message: 'Runtime emitted a duplicate terminal turn event.',
          warning: false,
        });
        return;
      }
      this.#emitTurnStarted(target, completion);
      const status = String(completion?.status || 'failed');
      const type = status === 'completed' ? 'turn.completed' : status === 'interrupted' ? 'turn.interrupted' : 'turn.failed';
      this.emit('turnCompleted', this.#decorateLegacyEvent(target, type, completion));
    });
    adapter.on?.('approvalRequested', (request) => {
      const decorated = this.#decorateLegacyEvent(target, 'approval.requested', request);
      this.pendingApprovals.set(String(request.approvalId), {
        runtimeTargetId: target.id,
        sessionId: decorated.sessionId,
      });
      this.#prunePendingResolutions(this.pendingApprovals);
      this.emit('approvalRequested', decorated);
    });
    adapter.on?.('questionRequested', (request) => {
      const decorated = this.#decorateLegacyEvent(target, 'question.requested', request);
      this.pendingQuestions.set(String(request.questionId), {
        runtimeTargetId: target.id,
        sessionId: decorated.sessionId,
      });
      this.#prunePendingResolutions(this.pendingQuestions);
      this.emit('questionRequested', decorated);
    });
  }

  #applyDiscoveredTargets(discovered) {
    const previous = new Map(this.targets.map((target) => [target.id, target]));
    const discoveredIds = new Set((discovered || []).map((target) => target.id));
    for (const [targetId, adapter] of this.adapters) {
      if (discoveredIds.has(targetId)) continue;
      adapter.stop?.();
      this.adapters.delete(targetId);
      this.activationPromises.delete(targetId);
      this.activationTokens.delete(targetId);
    }
    this.targets = (discovered || []).map((target) => ({
      ...target,
      capabilities: [...(previous.get(target.id)?.capabilities || target.capabilities || [])],
      protocolVersion: previous.get(target.id)?.protocolVersion ?? target.protocolVersion ?? null,
      runtimeVersion: previous.get(target.id)?.runtimeVersion ?? target.runtimeVersion ?? null,
      status: previous.get(target.id)?.status || target.status || 'detected',
      statusMessage: previous.get(target.id)?.statusMessage || null,
    }));
    const boundTargetId = this.activeTargetId && this.adapters.has(this.activeTargetId)
      ? this.activeTargetId
      : null;
    const selected = selectDefaultTarget(this.targets, {
      boundTargetId,
      lastSelectedTargetId: this.preferences.lastSelectedTargetId,
    });
    if (!boundTargetId) {
      this.activeTargetId = selected?.id || null;
      this.activeTargetPinned = Boolean(selected && (
        this.preferences.lastSelectedTargetId === selected.id
        || this.preferences.bindings[selected.id]
      ));
    }
    this.emit('targetsChanged', this.getRuntimeState());
  }

  #setTargetStatus(targetId, status, message) {
    this.targets = this.targets.map((target) => target.id === targetId
      ? { ...target, status, statusMessage: message }
      : target);
    this.emit('status', {
      targetId,
      status,
      message: sanitizeDiagnostic(message),
      warning: ['sign-in-required', 'unsupported-version', 'unreachable'].includes(status),
    });
    this.emit('targetsChanged', this.getRuntimeState());
  }

  #applyOperationError(targetId, error) {
    const classification = targetStateForError(error);
    const target = this.targets.find((candidate) => candidate.id === targetId);
    if (!classification) {
      this.emit('status', {
        targetId,
        status: target?.status || 'detected',
        message: sanitizeDiagnostic(error),
        warning: true,
      });
      return;
    }
    const message = classification === 'sign-in-required'
      ? `${target?.displayName || 'Agent'} sign-in required`
      : sanitizeDiagnostic(error);
    this.#setTargetStatus(targetId, classification, message);
  }

  #decorateChatState(state, target) {
    return {
      ...state,
      runtime: this.getRuntimeState(),
      runtimeTargetId: target.id,
      capabilities: [...target.capabilities],
      sessionBinding: state?.activeThreadId
        ? { runtimeTargetId: target.id, sessionId: state.activeThreadId }
        : null,
    };
  }

  async #recordBinding(targetId, sessionId, metadata = null) {
    const bindingSessionId = metadata?.sessionKey || sessionId;
    if (!targetId || !bindingSessionId) return;
    this.preferences.bindings[targetId] = {
      sessionId: String(bindingSessionId),
      ...(metadata?.sessionFile ? { sessionFile: String(metadata.sessionFile) } : {}),
    };
    if (targetId === this.activeTargetId) this.activeTargetPinned = true;
    await this.#savePreferences();
  }

  async #loadPreferences() {
    if (this.preferencesLoaded) return;
    this.preferencesLoaded = true;
    if (!this.preferencePath) return;
    try {
      const parsed = JSON.parse(await readFile(this.preferencePath, 'utf8'));
      if (parsed?.version === PREFERENCE_VERSION) {
        this.preferences = {
          version: PREFERENCE_VERSION,
          lastSelectedTargetId: parsed.lastSelectedTargetId || null,
          bindings: parsed.bindings || {},
        };
      }
    } catch {
      // Missing or invalid preferences are a normal first launch.
    }
  }

  async #savePreferences() {
    if (!this.preferencePath) return;
    await writeFile(this.preferencePath, `${JSON.stringify(this.preferences, null, 2)}\n`, 'utf8');
  }

  async #dispatchRequest(envelope) {
    await this.initialize();
    const { operation, payload } = envelope;
    if (operation === 'runtime.listTargets') {
      return { targets: this.listTargets() };
    }
    if (operation === 'runtime.refreshTargets') return this.refreshTargets(payload.hostId || null);
    if (operation === 'runtime.getStatus') {
      return this.getStatus(envelope.runtimeTargetId || payload.runtimeTargetId || undefined);
    }
    if (operation === 'session.list') {
      this.#assertIdentityTarget(envelope.runtimeTargetId, this.activeTargetId);
      const state = await this.getChatState();
      return boundedPage(state.sessions, payload.cursor, payload.limit);
    }
    if (operation === 'session.create') {
      this.#assertIdentityTarget(envelope.runtimeTargetId, this.activeTargetId);
      return this.createSession(payload.options || payload);
    }
    if (operation === 'session.open') {
      this.#assertIdentityTarget(envelope.runtimeTargetId, this.activeTargetId);
      const sessionId = envelope.sessionId || payload.sessionId;
      if (!sessionId) throw new BrokerProtocolError('invalid-request', 'session.open requires sessionId.');
      return this.switchSession(sessionId);
    }
    if (operation === 'session.read') {
      this.#assertIdentityTarget(envelope.runtimeTargetId, this.activeTargetId);
      const state = await this.getChatState();
      const sessionId = envelope.sessionId || payload.sessionId || state.activeThreadId;
      if (String(sessionId) !== String(state.activeThreadId)) {
        throw new BrokerProtocolError('capability-unavailable', 'This adapter can read only its exactly bound active session without rebinding.');
      }
      const page = boundedPage(state.thread?.turns, payload.cursor, payload.limit);
      return { sessionId: String(sessionId), ...page };
    }
    if (operation === 'turn.start') {
      this.#assertIdentityTarget(envelope.runtimeTargetId, this.activeTargetId);
      const state = await this.getChatState();
      if (String(envelope.sessionId) !== String(state.activeThreadId || '')) {
        throw new BrokerProtocolError('conflict', 'turn.start Session does not match the active Session Binding.');
      }
      return this.startTurn(
        payload.message,
        payload.snapshots || [],
        payload.images || [],
        { ...(payload.options || {}), clientOperationId: envelope.clientOperationId },
      );
    }
    if (operation === 'turn.steer') {
      return this.steerTurn(payload.message, payload.images || [], envelope);
    }
    if (operation === 'turn.interrupt') return this.interruptTurn(envelope);
    if (operation === 'approval.resolve') {
      return this.resolveApproval(payload.approvalId, payload.optionId || null, envelope);
    }
    if (operation === 'question.resolve') {
      return this.resolveQuestion(payload.questionId, payload.answer || {}, envelope);
    }
    if (operation === 'events.subscribe') {
      this.#assertIdentityTarget(envelope.runtimeTargetId, this.activeTargetId);
      const chat = await this.getChatState();
      return {
        snapshot: { runtime: this.getRuntimeState(), chat },
        sequence: this.#currentSequence(this.activeTargetId, envelope.sessionId || chat.activeThreadId),
      };
    }
    throw new BrokerProtocolError('unsupported-operation', `Unsupported broker operation '${operation}'.`);
  }

  #decorateLegacyEvent(target, type, payload = {}) {
    const event = this.#emitBrokerEvent(target, type, payload);
    return {
      ...payload,
      runtimeTargetId: target.id,
      sessionId: event.sessionId,
      turnId: event.turnId,
      clientOperationId: event.clientOperationId,
      brokerSequence: event.sequence,
      brokerEventType: type,
      protocolVersion: BROKER_PROTOCOL_VERSION,
    };
  }

  #emitBrokerEvent(target, type, payload = {}) {
    const sessionId = payload.sessionId || payload.threadId || null;
    const turnId = payload.turnId || null;
    const clientOperationId = payload.clientOperationId
      || this.#findTurnOperation(target.id, sessionId, turnId);
    const key = `${target.id}:${sessionId || '<runtime>'}`;
    const sequence = (this.eventSequences.get(key) || 0) + 1;
    this.eventSequences.set(key, sequence);
    const event = {
      protocolVersion: BROKER_PROTOCOL_VERSION,
      sequence,
      type,
      runtimeTargetId: target.id,
      sessionId,
      turnId,
      clientOperationId: clientOperationId || null,
      payload,
    };
    this.emit('event', event);
    if (type.startsWith('turn.') && ['turn.completed', 'turn.interrupted', 'turn.failed'].includes(type)) {
      const terminalKey = this.#turnKey(target, payload);
      if (terminalKey) {
        this.terminalTurns.add(terminalKey);
        while (this.terminalTurns.size > 512) this.terminalTurns.delete(this.terminalTurns.values().next().value);
      }
      this.startedTurns.delete(`${target.id}:${sessionId}:${turnId}`);
      this.#forgetTurnOperation(target.id, sessionId, turnId);
    }
    return event;
  }

  #rememberTurnOperation(targetId, sessionId, turnId, clientOperationId) {
    this.turnOperations.set(`${targetId}:${sessionId}:${turnId}`, clientOperationId);
    this.turnOperations.set(`${targetId}:${sessionId}:<active>`, clientOperationId);
  }

  #emitTurnStarted(target, payload = {}) {
    const sessionId = payload.sessionId || payload.threadId || null;
    const turnId = payload.turnId || null;
    if (!sessionId || !turnId) return;
    const key = `${target.id}:${sessionId}:${turnId}`;
    if (this.startedTurns.has(key)) return;
    this.startedTurns.add(key);
    this.#emitBrokerEvent(target, 'turn.started', payload);
  }

  #isTerminalTurn(target, payload = {}) {
    const key = this.#turnKey(target, payload);
    return Boolean(key && this.terminalTurns.has(key));
  }

  #turnKey(target, payload = {}) {
    const sessionId = payload.sessionId || payload.threadId || null;
    const turnId = payload.turnId || null;
    return sessionId && turnId ? `${target.id}:${sessionId}:${turnId}` : null;
  }

  #findTurnOperation(targetId, sessionId, turnId) {
    if (!sessionId) return null;
    return this.turnOperations.get(`${targetId}:${sessionId}:${turnId || '<active>'}`)
      || this.turnOperations.get(`${targetId}:${sessionId}:<active>`)
      || null;
  }

  #forgetTurnOperation(targetId, sessionId, turnId) {
    if (!sessionId) return;
    this.turnOperations.delete(`${targetId}:${sessionId}:${turnId || '<active>'}`);
    this.turnOperations.delete(`${targetId}:${sessionId}:<active>`);
  }

  #currentSequence(targetId, sessionId) {
    return this.eventSequences.get(`${targetId}:${sessionId || '<runtime>'}`) || 0;
  }

  #assertIdentityTarget(requested, active) {
    if (requested && String(requested) !== String(active || '')) {
      throw new BrokerProtocolError('conflict', 'Request Runtime Target does not match the active Session Binding. Select it explicitly first.');
    }
  }

  #assertPendingResolution(pending, requestId, identity) {
    const record = pending.get(String(requestId));
    if (!record) throw new BrokerProtocolError('invalid-request', `Unknown or expired runtime request '${requestId}'.`);
    if (String(record.runtimeTargetId) !== String(identity.runtimeTargetId || '')) {
      throw new BrokerProtocolError('conflict', 'Runtime request target identity does not match its origin.');
    }
    if (record.sessionId && String(record.sessionId) !== String(identity.sessionId || '')) {
      throw new BrokerProtocolError('conflict', 'Runtime request Session identity does not match its origin.');
    }
  }

  #prunePendingResolutions(pending) {
    while (pending.size > 256) pending.delete(pending.keys().next().value);
  }

  #cancelActivation(targetId) {
    if (!targetId || !this.activationTokens.has(targetId)) return;
    this.activationTokens.delete(targetId);
    this.activationPromises.delete(targetId);
    const adapter = this.adapters.get(targetId);
    adapter?.stop?.();
    this.adapters.delete(targetId);
    const target = this.getStatus(targetId);
    if (target?.status === 'starting') {
      this.#setTargetStatus(targetId, 'detected', `${target.displayName} detected`);
    }
  }

  #pruneOperations() {
    while (this.operations.size > 256) {
      const oldest = this.operations.keys().next().value;
      this.operations.delete(oldest);
    }
  }
}

function normalizeResolutionIdentity(identity, fallbackTargetId) {
  if (typeof identity === 'string') return { runtimeTargetId: identity, sessionId: null };
  return {
    runtimeTargetId: identity?.runtimeTargetId || fallbackTargetId || null,
    sessionId: identity?.sessionId || null,
  };
}

export function createDefaultRuntimeAdapter(target, { entry, binding } = {}) {
  if (target.adapterId === 'openclaw-gateway' && target.endpoint) {
    return new OpenClawGatewayAdapter({
      url: target.endpoint,
      preferredSessionId: binding?.sessionId || null,
      executionHost: target.executionHost,
    });
  }
  const launch = commandForTarget(target, entry);
  const options = {
    command: launch.command,
    commandArgs: launch.args,
    ...(target.runtimeHome ? { cwd: target.runtimeHome } : {}),
    preferredSessionId: binding?.sessionId || null,
  };
  if (target.adapterId === 'codex-app-server') return new CodexAppServerAdapter(options);
  if (target.adapterId === 'hermes-acp') return new AcpAdapter({
    ...options,
    runtimeDisplayName: 'Hermes',
    signInHint: 'run hermes acp --setup',
  });
  if (target.adapterId === 'openclaw-acp') return new AcpAdapter({
    ...options,
    runtimeDisplayName: 'OpenClaw',
    signInHint: 'run openclaw onboard',
  });
  if (target.adapterId === 'hermes-gateway') return new HermesGatewayAdapter({
    ...options,
    executionHost: target.executionHost,
  });
  if (target.adapterId === 'openclaw-gateway') return new OpenClawGatewayAdapter({
    ...options,
    executionHost: target.executionHost,
  });
  if (target.adapterId === 'pi-rpc') return new PiRpcAdapter({
    ...options,
    preferredSessionFile: binding?.sessionFile || null,
  });
  if (target.classification === 'compatible') return new PtyCompatibilityAdapter({
    ...options,
    target,
    profile: ptyCompatibilityProfile(target.runtimeId),
  });
  throw new Error(`${target.displayName} ${target.protocolName} is detected but this Zommi build does not support its machine protocol.`);
}

export function classifyRuntimeError(error) {
  const message = String(error?.message || error);
  if (/sign[ -]?in|log[ -]?in|not authenticated|unauthenticated|authentication required|missing credentials/i.test(message)) {
    return 'sign-in-required';
  }
  if (/unsupported|unknown (?:option|command)|version.+(?:old|require)/i.test(message)) return 'unsupported-version';
  return 'unreachable';
}

function targetStateForError(error) {
  if (error instanceof BrokerProtocolError) {
    if (error.code === 'authentication-required') return 'sign-in-required';
    if (error.code === 'unsupported-version') return 'unsupported-version';
    if (['ambiguous-outcome', 'capability-unavailable', 'conflict', 'input-too-large',
      'invalid-request', 'operation-cancelled', 'unsupported-operation']
      .includes(error.code)) return null;
  }
  return classifyRuntimeError(error);
}

function candidateMinimumProtocolVersion(target) {
  const value = target?.minimumProtocolVersion;
  return value === null || value === undefined ? null : Number(value);
}

function isExecutableMissingError(error) {
  return error?.code === 'ENOENT' || /ENOENT|not recognized|not found/i.test(String(error?.message || error));
}

function isWarningStatus(message) {
  return /error|failed|exited|unavailable|timed? out|did not respond|sign[ -]?in/i.test(String(message));
}

function streamEventType(update = {}) {
  const kind = String(update.kind || 'tool').toLowerCase();
  const lifecycle = String(update.lifecycle || 'delta').toLowerCase();
  if (kind === 'assistant') return lifecycle === 'completed' ? 'assistant.message' : 'assistant.delta';
  if (kind === 'thinking' || kind === 'reasoning') return 'reasoning.delta';
  if (kind === 'plan') return 'plan.updated';
  if (lifecycle === 'started') return 'tool.started';
  if (lifecycle === 'completed') return 'tool.completed';
  return 'tool.updated';
}
