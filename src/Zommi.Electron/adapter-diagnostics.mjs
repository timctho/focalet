const MAX_NATIVE_DIAGNOSTICS = 128;
const MAX_KEYS = 64;
const SENSITIVE_KEY = /token|password|secret|credential|authorization|api.?key|cookie/i;
const CONTENT_KEY = /text|content|message|prompt|input|output|body|data|attachment|image|url/i;
const SAFE_STRING_KEY = /^(?:id|.*_id|.*Id|sessionKey|runId|turnId|threadId|type|method|event|state|status|phase|kind|role|code|reasonCode)$/;

export function recordNativeDiagnostic(adapter, protocol, eventName, payload) {
  const record = Object.freeze({
    observedAtMs: Date.now(),
    protocol: String(protocol || 'runtime'),
    eventName: String(eventName || '<unknown>'),
    payload: redactNativePayload(payload),
  });
  adapter.nativeDiagnostics ||= [];
  adapter.nativeDiagnostics.push(record);
  while (adapter.nativeDiagnostics.length > MAX_NATIVE_DIAGNOSTICS) adapter.nativeDiagnostics.shift();
  adapter.emit?.('diagnostic', {
    message: `${record.protocol} retained unknown native event '${record.eventName}' for diagnostics.`,
    nativeEvent: record,
  });
  return record;
}

export function redactNativePayload(value, key = '', depth = 0) {
  if (depth > 5) return '[depth limited]';
  if (value === null || value === undefined || typeof value === 'boolean' || typeof value === 'number') return value;
  if (typeof value === 'string') {
    if (SENSITIVE_KEY.test(key)) return '[secret redacted]';
    if (CONTENT_KEY.test(key)) return `[content redacted:${Buffer.byteLength(value, 'utf8')} bytes]`;
    return SAFE_STRING_KEY.test(key) ? value.slice(0, 512) : `[string redacted:${Buffer.byteLength(value, 'utf8')} bytes]`;
  }
  if (Array.isArray(value)) return value.slice(0, MAX_KEYS).map((item) => redactNativePayload(item, key, depth + 1));
  if (typeof value !== 'object') return `[${typeof value}]`;
  const result = {};
  for (const entryKey of Object.keys(value).slice(0, MAX_KEYS)) {
    result[entryKey] = redactNativePayload(value[entryKey], entryKey, depth + 1);
  }
  return result;
}
