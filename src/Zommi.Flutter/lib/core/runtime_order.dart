import 'core_bridge.dart';

int _rank(String id) => switch (id.split('-').first.toLowerCase()) {
  'codex' => 0,
  'claude' => 1,
  'opencode' => 2,
  _ => 3,
};

int _names(String leftId, String leftName, String rightId, String rightName) {
  final rank = _rank(leftId).compareTo(_rank(rightId));
  return rank != 0
      ? rank
      : leftName.trim().toLowerCase().compareTo(rightName.trim().toLowerCase());
}

int compareRuntimeTargets(RuntimeTarget left, RuntimeTarget right) {
  final name = _names(
    left.runtimeId,
    left.displayName,
    right.runtimeId,
    right.displayName,
  );
  if (name != 0) return name;
  final host = (left.executionHost['displayName']?.toString() ?? '')
      .toLowerCase()
      .compareTo(
        (right.executionHost['displayName']?.toString() ?? '').toLowerCase(),
      );
  if (host != 0) return host;
  final protocol = left.protocolName.compareTo(right.protocolName);
  return protocol != 0 ? protocol : left.id.compareTo(right.id);
}

int compareRuntimeAdapters(
  Map<String, Object?> left,
  Map<String, Object?> right,
) {
  final leftId = left['adapterId']?.toString() ?? '';
  final rightId = right['adapterId']?.toString() ?? '';
  final name = _names(
    leftId,
    left['displayName']?.toString() ?? '',
    rightId,
    right['displayName']?.toString() ?? '',
  );
  return name != 0 ? name : leftId.compareTo(rightId);
}
