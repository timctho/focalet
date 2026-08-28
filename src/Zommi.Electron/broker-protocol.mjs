import { createHash, randomUUID } from 'node:crypto';

export const BROKER_PROTOCOL_VERSION = 1;
export const MAX_TURN_MESSAGE_BYTES = 256 * 1024;
export const MAX_CONTEXT_SNAPSHOTS = 16;
export const MAX_IMAGE_ATTACHMENTS = 8;
export const MAX_IMAGE_BYTES = 20 * 1024 * 1024;
export const MAX_TOTAL_IMAGE_BYTES = 50 * 1024 * 1024;

export const BROKER_OPERATIONS = Object.freeze([
  'runtime.listTargets',
  'runtime.refreshTargets',
  'runtime.getStatus',
  'session.list',
  'session.create',
  'session.open',
  'session.read',
  'turn.start',
  'turn.steer',
  'turn.interrupt',
  'approval.resolve',
  'question.resolve',
  'events.subscribe',
]);

const OPERATION_SET = new Set(BROKER_OPERATIONS);
const TARGET_ID_OPERATIONS = new Set(BROKER_OPERATIONS.filter((operation) => ![
  'runtime.listTargets', 'runtime.refreshTargets', 'runtime.getStatus',
].includes(operation)));
const SESSION_ID_OPERATIONS = new Set([
  'session.open', 'session.read', 'turn.start', 'turn.steer', 'turn.interrupt',
  'approval.resolve', 'question.resolve',
]);
const TURN_ID_OPERATIONS = new Set(['turn.steer', 'turn.interrupt']);
const MUTATING_OPERATIONS = new Set([
  'session.create', 'session.open', 'turn.start', 'turn.steer', 'turn.interrupt',
  'approval.resolve', 'question.resolve',
]);
const CLIENT_OPERATION_ID = /^[a-z0-9][a-z0-9._:-]{7,127}$/i;
const CAPABILITY = /^[a-z][a-z0-9]*(?:\.[a-z][a-z0-9]*)*\.v[1-9][0-9]*$/;

export class BrokerProtocolError extends Error {
  constructor(code, message, options = {}) {
    super(sanitizeDiagnostic(message), options.cause ? { cause: options.cause } : undefined);
    this.name = 'BrokerProtocolError';
    this.code = String(code || 'runtime-failed');
    this.outcome = options.outcome || 'rejected';
    this.retryable = Boolean(options.retryable);
  }
}

export function createClientOperationId() {
  return `zommi:${randomUUID()}`;
}

export function normalizeClientOperationId(value, { required = false } = {}) {
  if (value === undefined || value === null || value === '') {
    if (required) throw new BrokerProtocolError('invalid-request', 'clientOperationId is required.');
    return createClientOperationId();
  }
  const id = String(value);
  if (!CLIENT_OPERATION_ID.test(id)) {
    throw new BrokerProtocolError('invalid-request', 'clientOperationId must be 8-128 safe opaque characters.');
  }
  return id;
}

export function validateBrokerRequest(request) {
  if (!request || typeof request !== 'object' || Array.isArray(request)) {
    throw new BrokerProtocolError('invalid-request', 'Broker request must be an object.');
  }
  if (request.protocolVersion !== BROKER_PROTOCOL_VERSION) {
    throw new BrokerProtocolError(
      'unsupported-version',
      `Unsupported broker protocol version ${String(request.protocolVersion)}.`,
    );
  }
  const operation = String(request.operation || '');
  if (!OPERATION_SET.has(operation)) {
    throw new BrokerProtocolError('unsupported-operation', `Unsupported broker operation '${operation || '<missing>'}'.`);
  }
  const clientOperationId = normalizeClientOperationId(request.clientOperationId, {
    required: MUTATING_OPERATIONS.has(operation),
  });
  const payload = request.payload === undefined ? {} : request.payload;
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    throw new BrokerProtocolError('invalid-request', 'Broker request payload must be an object.');
  }
  const runtimeTargetId = optionalOpaqueId(request.runtimeTargetId, 'runtimeTargetId');
  const sessionId = optionalOpaqueId(request.sessionId, 'sessionId');
  const turnId = optionalOpaqueId(request.turnId, 'turnId');
  if (TARGET_ID_OPERATIONS.has(operation) && !runtimeTargetId) {
    throw new BrokerProtocolError('invalid-request', `${operation} requires runtimeTargetId.`);
  }
  if (SESSION_ID_OPERATIONS.has(operation) && !sessionId) {
    throw new BrokerProtocolError('invalid-request', `${operation} requires sessionId.`);
  }
  if (TURN_ID_OPERATIONS.has(operation) && !turnId) {
    throw new BrokerProtocolError('invalid-request', `${operation} requires turnId.`);
  }
  return {
    protocolVersion: BROKER_PROTOCOL_VERSION,
    operation,
    clientOperationId,
    runtimeTargetId,
    sessionId,
    turnId,
    payload,
  };
}

export function validateCapabilities(capabilities) {
  if (!Array.isArray(capabilities)) {
    throw new BrokerProtocolError('invalid-response', 'Runtime capabilities must be an array.');
  }
  const normalized = [...new Set(capabilities.map(String))];
  for (const capability of normalized) {
    if (!CAPABILITY.test(capability)) {
      throw new BrokerProtocolError('invalid-response', `Runtime emitted invalid capability '${capability}'.`);
    }
  }
  return normalized;
}

