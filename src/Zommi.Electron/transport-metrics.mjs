export function emitProtocolWrite(adapter, method, clientOperationId, transport = null) {
  if (!clientOperationId) return null;
  const protocolWriteAtEpochMs = Date.now();
  const rendererSubmittedAtEpochMs = finiteTimestamp(transport?.rendererSubmittedAtEpochMs);
  const mainReceivedAtEpochMs = finiteTimestamp(transport?.mainReceivedAtEpochMs);
  const metric = {
    clientOperationId: String(clientOperationId),
    method: String(method || 'turn'),
    protocolWriteAtEpochMs,
    rendererSubmittedAtEpochMs,
    mainReceivedAtEpochMs,
    rendererToProtocolWriteMilliseconds: rendererSubmittedAtEpochMs === null
      ? null : Math.max(0, protocolWriteAtEpochMs - rendererSubmittedAtEpochMs),
    mainToProtocolWriteMilliseconds: mainReceivedAtEpochMs === null
      ? null : Math.max(0, protocolWriteAtEpochMs - mainReceivedAtEpochMs),
  };
  adapter.emit?.('protocolWrite', metric);
  return metric;
}

function finiteTimestamp(value) {
  const timestamp = Number(value);
  return Number.isFinite(timestamp) && timestamp > 0 ? timestamp : null;
}
