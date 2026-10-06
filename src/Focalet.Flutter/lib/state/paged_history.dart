part of 'focalet_controller.dart';

extension PagedSessionHistory on FocaletController {
  bool get hasOlderHistory =>
      core is PagedHistoryBridge &&
      _historyNextCursor.containsKey(_activeSessionKey);
  bool get loadingOlderHistory =>
      _historyPagesLoading.contains(_activeSessionKey);
  String? get olderHistoryError => _historyPageErrors[_activeSessionKey];

  Future<int> loadOlderHistory() async {
    final runtime = activeRuntime?.id;
    final session = activeSessionId;
    final key = _activeSessionKey;
    final bridge = core;
    final cursor = _historyNextCursor[key];
    if (runtime == null ||
        session == null ||
        key == null ||
        cursor == null ||
        bridge is! PagedHistoryBridge ||
        !_historyPagesLoading.add(key)) {
      return 0;
    }
    final epoch = _historyEpochs[key] ?? 0;
    _historyPageErrors.remove(key);
    _notify();
    try {
      final response = await (bridge as PagedHistoryBridge).readHistoryPage(
        runtimeTargetId: runtime,
        sessionId: session,
        cursor: cursor,
      );
      if (_closed ||
          (_historyEpochs[key] ?? 0) != epoch ||
          _historyNextCursor[key] != cursor) {
        return 0;
      }
      if (mapValue(response['thread'])['id'] != session) {
        throw const CoreProtocolException(
          'identity-mismatch',
          'History belongs to a different chat.',
        );
      }
      final next = mapValue(response['pagination'])['nextCursor'];
      if (next == cursor) {
        throw const CoreProtocolException(
          'invalid-response',
          'History pagination did not advance.',
        );
      }
      final existing = _turnsBySession[key] ?? const <ConversationTurn>[];
      final ids = existing.map((turn) => turn.runtimeTurnId ?? turn.id).toSet();
      final older = mapThreadHistory(response)
          .where((turn) => !ids.contains(turn.runtimeTurnId ?? turn.id))
          .toList();
      _turnsBySession[key] = [...older, ...existing];
      numberHistoryTurns(_turnsBySession[key]!);
      if (next is String && next.isNotEmpty) {
        _historyNextCursor[key] = next;
      } else {
        _historyNextCursor.remove(key);
      }
      _transcriptChanged(key);
      return older.length;
    } on Object {
      if (!_closed && (_historyEpochs[key] ?? 0) == epoch) {
        _historyPageErrors[key] = 'Could not load older messages. Retry.';
      }
      return 0;
    } finally {
      _historyPagesLoading.remove(key);
      _notify();
    }
  }

  Future<void> loadTurnHistory(ConversationTurn turn) async {
    final runtime = activeRuntime?.id;
    final session = activeSessionId;
    final key = _activeSessionKey;
    final bridge = core;
    if (runtime == null ||
        session == null ||
        key == null ||
        bridge is! PagedHistoryBridge ||
        !turn.historySummary ||
        turn.historyLoading) {
      return;
    }
    final epoch = _historyEpochs[key] ?? 0;
    final revision = _transcriptRevisions[key] ?? 0;
    turn.historyLoading = true;
    turn.historyError = null;
    _notify();
    try {
      final response = await (bridge as PagedHistoryBridge).readHistoryTurn(
        runtimeTargetId: runtime,
        sessionId: session,
        turnId: turn.runtimeTurnId ?? turn.id,
      );
      if (_closed || (_historyEpochs[key] ?? 0) != epoch) return;
      if (mapValue(response['thread'])['id'] != session) {
        throw const CoreProtocolException(
          'identity-mismatch',
          'Turn history belongs to a different chat.',
        );
      }
      final loaded = mapThreadHistory(response);
      if (loaded.length != 1 ||
          loaded.single.runtimeTurnId != (turn.runtimeTurnId ?? turn.id)) {
        throw const CoreProtocolException(
          'identity-mismatch',
          'History belongs to a different turn.',
        );
      }
      final current = _turnsBySession[key];
      final index = current?.indexWhere((value) => value.id == turn.id) ?? -1;
      if (index < 0) return;
      final previous = current![index];
      final changed = (_transcriptRevisions[key] ?? 0) != revision;
      final full = changed
          ? mergeConversationTurn(
              previous,
              loaded.single,
              preferPrimaryBlocks: true,
              userPresentation: previous,
            )
          : mergeConversationTurn(
              loaded.single,
              previous,
              preferPrimaryBlocks: true,
              userPresentation: previous,
            );
      full
        ..historySummary = false
        ..historyError = null
        ..number = previous.number
        ..activityExpanded = previous.activityExpanded;
      current[index] = full;
      _transcriptChanged(key);
    } on Object {
      if (!_closed && (_historyEpochs[key] ?? 0) == epoch) {
        final current = _turnsBySession[key]
            ?.where((value) => value.id == turn.id)
            .firstOrNull;
        current?.historyError = 'Could not load activity. Retry.';
      }
    } finally {
      turn.historyLoading = false;
      if ((_historyEpochs[key] ?? 0) == epoch) {
        final current = _turnsBySession[key]
            ?.where((value) => value.id == turn.id)
            .firstOrNull;
        current?.historyLoading = false;
      }
      _notify();
    }
  }
}

List<ConversationTurn> mergeRecentHistory(
  List<ConversationTurn> recent,
  List<ConversationTurn> cached, {
  required bool preserveUpdates,
}) {
  if (recent.isEmpty) return preserveUpdates ? List.of(cached) : [];
  final oldById = {
    for (final turn in cached) turn.runtimeTurnId ?? turn.id: turn,
  };
  final first = cached.indexWhere(
    (turn) =>
        (turn.runtimeTurnId ?? turn.id) ==
        (recent.first.runtimeTurnId ?? recent.first.id),
  );
  final result = <ConversationTurn>[
    if (first > 0) ...cached.take(first),
    for (final turn in recent)
      if (oldById[turn.runtimeTurnId ?? turn.id] case final old?)
        mergeConversationTurn(
          preserveUpdates ? old : turn,
          preserveUpdates ? turn : old,
          preferPrimaryBlocks: true,
          userPresentation: old,
        )..activityExpanded = old.activityExpanded
      else
        turn,
  ];
  if (preserveUpdates) {
    final ids = result.map((turn) => turn.runtimeTurnId ?? turn.id).toSet();
    result.addAll(
      cached.where((turn) => !ids.contains(turn.runtimeTurnId ?? turn.id)),
    );
  }
  numberHistoryTurns(result);
  return result;
}

void numberHistoryTurns(List<ConversationTurn> turns) {
  for (var i = 0; i < turns.length; i++) {
    turns[i].number = i + 1;
  }
}