export function validateTurnInput(message, snapshots = [], images = []) {
  const text = String(message || '').trim();
  if (!text) throw new BrokerProtocolError('invalid-request', 'A message is required.');
  if (Buffer.byteLength(text, 'utf8') > MAX_TURN_MESSAGE_BYTES) {
    throw new BrokerProtocolError('input-too-large', `Message exceeds ${MAX_TURN_MESSAGE_BYTES} bytes.`);
  }
  if (!Array.isArray(snapshots) || snapshots.length > MAX_CONTEXT_SNAPSHOTS) {
    throw new BrokerProtocolError('input-too-large', `At most ${MAX_CONTEXT_SNAPSHOTS} context snapshots may be sent.`);
  }
  if (!Array.isArray(images) || images.length > MAX_IMAGE_ATTACHMENTS) {
    throw new BrokerProtocolError('input-too-large', `At most ${MAX_IMAGE_ATTACHMENTS} images may be sent.`);
  }
  let totalImageBytes = 0;
  for (const image of images) {
    const match = /^data:image\/[a-z0-9.+-]+;base64,([a-z0-9+/=\s]+)$/i.exec(String(image || ''));
    if (!match) throw new BrokerProtocolError('invalid-request', 'Image inputs must be base64 image data URLs.');
    const bytes = Buffer.from(match[1].replace(/\s+/g, ''), 'base64').byteLength;
    if (bytes > MAX_IMAGE_BYTES) {
      throw new BrokerProtocolError('input-too-large', `One image exceeds ${MAX_IMAGE_BYTES} bytes.`);
    }
    totalImageBytes += bytes;
  }
  if (totalImageBytes > MAX_TOTAL_IMAGE_BYTES) {
    throw new BrokerProtocolError('input-too-large', `Image inputs exceed ${MAX_TOTAL_IMAGE_BYTES} bytes in total.`);
  }
  return { message: text, snapshots, images };
}

export function validateTurnResult(result) {
  if (!result || typeof result !== 'object' || result.accepted !== true) {
    throw new BrokerProtocolError('invalid-response', 'Runtime did not return an accepted turn result.');
  }
  const threadId = requiredOpaqueId(result.threadId, 'sessionId');
  const turnId = requiredOpaqueId(result.turnId, 'turnId');
  return { ...result, accepted: true, threadId, turnId };
}

export function operationFingerprint(value) {
  return createHash('sha256').update(JSON.stringify(value)).digest('hex');
}

export function boundedPage(values, cursor = null, limit = 50, maximum = 200) {
  const rows = Array.isArray(values) ? values : [];
  const size = Math.min(maximum, Math.max(1, Number.isInteger(Number(limit)) ? Number(limit) : 50));
  const offset = decodeCursor(cursor);
  const data = rows.slice(offset, offset + size);
  return {
    data,
    nextCursor: offset + data.length < rows.length ? encodeCursor(offset + data.length) : null,
  };
}

export function sanitizeDiagnostic(value) {
  let message = String(value?.message || value || 'Runtime operation failed.');
  message = message.replace(/<zommi_invocation_context>[\s\S]*?<\/zommi_invocation_context>/gi, '[context redacted]');
  message = message.replace(/\bBearer\s+[A-Za-z0-9._~+\/-]+=*/gi, 'Bearer [redacted]');
  message = message.replace(/\b(token|password|secret|api[_-]?key|authorization)(\s*[:=]\s*)([^\s,;]+)/gi, '$1$2[redacted]');
  return message.slice(0, 2_000);
}

export function toBrokerProtocolError(error, fallbackCode = 'runtime-failed') {
  if (error instanceof BrokerProtocolError) return error;
  const message = sanitizeDiagnostic(error);
  if (/sign[ -]?in|log[ -]?in|not authenticated|unauthenticated|authentication required|missing credentials/i.test(message)) {
    return new BrokerProtocolError('authentication-required', message, { cause: error });
  }
  if (/unsupported|unknown (?:option|command)|version.+(?:old|require)/i.test(message)) {
    return new BrokerProtocolError('unsupported-version', message, { cause: error });
  }
  if (/already has an active|active turn|conflict/i.test(message)) {
    return new BrokerProtocolError('conflict', message, { cause: error, retryable: true });
  }
  return new BrokerProtocolError(fallbackCode, message, { cause: error });
}

export function ambiguousOutcome(error, runtimeName, operation = 'turn') {
  return new BrokerProtocolError(
    'ambiguous-outcome',
    `${runtimeName} did not confirm whether the ${operation} was accepted. Zommi did not retry it; refresh the exact session before sending again.`,
    { cause: error, outcome: 'unknown', retryable: false },
  );
}

export function serializeBrokerError(error) {
  const normalized = toBrokerProtocolError(error);
  return {
    code: normalized.code,
    message: normalized.message,
    outcome: normalized.outcome,
    retryable: normalized.retryable,
  };
}

function optionalOpaqueId(value, name) {
  if (value === undefined || value === null || value === '') return null;
  return requiredOpaqueId(value, name);
}

function requiredOpaqueId(value, name) {
  const id = String(value || '');
  if (!id || id.length > 512 || /[\u0000-\u001f\u007f]/.test(id)) {
    throw new BrokerProtocolError('invalid-request', `${name} is invalid.`);
  }
  return id;
}

function encodeCursor(offset) {
  return Buffer.from(String(offset), 'utf8').toString('base64url');
}

function decodeCursor(cursor) {
  if (cursor === undefined || cursor === null || cursor === '') return 0;
  try {
    const value = Number(Buffer.from(String(cursor), 'base64url').toString('utf8'));
    if (!Number.isSafeInteger(value) || value < 0) throw new Error('invalid');
    return value;
  } catch {
    throw new BrokerProtocolError('invalid-request', 'Pagination cursor is invalid.');
  }
}
