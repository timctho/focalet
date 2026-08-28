export const RUNTIME_CATALOG_VERSION = 6;

const CODEX_CAPABILITIES = [
  'session.list.v1',
  'session.create.v1',
  'session.resume.v1',
  'history.read.v1',
  'turn.stream.v1',
  'turn.interrupt.v1',
  'input.image.v1',
  'model.select.v1',
  'reasoning.select.v1',
];

const PI_CAPABILITIES = [
  'session.create.v1',
  'session.resume.v1',
  'history.read.v1',
  'turn.stream.v1',
  'turn.interrupt.v1',
  'turn.steer.v1',
  'input.image.v1',
  'model.select.v1',
  'reasoning.select.v1',
  'question.resolve.v1',
];

const ACP_CAPABILITIES = [
  'session.list.v1',
  'session.create.v1',
  'session.resume.v1',
  'history.read.v1',
  'turn.stream.v1',
  'turn.interrupt.v1',
  'input.image.v1',
  'approval.resolve.v1',
  'question.resolve.v1',
  'model.select.v1',
];

const HERMES_GATEWAY_CAPABILITIES = [
  'session.list.v1',
  'session.create.v1',
  'session.resume.v1',
  'history.read.v1',
  'turn.stream.v1',
  'turn.interrupt.v1',
  'input.image.v1',
  'approval.resolve.v1',
  'question.resolve.v1',
  'model.select.v1',
  'reasoning.select.v1',
];

const OPENCLAW_GATEWAY_CAPABILITIES = [
  'session.list.v1',
  'session.create.v1',
  'session.resume.v1',
  'history.read.v1',
  'turn.stream.v1',
  'turn.interrupt.v1',
  'input.image.v1',
  'approval.resolve.v1',
  'question.resolve.v1',
  'operation.idempotency.v1',
];

const OPENCLAW_ACP_CAPABILITIES = [
  'session.list.v1',
  'session.create.v1',
  'session.resume.v1',
  'history.read.v1',
  'turn.stream.v1',
  'turn.interrupt.v1',
  'input.image.v1',
  'approval.resolve.v1',
];

