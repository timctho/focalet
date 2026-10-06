part of 'focalet_controller.dart';

const codexCommandHelp =
    '''/clear or /new — start a fresh chat; keep the previous chat in history.
/goal <objective> — set a goal and let Codex work on it.
/goal — view the current goal and usage.
/goal edit — load the objective into the composer.
/goal pause or /goal resume — control goal work.
/goal clear — remove the goal.
/status — view session details, context usage and account limits.
/help — show these commands.''';

extension CodexCommands on FocaletController {
  bool isReadOnlyCodexCommand(String text) =>
      activeRuntime?.adapterId == 'codex-app-server' &&
      const ['/status', '/help', '/'].contains(text.trim());
  Future<void> _refreshGoal() async {
    if (activeRuntime?.adapterId != 'codex-app-server' ||
        core is! GoalControlBridge ||
        activeSessionId == null) {
      return;
    }
    final targetId = activeRuntime!.id;
    final sessionId = activeSessionId!;
    final key = FocaletController._sessionKey(targetId, sessionId);
    final revision = _goalRevisions[key] ?? 0;
    try {
      final response = await (core as GoalControlBridge).goalCommand(
        runtimeTargetId: targetId,
        sessionId: sessionId,
        action: 'get',
      );
      if (!_closed && (_goalRevisions[key] ?? 0) == revision) {
        final value = response['goal'];
        _goalsBySession[key] = value is Map ? mapValue(value) : null;
        if (_activeSessionKey == key) _notify();
      }
    } on Object {
      // Older runtimes and configurations with goals disabled remain usable.
      // An explicit /goal command displays the runtime's error to the user.
    }
  }

  bool isCodexCommand(String message) =>
      activeRuntime?.adapterId == 'codex-app-server' &&
      (message.trim() == '/' ||
          RegExp(r'^/[A-Za-z][A-Za-z0-9_-]*(?:\s|$)').hasMatch(message.trim()));

  String? get commandResult =>
      commandOutput ?? (goalPanelOpen ? _goalSummary : null);

  String get _goalSummary {
    final goal = _goalsBySession[_activeSessionKey];
    if (goal == null) return 'No goal set. Use /goal <objective> to start one.';
    final state = goal['status']?.toString() ?? 'unknown';
    final budget = goal['tokenBudget'];
    return 'Goal · $state\n${goal['objective']}\n'
        '${goal['tokensUsed'] ?? 0}${budget == null ? '' : ' / $budget'} tokens · '
        '${goal['timeUsedSeconds'] ?? 0}s\n'
        '/goal pause · /goal resume · /goal edit · /goal clear';
  }

  void dismissCommandResult() {
    _statusRequest++;
    commandOutput = null;
    goalPanelOpen = false;
    _notify();
  }

  void _commandError(String message) {
    commandOutput = message;
    _setStatus(message, warning: true);
  }

  Future<void> _clearCodexChat() async {
    final targetId = activeRuntime!.id;
    final sessionId = activeSessionId!;
    final key = FocaletController._sessionKey(targetId, sessionId);
    sessionBusy = true;
    _notify();
    try {
      if (_goalsBySession[key]?['status'] == 'active') {
        if (core is! GoalControlBridge) {
          throw const CoreProtocolException(
            'capability-unavailable',
            'Cannot pause the active goal.',
          );
        }
        final result = await (core as GoalControlBridge).goalCommand(
          runtimeTargetId: targetId,
          sessionId: sessionId,
          action: 'pause',
        );
        _goalsBySession[key] = mapValue(result['goal']);
      }
      final turnId = _activeTurns[key];
      if (turnId != null) {
        final stopped = Completer<void>();
        final subscription = core.events.listen((event) {
          if (event.name == 'turn.completed' &&
              event.runtimeTargetId == targetId &&
              event.sessionId == sessionId &&
              event.turnId == turnId &&
              !stopped.isCompleted) {
            stopped.complete();
          }
        });
        _interruptingSessions.add(key);
        try {
          await core.interruptTurn(
            runtimeTargetId: targetId,
            sessionId: sessionId,
            turnId: turnId,
          );
          await stopped.future.timeout(const Duration(seconds: 15));
        } finally {
          await subscription.cancel();
          _interruptingSessions.remove(key);
        }
      }
      if (!_isActiveSession(targetId, sessionId)) return;
      sessionBusy = false;
      final previousDraft = composerValue;
      composerValue = TextEditingValue.empty;
      await createSession();
      if (_activeSessionKey == key) composerValue = previousDraft;
    } on Object catch (error) {
      _commandError('Could not start a fresh chat · $error');
    } finally {
      sessionBusy = false;
      _notify();
    }
  }

