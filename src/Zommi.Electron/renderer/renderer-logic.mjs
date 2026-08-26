export function mergeActivityText(currentValue, incomingValue, kind, lifecycle) {
  const current = String(currentValue || '');
  const incoming = String(incomingValue || '');
  if (!incoming) return current;

  if (lifecycle === 'completed' && (kind === 'thinking' || kind === 'plan')) {
    if (incoming === current || current.startsWith(incoming)) return current;
    if (incoming.startsWith(current)) return incoming;
    return incoming;
  }

  if (incoming === current) return current;
  if (lifecycle === 'completed' && current.includes(incoming)) return current;
  const separator = lifecycle === 'completed' && current && !current.endsWith('\n') ? '\n' : '';
  return `${current}${separator}${incoming}`;
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

export function effortsForModel(model) {
  const options = model?.supportedReasoningEfforts || [];
  return options
    .map((option) => typeof option === 'string' ? option : option?.reasoningEffort)
    .filter(Boolean);
}