export const RUNTIME_CATALOG = Object.freeze([
  Object.freeze({
    id: 'codex-app-server',
    runtimeId: 'codex',
    adapterId: 'codex-app-server',
    displayName: 'Codex',
    protocolName: 'app-server',
    executables: Object.freeze(['codex']),
    hostKinds: Object.freeze(['native', 'wsl']),
    launchArgs: Object.freeze(['app-server']),
    signInArgs: Object.freeze(['login']),
    machineMode: 'app-server',
    minimumProtocolVersion: 1,
    handshake: Object.freeze({ kind: 'adapter', timeoutMs: 30_000 }),
    classification: 'native',
    priority: 10,
    capabilityHints: Object.freeze(CODEX_CAPABILITIES),
  }),
  Object.freeze({
    id: 'pi-rpc',
    runtimeId: 'pi',
    adapterId: 'pi-rpc',
    displayName: 'Pi',
    protocolName: 'RPC',
    executables: Object.freeze(['pi']),
    hostKinds: Object.freeze(['native', 'wsl']),
    launchArgs: Object.freeze(['--mode', 'rpc']),
    signInArgs: Object.freeze(['onboard']),
    machineMode: 'rpc',
    minimumProtocolVersion: 1,
    handshake: Object.freeze({ kind: 'adapter', timeoutMs: 30_000 }),
    classification: 'native',
    priority: 20,
    capabilityHints: Object.freeze(PI_CAPABILITIES),
  }),
  Object.freeze({
    id: 'hermes-acp',
    runtimeId: 'hermes',
    adapterId: 'hermes-acp',
    displayName: 'Hermes',
    protocolName: 'ACP',
    executables: Object.freeze(['hermes']),
    hostKinds: Object.freeze(['native', 'wsl']),
    launchArgs: Object.freeze(['acp']),
    signInArgs: Object.freeze(['acp', '--setup']),
    machineMode: 'acp',
    minimumProtocolVersion: 1,
    handshake: Object.freeze({ kind: 'adapter', timeoutMs: 30_000 }),
    classification: 'native',
    priority: 30,
    capabilityHints: Object.freeze(ACP_CAPABILITIES),
  }),
  Object.freeze({
    id: 'hermes-gateway',
    runtimeId: 'hermes',
    adapterId: 'hermes-gateway',
    displayName: 'Hermes',
    protocolName: 'Gateway',
    executables: Object.freeze(['hermes']),
    hostKinds: Object.freeze(['native', 'wsl']),
    launchArgs: Object.freeze(['serve', '--port', '0', '--host', '127.0.0.1', '--skip-build', '--isolated']),
    signInArgs: Object.freeze([]),
    machineMode: 'gateway',
    minimumProtocolVersion: 1,
    handshake: Object.freeze({ kind: 'health-and-websocket', timeoutMs: 45_000 }),
    classification: 'native',
    priority: 31,
    capabilityHints: Object.freeze(HERMES_GATEWAY_CAPABILITIES),
  }),
  Object.freeze({
    id: 'openclaw-acp',
    runtimeId: 'openclaw',
    adapterId: 'openclaw-acp',
    displayName: 'OpenClaw',
    protocolName: 'ACP',
    executables: Object.freeze(['openclaw']),
    hostKinds: Object.freeze(['native', 'wsl']),
    launchArgs: Object.freeze(['acp']),
    signInArgs: Object.freeze(['onboard']),
    machineMode: 'runtime-owned-bridge',
    minimumProtocolVersion: 1,
    handshake: Object.freeze({ kind: 'acp', timeoutMs: 30_000 }),
    classification: 'native',
    priority: 40,
    capabilityHints: Object.freeze(OPENCLAW_ACP_CAPABILITIES),
  }),
  Object.freeze({
    id: 'openclaw-gateway',
    runtimeId: 'openclaw',
    adapterId: 'openclaw-gateway',
    displayName: 'OpenClaw',
    protocolName: 'Direct Gateway',
    // A direct endpoint is an Advanced override. Local executable discovery uses
    // `openclaw acp` so OpenClaw remains the sole owner of config, SecretRefs,
    // device identity, and issued device tokens.
    executables: Object.freeze([]),
    hostKinds: Object.freeze(['remote']),
    launchArgs: Object.freeze([]),
    signInArgs: Object.freeze([]),
    machineMode: 'gateway-client',
    minimumProtocolVersion: 4,
    handshake: Object.freeze({ kind: 'official-gateway-client', timeoutMs: 30_000 }),
    classification: 'native',
    priority: 41,
    capabilityHints: Object.freeze(OPENCLAW_GATEWAY_CAPABILITIES),
  }),
  Object.freeze({
    id: 'claude-pty',
    runtimeId: 'claude',
    adapterId: 'pty-compatibility',
    displayName: 'Claude CLI',
    protocolName: 'Terminal compatibility',
    executables: Object.freeze(['claude']),
    hostKinds: Object.freeze(['native', 'wsl']),
    launchArgs: Object.freeze([]),
    signInArgs: Object.freeze([]),
    machineMode: 'terminal',
    minimumProtocolVersion: null,
    handshake: Object.freeze({ kind: 'terminal-readiness', timeoutMs: 20_000 }),
    classification: 'compatible',
    priority: 1000,
    capabilityHints: Object.freeze(['turn.stream.v1']),
  }),
]);

export function catalogExecutableNames(catalog = RUNTIME_CATALOG) {
  return [...new Set(catalog.flatMap((entry) => entry.executables || []).filter(isSafeExecutableName))];
}

export function catalogEntriesForExecutable(executableName, hostKind, catalog = RUNTIME_CATALOG) {
  return catalog.filter((entry) =>
    entry.hostKinds?.includes(hostKind) && entry.executables?.includes(executableName));
}

export function catalogEntry(adapterId, catalog = RUNTIME_CATALOG) {
  return catalog.find((entry) => entry.adapterId === adapterId) || null;
}

function isSafeExecutableName(value) {
  return /^[a-z0-9][a-z0-9._-]{0,127}$/i.test(String(value));
}
