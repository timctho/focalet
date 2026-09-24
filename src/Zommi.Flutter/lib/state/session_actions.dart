part of 'zommi_controller.dart';

extension SessionActions on ZommiController {
  bool get sessionActionBusy =>
      starting ||
      sessionBusy ||
      runtimeBusy ||
      sessionSettingsBusy ||
      submitting ||
      selectingContent;

  bool canForkSession(SessionSummary session) =>
      core is SessionForkBridge &&
      runtimeForSession(session)?.adapterId == 'codex-app-server' &&
      !sessionActionBusy &&
      presenceFor(session.id, runtimeTargetId: session.runtimeTargetId) !=
          SessionPresence.running;

  void setSessionPinned(SessionSummary session, bool pinned) {
    final index = _summaryIndex(session);
    if (index < 0) return;
    sessions[index] = sessions[index].copyWith(pinned: pinned);
    _newSessions.remove(
      ZommiController._sessionKey(session.runtimeTargetId, session.id),
    );
    _sortSessions();
    _scheduleCatalogSave();
    _notify();
  }

  void renameSession(SessionSummary session, String title) {
    final index = _summaryIndex(session);
    title = title.trim();
    if (index < 0 || title.isEmpty) return;
    sessions[index] = sessions[index].copyWith(
      title: title,
      customTitle: title,
    );
    _newSessions.remove(
      ZommiController._sessionKey(session.runtimeTargetId, session.id),
    );
    _scheduleCatalogSave();
    _notify();
  }

  int _summaryIndex(SessionSummary session) => sessions.indexWhere(
    (item) =>
        item.id == session.id &&
        item.runtimeTargetId == session.runtimeTargetId,
  );

  Future<void> copySession(SessionSummary session) async {
    if (sessionActionBusy) return;
    sessionBusy = true;
    _notify();
    try {
      final key = ZommiController._sessionKey(
        session.runtimeTargetId,
        session.id,
      );
      List<ConversationTurn> history;
      if (_newSessions.contains(key)) {
        history = _turnsBySession[key] ?? const [];
      } else {
        if (activeRuntime?.id != session.runtimeTargetId) {
          _cacheConnection(
            await core.connectRuntime(
              runtimeTargetId: session.runtimeTargetId,
              preferredSessionId: session.id,
              cwd: session.cwd,
            ),
          );
        }
        final revision = _transcriptRevisions[key] ?? 0;
        final response = await core.readSession(
          runtimeTargetId: session.runtimeTargetId,
          sessionId: session.id,
        );
        if (mapValue(response['thread'])['id'] != session.id) {
          throw const CoreProtocolException(
            'identity-mismatch',
            'The runtime returned a different chat.',
          );
        }
        final changed = (_transcriptRevisions[key] ?? 0) != revision;
        history = mergeSessionHistory(
          mapThreadHistory(response),
          _turnsBySession[key] ?? const [],
          preserveCached: _activeTurns.containsKey(key) || changed,
          preferCachedUpdates: changed,
        );
      }
      final text = StringBuffer('# ${session.title}');
      for (final turn in history) {
        text.write('\n\n## You\n\n${turn.userText}');
        for (final block in turn.blocks) {
          if (block.text.trim().isNotEmpty) {
            text.write('\n\n## ${block.title}\n\n${block.text}');
          }
        }
      }
      await desktop.copyText(text.toString());
      _setStatus('Chat copied');
    } on Object catch (error) {
      _setStatus('Could not copy chat · $error', warning: true);
    } finally {
      sessionBusy = false;
      _notify();
    }
  }

  Future<void> duplicateSession(SessionSummary session) async {
    if (!canForkSession(session)) return;
    _cancelSwitchRecovery();
    _rememberActiveSessionSettings();
    final inherited = _settingsForSession(session.runtimeTargetId, session.id);
    sessionBusy = true;
    _notify();
    try {
      if (activeRuntime?.id != session.runtimeTargetId ||
          activeRuntime?.status == 'unavailable') {
        _cacheConnection(
          await core.connectRuntime(
            runtimeTargetId: session.runtimeTargetId,
            preferredSessionId: session.id,
            cwd: session.cwd,
          ),
        );
      }
      final connection = await (core as SessionForkBridge).forkSession(
        runtimeTargetId: session.runtimeTargetId,
        sessionId: session.id,
      );
      if (connection.runtimeTargetId != session.runtimeTargetId ||
          connection.sessionId == session.id ||
          connection.sessionId.isEmpty) {
        throw const CoreProtocolException(
          'identity-mismatch',
          'The runtime did not create a separate chat.',
        );
      }
      await _applySessionConnection(connection, inherited: inherited);
      final duplicate = sessions.firstWhere(
        (s) =>
            s.runtimeTargetId == connection.runtimeTargetId &&
            s.id == connection.sessionId,
      );
      renameSession(duplicate, '${session.title} (copy)');
      _recordSessionActivity(connection.runtimeTargetId, connection.sessionId);
      _setStatus('Chat duplicated');
    } on Object catch (error) {
      _setStatus('Could not duplicate chat · $error', warning: true);
    } finally {
      sessionBusy = false;
      _notify();
    }
  }

  void deleteSessionMetadata(SessionSummary session) {
    if (sessionActionBusy) return;
    final identity = (session.runtimeTargetId, session.id);
    final key = ZommiController._sessionKey(identity.$1, identity.$2);
    // A tombstone prevents provider refresh from recreating the sidebar row.
    // Runtime history and any running turn remain owned by the provider.
    _dismissedSessions.add(identity);
    sessions.removeWhere((s) => (s.runtimeTargetId, s.id) == identity);
    _newSessions.remove(key);
    _drafts.remove(key);
    _inputHistory.remove(key);
    _messageQueues.remove(key);
    _pausedQueues.remove(key);
    _sessionSettings.remove(key);
    _turnsBySession.remove(key);
    _historyEpochs[key] = (_historyEpochs[key] ?? 0) + 1;
    _historyNextCursor.remove(key);
    _historyPageErrors.remove(key);
    _transcriptRevisions.remove(key);
    _unreadSessions.remove(key);
    if (_activeSessionKey == key) {
      _cancelSwitchRecovery();
      activeSessionId = null;
      composerValue = TextEditingValue.empty;
      attachments.clear();
      _attachmentSequence = 0;
      _composerAttachmentOrder = null;
      previewAttachment = null;
      previewArtifact = null;
      _approvals.removeWhere(
        (request) =>
            ZommiController._sessionKey(
              request.runtimeTargetId,
              request.sessionId,
            ) ==
            key,
      );
      question = null;
      commandOutput = null;
      goalPanelOpen = false;
    }
    _scheduleCatalogSave();
    _setStatus('Chat removed from Zommi');
  }
}