  Future<bool> _submitCodexCommand(String text) async {
    if (!isCodexCommand(text)) return false;
    if (text == '/') text = '/help';
    final match = RegExp(r'^/([A-Za-z][A-Za-z0-9_-]*)(?:\s+([\s\S]*))?$')
        .firstMatch(text)!;
    final command = match.group(1)!;
    final argument = (match.group(2) ?? '').trim();
    if (command == 'help' && argument.isEmpty) {
      commandOutput = codexCommandHelp;
      composerValue = TextEditingValue.empty;
      commandComposerEpoch++;
      _notify();
      return true;
    }
    if (command == 'status') {
      if (argument.isNotEmpty) {
        _commandError('Use /status without arguments.');
        return true;
      }
      if (core is! SessionStatusBridge) {
        _commandError('This connection does not support status queries.');
        return true;
      }
      final target = activeRuntime!.id;
      final session = activeSessionId!;
      final epoch = _switchEpoch;
      final request = ++_statusRequest;
      final draft = composerValue;
      commandOutput = 'Reading Codex status…';
      _notify();
      try {
        final result = await (core as SessionStatusBridge).sessionStatus(
          runtimeTargetId: target,
          sessionId: session,
        );
        if (_closed ||
            request != _statusRequest ||
            epoch != _switchEpoch ||
            !_isActiveSession(target, session)) {
          return true;
        }
        if (result['runtimeTargetId'] != target ||
            result['sessionId'] != session) {
          throw const CoreProtocolException(
            'identity-mismatch',
            'Status belongs to another chat.',
          );
        }
        commandOutput = formatCodexStatus(result);
        if (composerValue == draft && draft.text.trim() == '/status') {
          composerValue = TextEditingValue.empty;
          commandComposerEpoch++;
        }
      } on Object catch (error) {
        if (!_closed &&
            request == _statusRequest &&
            epoch == _switchEpoch &&
            _isActiveSession(target, session)) {
          _commandError('Could not read /status · $error');
        }
      }
      if (!_closed) _notify();
      return true;
    }
    if (command == 'clear' || command == 'new') {
      if (argument.isNotEmpty) {
        _commandError('Use /$command without arguments.');
      } else {
        await _clearCodexChat();
      }
      return true;
    }
    if (command != 'goal') {
      _commandError(
        'Unknown Codex command /$command. Use /help for supported commands.',
      );
      return true;
    }
    if (core is! GoalControlBridge) {
      _commandError('This connection does not support goal commands.');
      return true;
    }
    final action = switch (argument) {
      '' || 'edit' => 'get',
      'pause' || 'resume' || 'clear' => argument,
      _ => 'set',
    };
    if (action == 'set' && argument.runes.length > 4000) {
      _commandError(
        'A goal can contain at most 4,000 characters. Put longer instructions in a file and reference it.',
      );
      return true;
    }
    // Control commands never attach captured content or enter model history.
    // Keep attachments and drafts available for the next normal message.
    if (attachments.isNotEmpty && action == 'set') {
      _commandError(
        'Send or remove attached content before setting a goal. Goal commands accept a text objective.',
      );
      return true;
    }
    final targetId = activeRuntime!.id;
    final sessionId = activeSessionId!;
    final key = FocaletController._sessionKey(targetId, sessionId);
    final revision = _goalRevisions[key] ?? 0;
    sessionBusy = true;
    commandOutput = null;
    _notify();
    try {
      final response = await (core as GoalControlBridge).goalCommand(
        runtimeTargetId: targetId,
        sessionId: sessionId,
        action: action,
        objective: action == 'set' ? argument : null,
        model: FocaletController._nonEmpty(selectedModel),
        effort: FocaletController._nonEmpty(selectedEffort),
        cwd: FocaletController._nonEmpty(selectedWorkspace),
      );
      if ((_goalRevisions[key] ?? 0) == revision) {
        final value = response['goal'];
        _goalsBySession[key] = value is Map ? mapValue(value) : null;
      }
      if (!_isActiveSession(targetId, sessionId)) return true;
      goalPanelOpen = true;
      if (argument == 'edit' && _goalsBySession[key] != null) {
        final draft = '/goal ${_goalsBySession[key]!['objective']}';
        composerValue = TextEditingValue(
          text: draft,
          selection: TextSelection.collapsed(offset: draft.length),
        );
      } else {
        composerValue = TextEditingValue.empty;
      }
      commandComposerEpoch++;
      if (action == 'set') {
        _newSessions.remove(key);
        _updateSessionTitle(sessionId, argument);
        _recordSessionActivity(targetId, sessionId);
      }
      _setStatus(switch (action) {
        'set' => 'Goal set · Codex is starting',
        'pause' => 'Goal paused',
        'resume' => 'Goal resumed',
        'clear' => 'Goal cleared',
        _ => 'Goal refreshed',
      });
      focusComposerEpoch++;
    } on Object catch (error) {
      _commandError('Could not run /goal · $error');
    } finally {
      sessionBusy = false;
      _notify();
    }
    return true;
  }
}
