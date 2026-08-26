export function mergeActivityText(currentValue, incomingValue, kind, lifecycle) {
  const current = String(currentValue || '');
  const incoming = String(incomingValue || '');
  if (!incoming) return current;

  if (lifecycle === 'completed' && (kind === 'thinking' || kind === 'plan')) {
    if (incoming === current || current.includes(incoming)) return current;
    if (incoming.includes(current)) return incoming;
    return incoming;
  }

  if (incoming === current) return current;
  if (lifecycle === 'completed' && current.includes(incoming)) return current;
  const separator = lifecycle === 'completed' && current && !current.endsWith('\n') ? '\n' : '';
  return `${current}${separator}${incoming}`;
}

export function mergeDistinctTextSections(sections) {
  const values = [];
  for (const section of sections || []) {
    const value = String(section || '').trim();
    if (!value || values.some((existing) => existing === value || existing.includes(value))) continue;
    for (let index = values.length - 1; index >= 0; index--) {
      if (value.includes(values[index])) values.splice(index, 1);
    }
    values.push(value);
  }
  return values.join('\n');
}

export function extractDisplayUserText(value) {
  const text = String(value || '');
  const match = text.match(/<user_message>\s*([\s\S]*?)\s*<\/user_message>/i);
  return (match ? match[1] : text).trim();
}

export function sessionTitle(session) {
  const value = session?.name || session?.preview || 'New chat';
  const title = extractDisplayUserText(value).replace(/^Zommi\s*·\s*/i, '').replace(/\s+/g, ' ').trim();
  return title.length <= 42 ? title : `${title.slice(0, 41)}…`;
}

export function isNearBottom({ scrollHeight, scrollTop, clientHeight }, tolerance = 36) {
  return scrollHeight - scrollTop - clientHeight <= tolerance;
}

export function initialHistoryStart(turnCount, pageSize) {
  return Math.max(0, Number(turnCount) - Math.max(1, Number(pageSize)));
}

export function previousHistoryStart(currentStart, pageSize) {
  return Math.max(0, Number(currentStart) - Math.max(1, Number(pageSize)));
}

export function sessionStatus(threadId, activeThreadId, runningThreadIds, unreadThreadIds) {
  if (runningThreadIds?.has(threadId)) return 'running';
  if (unreadThreadIds?.has(threadId)) return 'unread';
  return threadId === activeThreadId ? 'read' : 'done';
}

export function effortsForModel(model) {
  const options = model?.supportedReasoningEfforts || [];
  return options
    .map((option) => typeof option === 'string' ? option : option?.reasoningEffort)
    .filter(Boolean);
}

export function activityKey(kind, itemId, title) {
  return String(kind || '').toLowerCase() === 'thinking'
    ? 'turn-thinking'
    : itemId || `${kind}:${title}`;
}
