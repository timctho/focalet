import assert from 'node:assert/strict';
import test from 'node:test';
import {
  BROKER_PROTOCOL_VERSION,
  BrokerProtocolError,
  boundedPage,
  sanitizeDiagnostic,
  serializeBrokerError,
  validateBrokerRequest,
  validateCapabilities,
  validateTurnInput,
} from '../broker-protocol.mjs';

test('broker requests require a supported version, operation, and stable turn operation id', () => {
  assert.throws(
    () => validateBrokerRequest({ protocolVersion: 99, operation: 'runtime.listTargets' }),
    (error) => error instanceof BrokerProtocolError && error.code === 'unsupported-version',
  );
  assert.throws(
    () => validateBrokerRequest({ protocolVersion: BROKER_PROTOCOL_VERSION, operation: 'turn.start', payload: { message: 'hello' } }),
    (error) => error.code === 'invalid-request',
  );
  const request = validateBrokerRequest({
    protocolVersion: BROKER_PROTOCOL_VERSION,
    operation: 'turn.start',
    clientOperationId: 'client:operation-1',
    runtimeTargetId: 'target-a',
    sessionId: 'session-a',
    payload: { message: 'hello' },
  });
  assert.equal(request.clientOperationId, 'client:operation-1');
  assert.equal(request.runtimeTargetId, 'target-a');
  assert.equal(request.sessionId, 'session-a');
});

test('state-changing broker operations require exact target, session, turn, and operation identity', () => {
  const base = {
    protocolVersion: BROKER_PROTOCOL_VERSION,
    clientOperationId: 'client:mutation-1',
    payload: {},
  };
  assert.throws(
    () => validateBrokerRequest({ ...base, operation: 'session.create' }),
    /requires runtimeTargetId/,
  );
  assert.throws(
    () => validateBrokerRequest({ ...base, operation: 'turn.start', runtimeTargetId: 'target-a' }),
    /requires sessionId/,
  );
  assert.throws(
    () => validateBrokerRequest({
      ...base, operation: 'turn.interrupt', runtimeTargetId: 'target-a', sessionId: 'session-a',
    }),
    /requires turnId/,
  );
  assert.throws(
    () => validateBrokerRequest({
      protocolVersion: BROKER_PROTOCOL_VERSION,
      operation: 'question.resolve',
      runtimeTargetId: 'target-a',
      sessionId: 'session-a',
      payload: { questionId: 'question-a' },
    }),
    /clientOperationId is required/,
  );
});

test('broker input validation bounds context and image payloads before an adapter write', () => {
  const valid = validateTurnInput('hello', [{ snapshotId: 'a' }], ['data:image/png;base64,aGVsbG8=']);
  assert.equal(valid.message, 'hello');
  assert.throws(
    () => validateTurnInput('hello', Array.from({ length: 17 }, () => ({})), []),
    (error) => error.code === 'input-too-large',
  );
  assert.throws(
    () => validateTurnInput('hello', [], ['https://example.test/not-an-image']),
    (error) => error.code === 'invalid-request',
  );
});

test('broker pagination is bounded and rejects forged cursors', () => {
  const first = boundedPage(['a', 'b', 'c'], null, 2);
  assert.deepEqual(first.data, ['a', 'b']);
  assert.ok(first.nextCursor);
  assert.deepEqual(boundedPage(['a', 'b', 'c'], first.nextCursor, 2), { data: ['c'], nextCursor: null });
  assert.throws(() => boundedPage(['a'], 'not-a-cursor', 2), (error) => error.code === 'invalid-request');
});

test('broker diagnostics redact credentials and captured context', () => {
  const message = sanitizeDiagnostic('Bearer abc.def token=private <zommi_invocation_context>screen secret</zommi_invocation_context> failed');
  assert.doesNotMatch(message, /abc\.def|private|screen secret/);
  assert.match(message, /Bearer \[redacted\]/);
  const serialized = serializeBrokerError(new Error('password=hunter2'));
  assert.equal(serialized.code, 'runtime-failed');
  assert.doesNotMatch(serialized.message, /hunter2/);
});

test('capability strings are versioned instead of inferred from adapter names', () => {
  assert.deepEqual(validateCapabilities(['turn.stream.v1', 'turn.stream.v1']), ['turn.stream.v1']);
  assert.throws(() => validateCapabilities(['turn.stream']), (error) => error.code === 'invalid-response');
});
