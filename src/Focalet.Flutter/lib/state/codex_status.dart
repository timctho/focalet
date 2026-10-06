import 'package:focalet_flutter/state/focalet_models.dart';

String formatCodexStatus(Map<String, Object?> status) {
  final settings = mapValue(status['settings']);
  final thread = mapValue(status['thread']);
  final account = mapValue(status['account']);
  final usage = mapValue(status['tokenUsage']);
  final last = mapValue(usage['last']);
  final total = mapValue(usage['total']);
  final lines = <String>[
    'Codex${status['runtimeVersion'] == null ? '' : ' · ${status['runtimeVersion']}'}',
    'Session: ${status['sessionId']}',
    'Model: ${settings['model'] ?? 'Not reported'}'
        '${settings['reasoningEffort'] == null ? '' : ' · ${settings['reasoningEffort']}'}',
    'Workspace: ${thread['cwd'] ?? settings['cwd'] ?? 'Not reported'}',
    'Status: ${mapValue(thread['status'])['type'] ?? 'Not reported'}'
        '${status['readOnly'] == true ? ' · read only' : ''}',
    if (settings['approvalPolicy'] != null)
      'Approvals: ${settings['approvalPolicy']}',
    if (mapValue(settings['sandbox'])['type'] != null)
      'Sandbox: ${mapValue(settings['sandbox'])['type']}',
    if (account.isNotEmpty)
      'Account: ${account['type'] ?? 'Unknown'}'
          '${account['planType'] == null ? '' : ' · ${account['planType']}'}',
  ];
  final used = last['totalTokens'];
  final capacity = usage['modelContextWindow'];
  if (used is num && capacity is num && capacity > 0) {
    final left = ((1 - used / capacity) * 100).clamp(0, 100).round();
    lines.add(
      'Context (last reported): $used / $capacity tokens · $left% left',
    );
  } else {
    lines.add('Context usage: not reported by this connection yet');
  }
  if (total['totalTokens'] != null) {
    lines.add(
      'Session usage: ${total['totalTokens']} tokens'
      ' · ${total['inputTokens'] ?? '?'} input'
      ' · ${total['outputTokens'] ?? '?'} output',
    );
  }
  final buckets = {...mapValue(status['rateLimitsByLimitId'])};
  if (buckets.isEmpty && status['rateLimits'] is Map) {
    buckets['Codex'] = status['rateLimits'];
  }
  var hasLimits = false;
  for (final entry in buckets.entries) {
    final bucket = mapValue(entry.value);
    for (final period in ['primary', 'secondary']) {
      final window = mapValue(bucket[period]);
      final usedPercent = window['usedPercent'];
      if (usedPercent is! num) continue;
      hasLimits = true;
      final minutes = window['windowDurationMins'];
      final label = minutes == 300
          ? '5h'
          : minutes == 10080
          ? 'Weekly'
          : minutes is num
          ? '${minutes}m'
          : period;
      final reset = window['resetsAt'];
      final resets = reset is num
          ? ' · resets ${DateTime.fromMillisecondsSinceEpoch(reset.toInt() * 1000).toLocal()}'
          : '';
      lines.add(
        '${bucket['limitName'] ?? entry.key} $label: '
        '${(100 - usedPercent).clamp(0, 100).round()}% left$resets',
      );
    }
  }
  if (!hasLimits) lines.add('Usage limits: not reported for this connection');
  for (final warning in status['warnings'] as List<Object?>? ?? const []) {
    lines.add(warning.toString());
  }
  return lines.join('\n');
}
