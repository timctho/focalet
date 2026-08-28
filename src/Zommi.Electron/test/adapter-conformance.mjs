import assert from 'node:assert/strict';
import { once } from 'node:events';

export async function assertAcceptedTurnBecomesUnknownOnRuntimeExit({
  adapter,
  exitRuntime,
  operationId,
  message = 'keep working',
  forbiddenDiagnostics = [],
}) {
  const statuses = [];
  const onStatus = (status) => statuses.push(String(status));
  adapter.on('status', onStatus);
  const completion = once(adapter, 'turnCompleted');
  const accepted = await adapter.startTurn(message, [], [], { clientOperationId: operationId });
  assert.equal(accepted.accepted, true);
  exitRuntime();
  const [terminal] = await completion;
  assert.deepEqual({
    threadId: terminal.threadId,
    turnId: terminal.turnId,
    clientOperationId: terminal.clientOperationId,
    status: terminal.status,
  }, {
    threadId: accepted.threadId,
    turnId: accepted.turnId,
    clientOperationId: operationId,
    status: 'unknown',
  });
  assert.match(String(terminal.error || ''), /exit|closed|stopped|disconnect/i);
  const diagnostics = `${String(terminal.error || '')}\n${statuses.join('\n')}`;
  for (const forbidden of forbiddenDiagnostics) {
    assert.equal(diagnostics.includes(forbidden), false, `runtime diagnostics leaked '${forbidden}'`);
  }
  adapter.off('status', onStatus);
  if (adapter.pending instanceof Map) assert.equal(adapter.pending.size, 0);
  if (adapter.pendingRequests instanceof Set) assert.equal(adapter.pendingRequests.size, 0);
  return terminal;
}

export function assertSafeUnknownNativeDiagnostic(adapter, { eventName, forbidden = [] }) {
  const record = adapter.nativeDiagnostics?.at(-1);
  assert.ok(record, 'adapter did not retain an unknown native event');
  assert.equal(record.eventName, eventName);
  const serialized = JSON.stringify(record);
  for (const value of forbidden) assert.equal(serialized.includes(value), false, `native diagnostic leaked '${value}'`);
  return record;
}

export function installPendingRequestExitProbe(adapter) {
  let rejectProbe;
  const promise = new Promise((_resolve, reject) => { rejectProbe = reject; });
  promise.catch(() => {});
  const call = { reject: rejectProbe, timer: setTimeout(() => rejectProbe(new Error('pending request probe timed out')), 10_000) };
  if (adapter.pending instanceof Map) adapter.pending.set(Symbol('conformance-pending-request'), call);
  else if (adapter.pendingRequests instanceof Set) adapter.pendingRequests.add(call);
  else throw new Error('adapter does not expose a pending request collection for conformance');
  return promise;
}
