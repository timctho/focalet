import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:focalet_flutter/core/core_bridge.dart';
import 'package:focalet_flutter/core/runtime_order.dart';
import 'package:focalet_flutter/state/codex_status.dart';
import 'package:focalet_flutter/desktop/artifact_loader.dart';
import 'package:focalet_flutter/desktop/desktop_bridge.dart';
import 'package:focalet_flutter/state/history_mapper.dart';
import 'package:focalet_flutter/state/runtime_command_catalog.dart';
import 'package:focalet_flutter/state/session_catalog_store.dart';
import 'package:focalet_flutter/state/focalet_models.dart';
import 'package:focalet_flutter/theme/app_preferences.dart';

part 'codex_commands.dart';
part 'runtime_commands.dart';
part 'session_actions.dart';
part 'paged_history.dart';

const int historyPageSize = 18;
const int sessionPageSize = 20;
const int composerHistoryLimit = 20;

final class _SessionDraft {
  const _SessionDraft({
    required this.value,
    required this.attachments,
    required this.attachmentSequence,
  });
  final TextEditingValue value;
  final List<ContextAttachment> attachments;
  final int attachmentSequence;
}

final class FocaletController extends ChangeNotifier {
  FocaletController({
    required this.core,
    required this.desktop,
    ArtifactLoader? artifactLoader,
    this.sessionCatalogStore = const NoopSessionCatalogStore(),
    this.catalogStartupDelay = Duration.zero,
    this.runtimeSetupPending = false,
    this.prepareImageCapture,
    DateTime Function()? clock,
    WindowSizeSetting initialWindowSize = WindowSizeSetting.standard,
  }) : artifactLoader = artifactLoader ?? const LocalArtifactLoader(),
       windowSize = initialWindowSize,
       _clock = clock ?? DateTime.now;

  final CoreBridge core;
  final DesktopBridge desktop;
  final Future<bool> Function()? prepareImageCapture;
  final ArtifactLoader artifactLoader;
  final SessionCatalogStore sessionCatalogStore;
  final Duration catalogStartupDelay;
  final DateTime Function() _clock;

  final List<RuntimeTarget> runtimeTargets = [];
  final List<SessionSummary> sessions = [];
  final List<Map<String, Object?>> models = [];
  final List<ContextAttachment> attachments = [];
  TextEditingValue composerValue = TextEditingValue.empty;
  List<String>? _composerAttachmentOrder;
  final Map<String, _SessionDraft> _drafts = {};
  final Map<String, List<String>> _inputHistory = {};
  final Map<String, List<ComposerCommand>> _commandCatalogs = {};
  final Map<String, String> _commandContexts = {};
  final Map<String, String> _commandErrors = {};
  final Map<String, int> _commandRevisions = {};
  final Map<String, int> _commandRequests = {};
  final Map<String, List<QueuedMessage>> _messageQueues = {};
  final Set<String> _pausedQueues = {};
  final Set<String> _startingSessions = {};
  final Set<String> _newSessions = {};
  final Set<(String, String)> _dismissedSessions = {};
  Map<String, Object?> runtimeSettings = {};
  final Map<String, List<ConversationTurn>> _turnsBySession = {};
  final Map<String, int> _transcriptRevisions = {};
  final Map<String, int> _historyEpochs = {};
  final Map<String, Set<String>> _discardedTurnIds = {};
  final Map<String, String> _activeTurns = {};
  final Set<String> _unreadSessions = {};
  final Set<String> _cancelRequestedSessions = {};
  final Set<String> _interruptingSessions = {};
  final Map<String, String> _completedTurnIds = {};
  final Set<(String, String, String)> _notifiedTurns = {};
  DesktopInvocation? _pendingNotificationOpen;

  bool get _canOpenNotification =>
      !starting &&
      !runtimeBusy &&
      !sessionSettingsBusy &&
      !submitting &&
      !selectingContent &&
      (!sessionBusy || _switchWorker != null);
  final Map<String, int> _lastSequences = {};
  final Map<String, SessionSettings> _sessionSettings = {};
  final Map<String, List<Map<String, Object?>>> _modelCatalogs = {};
  final Map<String, String> _runtimeTargetAliases = {};
  final Set<String> _detectedRuntimeIds = {};
  final Map<String, RuntimeTarget> _knownRuntimes = {};
  final Map<String, Set<String>> _runtimeCapabilities = {};
  final Map<String, DateTime> _catalogSyncedAt = {};
  final Map<String, DateTime> _catalogAttemptedAt = {};
  final Map<String, DateTime> _catalogUsedAt = {};
  final List<(RuntimeTarget, Completer<void>)> _catalogQueue = [];
  int _catalogWorkerCount = 0;
  Timer? _catalogStartupTimer;
  Timer? _catalogSaveTimer;
  Timer? _catalogRetentionTimer;
  Future<void>? _catalogSave;
  bool _catalogRestored = false;
  final Set<String> _catalogLoading = {};
  final Set<String> _catalogErrors = {};

  StreamSubscription<CoreEvent>? _coreEvents;
  StreamSubscription<DesktopInvocation>? _desktopEvents;
  RuntimeTarget? activeRuntime;
  String? activeSessionId;
  Set<String> capabilities = {};
  String selectedModel = '';
  String selectedEffort = '';
  String selectedWorkspace = '';
  String? workspaceError;
  String selectedProfile = '';
  List<Map<String, Object?>> profiles = [];
  String status = 'Connecting to Rust core…';
  bool statusWarning = false;
  bool coreConnectionFailed = false;
  String? connectionErrorTargetId;
  String? connectionErrorSessionId;
  (String targetId, String action)? _runtimeRecovery;
  bool _retryCreatesSession = false;
  bool initialized = false;
  bool starting = true;
  bool runtimeBusy = false;
  bool runtimeDiscoveryBusy = false;
  String? runtimeDiscoveryError;
  String? switchingRuntimeId;
  bool runtimeOverrideBusy = false;
  bool sessionBusy = false;
  final Set<String> _readOnlySessions = {};
  final Set<String> _connectedRuntimes = {};
  bool get sessionReadOnly => _readOnlySessions.contains(_activeSessionKey);
  (String, String)? _pendingSwitch;
  Future<void>? _switchWorker;
  String? _switchWorkerTargetId;
  int _switchWorkerGeneration = 0;
  final Set<String> _runtimePreparations = {};
  final List<String> _runtimePreparationQueue = [];
  int _runtimePreparationCount = 0;
  String? _startupRuntimeId;
  Timer? _switchRetryTimer;
  int _switchEpoch = 0;
  int _switchFailures = 0;
  final Map<String, String> _historyNextCursor = {};
  final Set<String> _historyPagesLoading = {};
  final Map<String, String> _historyPageErrors = {};
  bool sessionSettingsBusy = false;
  bool get submitting => _startingSessions.isNotEmpty;
  bool selectingContent = false;
  int _attachmentSequence = 0;
  bool expanded = true;
  WindowSizeSetting windowSize;
  WindowSizeSetting _restoredWindowSize = WindowSizeSetting.standard;
  bool get largePanel => windowSize == WindowSizeSetting.wide;
  bool get maximizedPanel => windowSize == WindowSizeSetting.maximized;
  bool surfaceTransitioning = false;
  bool surfaceTransitionAnimating = false;
  bool transitionTargetExpanded = true;
  bool transitionTargetLarge = false;
  bool sessionPanelOpen = true;
  bool showingOlderSessions = false;
  int _visibleSessionLimit = sessionPageSize;
  bool _loadingMoreSessions = false;
  bool runtimeSetupPanelOpen = false;
  bool runtimeSetupPending;
  bool modelPanelOpen = false;
  bool workspacePanelOpen = false;
  bool appSettingsPanelOpen = false;
  bool sessionSettingsDetailOpen = false;
  bool contextShortcutRegistered = false;
  bool imageShortcutRegistered = false;
  int focusComposerEpoch = 0;
  int sessionSettingsOverviewEpoch = 0;
  final List<PendingApproval> _approvals = [];
  PendingApproval? get approval => _approvals.firstOrNull;
  int get pendingApprovalCount => _approvals.length;
  String get approvalSource {
    final request = approval;
    if (request == null) return '';
    final runtime =
        _runtimeTarget(request.runtimeTargetId)?.displayName ?? 'Agent';
    final chat = sessions
        .where(
          (session) =>
              session.id == request.sessionId &&
              session.runtimeTargetId == request.runtimeTargetId,
        )
        .firstOrNull;
    return '$runtime · ${chat?.title ?? request.sessionId}';
  }

  PendingQuestion? question;
  ContextAttachment? previewAttachment;
  ArtifactPreview? previewArtifact;
  bool resolvingPrompt = false;
  String? commandOutput;
  int _statusRequest = 0;
  int commandComposerEpoch = 0;
  bool goalPanelOpen = false;
  final Map<String, Map<String, Object?>?> _goalsBySession = {};
  final Map<String, int> _goalRevisions = {};
  bool _closed = false;
  int _localTurnSequence = 0;
  int _surfaceTransitionEpoch = 0;

  String? get _activeSessionKey {
    final runtimeTargetId = activeRuntime?.id;
    final sessionId = activeSessionId;
    return runtimeTargetId == null || sessionId == null
        ? null
        : _sessionKey(runtimeTargetId, sessionId);
  }

  String? get composerSessionKey => _activeSessionKey;

  /// Most recent first, including messages submitted during this app session.
  List<String> get composerHistory {
    final history = <String>[];
    for (final text in [
      ...?_inputHistory[_activeSessionKey]?.reversed,
      ...turns.reversed.map((turn) => turn.userText),
    ]) {
      if (text.trim().isEmpty || history.contains(text)) continue;
      history.add(text);
      if (history.length == composerHistoryLimit) break;
    }
    return history;
  }

  List<QueuedMessage> get queuedMessages =>
      List.unmodifiable(_messageQueues[_activeSessionKey] ?? const []);

  bool get queuePaused => _pausedQueues.contains(_activeSessionKey);

  void removeQueuedMessage(String id) {
    _messageQueues[_activeSessionKey]?.removeWhere((item) => item.id == id);
    _notify();
  }

  void resumeQueuedMessages() {
    final key = _activeSessionKey;
    if (key == null || sessionReadOnly || sessionBusy || runtimeBusy) return;
    _pausedQueues.remove(key);
    _drainMessageQueue(key);
    _notify();
  }

  void _drainMessageQueue(String sessionKey) {
    final queue = _messageQueues[sessionKey];
    if (_closed ||
        queue == null ||
        queue.isEmpty ||
        _activeTurns.containsKey(sessionKey) ||
        _startingSessions.contains(sessionKey) ||
        _readOnlySessions.contains(sessionKey) ||
        _pausedQueues.contains(sessionKey)) {
      return;
    }
    unawaited(_startMessage(queue.removeAt(0)));
  }

  void updateComposerValue(
    TextEditingValue value, {
    List<String>? attachmentOrder,
  }) {
    composerValue = value;
    _composerAttachmentOrder = attachmentOrder;
  }

  void _saveSessionDraft() {
    final key = _activeSessionKey;
    if (key == null) return;
    if (_newSessions.contains(key) &&
        composerValue.text.trim().isEmpty &&
        attachments.isEmpty &&
        turns.isEmpty &&
        !turnActive) {
      final identity = (activeRuntime!.id, activeSessionId!);
      _dismissedSessions.add(identity);
      sessions.removeWhere(
        (session) => (session.runtimeTargetId, session.id) == identity,
      );
      _newSessions.remove(key);
      _drafts.remove(key);
      _sessionSettings.remove(key);
      _turnsBySession.remove(key);
      _transcriptRevisions.remove(key);
      _scheduleCatalogSave();
      return;
    }
    _drafts[key] = _SessionDraft(
      value: composerValue.copyWith(composing: TextRange.empty),
      attachments: _orderedAttachments(_composerAttachmentOrder),
      attachmentSequence: _attachmentSequence,
    );
  }

  void _restoreSessionDraft() {
    final draft = _drafts[_activeSessionKey];
    composerValue = draft?.value ?? TextEditingValue.empty;
    attachments
      ..clear()
      ..addAll(draft?.attachments ?? const []);
    _attachmentSequence = draft?.attachmentSequence ?? 0;
    _composerAttachmentOrder = null;
    previewAttachment = null;
  }

  List<ConversationTurn> get turns =>
      _turnsBySession[_activeSessionKey] ?? const [];

  /// Visible content changes only; folded activity deltas, folding UI and
  /// unrelated sessions must not make the transcript follow a new message.
  int get transcriptRevision => _transcriptRevisions[_activeSessionKey] ?? 0;

  void _transcriptChanged(String sessionKey) {
    _transcriptRevisions.update(
      sessionKey,
      (value) => value + 1,
      ifAbsent: () => 1,
    );
  }

  String? get activeTurnId => _activeTurns[_activeSessionKey];

  bool get turnActive => activeTurnId != null;

  bool get activeTurnStopping =>
      _activeSessionKey != null &&
      _interruptingSessions.contains(_activeSessionKey);

  bool get anyTurnActive => _activeTurns.isNotEmpty;

  SessionSettings get activeSessionSettings => SessionSettings(
    workspace: selectedWorkspace,
    model: selectedModel,
    effort: selectedEffort,
    profile: selectedProfile,
  );

  List<RuntimeTarget> get visibleRuntimeTargets =>
      _deduplicateRuntimeTargets(runtimeTargets);

  bool get imageInputSupported =>
      activeRuntime == null || capabilities.contains('input.image.v1');

  bool get sessionNavigationSupported =>
      initialized || sessions.isNotEmpty || visibleRuntimeTargets.isNotEmpty;

  bool get sessionCreationSupported =>
      visibleRuntimeTargets.any(canCreateSession);

  bool get sessionCatalogLoading => _catalogLoading.isNotEmpty;

  List<SessionSummary> get _availableSessions {
    if (showingOlderSessions) return sessions;
    final cutoff = _clock().toUtc().subtract(sessionCatalogRetention);
    return sessions.where((session) {
      final key = _sessionKey(session.runtimeTargetId, session.id);
      return session.pinned ||
          key == _activeSessionKey ||
          _activeTurns.containsKey(key) ||
          session.activityTime?.isBefore(cutoff) != true;
    }).toList();
  }

  List<SessionSummary> get visibleSessions =>
      _availableSessions.take(_visibleSessionLimit).toList();

  bool get hasMoreSessions =>
      !showingOlderSessions || _availableSessions.length > _visibleSessionLimit;

  Future<void> loadMoreSessions() async {
    if (_closed || starting || _loadingMoreSessions || !hasMoreSessions) return;
    _loadingMoreSessions = true;
    try {
      final revealOlder =
          _availableSessions.length <= _visibleSessionLimit &&
          !showingOlderSessions;
      _visibleSessionLimit += sessionPageSize;
      if (revealOlder) showingOlderSessions = true;
      _notify();
      if (revealOlder) await refreshSessionCatalog(force: true);
    } finally {
      _loadingMoreSessions = false;
    }
  }

  String? get sessionCatalogError {
    final names = visibleRuntimeTargets
        .where((target) => _catalogErrors.contains(target.id))
        .map((target) => target.displayName)
        .toSet();
    return names.isEmpty
        ? null
        : '${names.join(', ')} chats could not be loaded';
  }

  bool canCreateSession(RuntimeTarget target) =>
      (_runtimeCapabilities[target.id] ?? target.capabilityHints.toSet())
          .contains('session.create.v1');

  RuntimeTarget? runtimeForSession(SessionSummary session) =>
      _runtimeTarget(session.runtimeTargetId);

  RuntimeTarget? _runtimeTarget(String id) =>
      runtimeTargets.cast<RuntimeTarget?>().firstWhere(
        (target) => target?.id == id,
        orElse: () => _knownRuntimes[id],
      );

  bool get modelSelectionSupported =>
      capabilities.contains('model.select.v1') && models.isNotEmpty;

  bool get sessionSettingsSupported => activeSessionId != null;

  bool get profileSelectionSupported =>
      activeRuntime?.runtimeId == 'hermes' &&
      activeRuntime?.adapterId == 'hermes-gateway' &&
      profiles.isNotEmpty;

  bool get runtimeOverridesSupported => core is RuntimeConfigurationBridge;

  List<Map<String, Object?>> get runtimeOverrideAdapters =>
      mapList(runtimeSettings['adapters'])..sort(compareRuntimeAdapters);

  List<Map<String, Object?>> get configurableRuntimeAdapters =>
      runtimeOverrideAdapters
          .where((adapter) => adapter['acceptsEndpoint'] != true)
          .toList(growable: false);

  List<Map<String, Object?>> get runtimeOverrideHosts =>
      mapList(runtimeSettings['hosts']);

  List<Map<String, Object?>> get runtimeOverrides =>
      mapList(runtimeSettings['overrides']);

  String get activeRuntimeName => activeRuntime?.displayName ?? 'Agent';

  String? get switchingRuntimeName => runtimeTargets
      .cast<RuntimeTarget?>()
      .firstWhere(
        (target) => target?.id == switchingRuntimeId,
        orElse: () => null,
      )
      ?.displayName;

  String get modelSummary {
    final selected = models.cast<Map<String, Object?>?>().firstWhere(
      (model) => _modelId(model!) == selectedModel,
      orElse: () => null,
    );
    final name =
        selected?['displayName']?.toString() ??
        (selectedModel.isEmpty ? 'Default model' : selectedModel);
    return selectedEffort.isEmpty
        ? name
        : '$name · ${_formatEffort(selectedEffort)}';
  }

  String get workspaceSummary {
    final value = selectedWorkspace.trim();
    if (value.isEmpty) return 'Runtime default';
    final normalized = value.replaceAll('\\', '/');
    final segments = normalized.split('/').where((part) => part.isNotEmpty);
    return segments.isEmpty ? value : segments.last;
  }

  String get profileSummary => selectedProfile.trim().isEmpty
      ? 'Default profile'
      : selectedProfile.trim();

  Future<void> initialize() async {
    if (initialized || _closed) return;
    initialized = true;
    _coreEvents = core.events.listen(_handleCoreEvent);
    _desktopEvents = desktop.invocations.listen((invocation) {
      unawaited(_handleDesktopInvocation(invocation));
    });
    final desktopInitialization = _initializeDesktopIntegration();
    (String, String)? startupRecovery;
    final startupEpoch = _switchEpoch;
    try {
      await _restoreSessionCatalog();
      if (_closed) return;
      final coreStatus = await core.initialize();
      coreConnectionFailed = false;
      _setStatus('Finding agent runtimes…');
      final discovery = await core.discoverRuntimeTargets();
      if (_closed) return;
      _replaceDiscovery(discovery);
      // Only discovery gates the initial shell. Runtime processes can now start
      // independently while settings, drafts and other sessions remain usable.
      starting = false;
      _notify();
      final selectedTarget = _visibleSelectedTargetId(
        discovery.selectedTargetId,
      );
      _startupRuntimeId = runtimeSetupPending ? null : selectedTarget;
      _prepareRuntimes(except: _startupRuntimeId);
      _scheduleStartupCatalogRefresh();
      if (runtimeSetupPending) {
        _setStatus('Choose an agent to get started');
        return;
      }
      final targetId = _visibleSelectedTargetId(discovery.selectedTargetId);
      if (targetId == null || targetId.isEmpty) {
        _setStatus(
          'No supported agent found. Capture remains available.',
          warning: true,
        );
        return;
      }
      _setStatus(
        'Connecting to ${_runtimeTarget(targetId)?.displayName ?? 'agent'}…',
      );
      try {
        await _connectRuntime(
          targetId,
          coreVersion: coreStatus.version,
          selectionEpoch: startupEpoch,
        );
      } on Object catch (error) {
        if (_closed || startupEpoch != _switchEpoch) return;
        if (!_applyConnectionError(targetId, error)) {
          final binding = discovery.binding;
          final savedSession = activeRuntime?.id == targetId
              ? activeSessionId
              : binding['runtimeTargetId'] == targetId
              ? binding['sessionId']?.toString()
              : null;
          if (!_canRetrySwitch(error) ||
              savedSession == null ||
              savedSession.isEmpty) {
            rethrow;
          }
          // Freeze the remembered chat, including its profile/workspace, before
          // retrying. A later catalog refresh must not select a different chat.
          final metadata =
              binding['sessionId'] == savedSession &&
                  binding['runtimeTargetId'] == targetId
              ? {...binding, ...mapValue(binding['sessionMetadata'])}
              : const <String, Object?>{};
          final key = _sessionKey(targetId, savedSession);
          final settings = _settingsForSession(targetId, savedSession);
          _sessionSettings.putIfAbsent(
            key,
            () => settings.copyWith(
              workspace:
                  _nonEmpty(metadata['cwd']?.toString()) ?? settings.workspace,
              profile:
                  _nonEmpty(metadata['profile']?.toString()) ??
                  settings.profile,
            ),
          );
          startupRecovery = (targetId, savedSession);
        }
      }
    } on Object catch (error) {
      coreConnectionFailed = _startupRuntimeId == null && activeRuntime == null;
      if (error is CoreProtocolException &&
          !{
            'core-exited',
            'core-timeout',
            'unsupported-version',
          }.contains(error.code)) {
        _setStatus(
          'Agent runtime unavailable · ${error.message}',
          warning: true,
        );
      } else {
        _setStatus('Rust core unavailable · $error', warning: true);
      }
      if ((_startupRuntimeId ?? activeRuntime?.id) case final target?) {
        _rememberConnectionFailure(target, session: activeSessionId);
      }
    } finally {
      await desktopInitialization;
      _startupRuntimeId = null;
      starting = false;
      final recovery = startupRecovery;
      if (!_closed && recovery != null && startupEpoch == _switchEpoch) {
        _scheduleSwitchRecovery(recovery.$1, recovery.$2, _switchEpoch);
      }
      _notify();
    }
  }

  void _prepareRuntimes({String? except}) {
    if (_closed || runtimeSetupPending || core is! RuntimePreparationBridge) {
      return;
    }
    for (final target in visibleRuntimeTargets) {
      if (target.id == except ||
          !const {
            'codex-app-server',
            'hermes-acp',
            'opencode-acp',
            'gemini-acp',
            'claude-stream-json',
            'openclaw-acp',
            'hermes-gateway',
            'openclaw-gateway',
          }.contains(target.adapterId) ||
          !_runtimePreparations.add(target.id)) {
        continue;
      }
      _runtimePreparationQueue.add(target.id);
    }
    _drainRuntimePreparations();
  }

  void _drainRuntimePreparations() {
    while (!_closed &&
        _runtimePreparationCount < 2 &&
        _runtimePreparationQueue.isNotEmpty) {
      final targetId = _runtimePreparationQueue.removeAt(0);
      _runtimePreparationCount++;
      unawaited(
        (core as RuntimePreparationBridge)
            .prepareRuntime(runtimeTargetId: targetId)
            .catchError((Object _) {
              // A selection retries preparation failures through normal connection.
              _runtimePreparations.remove(targetId);
            })
            .whenComplete(() {
              _runtimePreparationCount--;
              _drainRuntimePreparations();
            }),
      );
    }
  }

  Future<void> _initializeDesktopIntegration() async {
    try {
      final readiness = await desktop.initialize();
      if (largePanel || maximizedPanel) {
        await desktop.setSurface(
          expanded: true,
          large: largePanel,
          maximized: maximizedPanel,
          animate: false,
        );
      }
      contextShortcutRegistered = readiness.contextShortcut;
      imageShortcutRegistered = readiness.imageShortcut;
      _notify();
    } on Object catch (error) {
      _setStatus('Desktop integration unavailable · $error', warning: true);
    }
  }

  Future<void> refreshRuntimes() async {
    if (_closed ||
        starting ||
        runtimeBusy ||
        sessionBusy ||
        sessionSettingsBusy ||
        submitting ||
        anyTurnActive ||
        runtimeDiscoveryBusy ||
        runtimeOverrideBusy) {
      return;
    }
    runtimeDiscoveryBusy = true;
    runtimeBusy = true;
    runtimeDiscoveryError = null;
    _notify();
    try {
      final discovery = await core.discoverRuntimeTargets(
        lastSelectedTargetId: activeRuntime?.id,
        force: true,
      );
      if (_closed) return;
      _replaceDiscovery(discovery);
      coreConnectionFailed = false;
      if (!runtimeSetupPending && core is RuntimeModelRefreshBridge) {
        final refreshable = core as RuntimeModelRefreshBridge;
        final failures = <String>[];
        await Future.wait([
          for (final target in visibleRuntimeTargets)
            () async {
              try {
                final inventory = await refreshable.refreshRuntimeModels(
                  runtimeTargetId: target.id,
                );
                if (_closed || inventory == null) return;
                _modelCatalogs[target.id] = List.of(inventory);
                if (inventory.isNotEmpty) {
                  (_runtimeCapabilities[target.id] ??= {}).add(
                    'model.select.v1',
                  );
                } else {
                  _runtimeCapabilities[target.id]?.removeAll({
                    'model.select.v1',
                    'reasoning.select.v1',
                  });
                }
                if (activeRuntime?.id == target.id) {
                  models
                    ..clear()
                    ..addAll(inventory);
                  capabilities =
                      _runtimeCapabilities[target.id] ?? capabilities;
                }
              } on Object {
                failures.add(target.displayName);
              }
            }(),
        ]);
        if (!_closed && failures.isNotEmpty) {
          runtimeDiscoveryError =
              'Could not refresh models for ${failures.toSet().join(', ')}. Try again.';
        }
      }
      _prepareRuntimes(except: activeRuntime?.id);
    } on Object {
      if (!_closed) {
        runtimeDiscoveryError = 'Could not refresh agents. Try again.';
      }
    } finally {
      runtimeDiscoveryBusy = false;
      runtimeBusy = false;
      _notify();
    }
  }

  Future<void> _restoreSessionCatalog() async {
    try {
      final snapshot = await sessionCatalogStore.load();
      if (_closed) return;
      sessions.addAll(snapshot.sessions);
      _dismissedSessions.addAll(snapshot.dismissedSessions);
      sessions.removeWhere(
        (session) =>
            _dismissedSessions.contains((session.runtimeTargetId, session.id)),
      );
      for (final runtime in snapshot.runtimes) {
        _knownRuntimes[runtime.id] = runtime;
      }
      _catalogSyncedAt.addAll(snapshot.syncedAt);
      _catalogAttemptedAt.addAll(snapshot.attemptedAt);
      _catalogUsedAt.addAll(snapshot.usedAt);
      _sortSessions();
      _notify();
    } on Object {
      // A rebuildable cache must never prevent the app from connecting.
    } finally {
      _catalogRestored = true;
    }
  }

  Future<bool> connectRuntimeForSetup(String targetId) async {
    if (starting || runtimeBusy || runtimeOverrideBusy) return false;
    _cancelSwitchRecovery();
    final epoch = _switchEpoch;
    runtimeBusy = true;
    switchingRuntimeId = targetId;
    _setStatus('Connecting to agent…');
    try {
      await _connectRuntime(targetId, selectionEpoch: epoch);
      if (_closed || epoch != _switchEpoch) return false;
      return activeRuntime?.id == targetId && activeSessionId != null;
    } on Object catch (error) {
      if (_closed || epoch != _switchEpoch) return false;
      _rememberConnectionFailure(targetId);
      if (!_applyConnectionError(targetId, error, activateTarget: false)) {
        _setStatus('Could not connect · $error', warning: true);
      }
      return false;
    } finally {
      if (epoch == _switchEpoch) {
        runtimeBusy = false;
        switchingRuntimeId = null;
        _notify();
      }
    }
  }

  void completeRuntimeSetup() {
    runtimeSetupPending = false;
    runtimeSetupPanelOpen = false;
    focusComposerEpoch++;
    _notify();
    _scheduleStartupCatalogRefresh();
  }

  void _scheduleStartupCatalogRefresh() {
    if (runtimeSetupPending) return;
    if (_closed) return;
    if (sessionCatalogStore is! NoopSessionCatalogStore) {
      _catalogRetentionTimer = Timer.periodic(const Duration(hours: 1), (_) {
        _scheduleCatalogSave();
        _notify();
      });
    }
    if (catalogStartupDelay == Duration.zero) {
      unawaited(refreshSessionCatalog());
    } else {
      _catalogStartupTimer = Timer(catalogStartupDelay, () {
        unawaited(refreshSessionCatalog());
      });
    }
  }

  bool _catalogIsDue(String id) {
    final now = _clock().toUtc();
    final attempt = _catalogAttemptedAt[id];
    // Persist retry cooldowns too, so repeated launches do not hammer an
    // unavailable provider. Explicit refresh/retry bypasses this cooldown.
    if (attempt != null &&
        now.difference(attempt) < const Duration(minutes: 2) &&
        !attempt.isAfter(now)) {
      return false;
    }
    final synced = _catalogSyncedAt[id];
    if (synced == null || synced.isAfter(now)) return true;
    final used = _catalogUsedAt[id];
    final recentlyUsed =
        used != null && now.difference(used) < const Duration(days: 7);
    final ttl = recentlyUsed
        ? const Duration(minutes: 15)
        : const Duration(hours: 6);
    return now.difference(synced) >= ttl;
  }

  Future<void> refreshSessionCatalog({bool force = false}) async {
    if (_closed || starting || core is! SessionCatalogBridge) return;
    final targets =
        visibleRuntimeTargets
            .where(
              (target) =>
                  target.id != _startupRuntimeId &&
                  target.capabilityHints.contains('session.list.v1') &&
                  !_catalogLoading.contains(target.id) &&
                  (force || _catalogIsDue(target.id)),
            )
            .toList()
          ..sort(
            (a, b) => (_catalogUsedAt[b.id]?.millisecondsSinceEpoch ?? 0)
                .compareTo(_catalogUsedAt[a.id]?.millisecondsSinceEpoch ?? 0),
          );
    final completed = <Future<void>>[];
    for (final target in targets) {
      final completion = Completer<void>();
      _catalogQueue.add((target, completion));
      _catalogLoading.add(target.id);
      completed.add(completion.future);
    }
    if (targets.isNotEmpty) _notify();
    _drainCatalogQueue();
    await Future.wait(completed);
  }

  void _drainCatalogQueue() {
    // One global queue also bounds overlapping startup, retry and discovery
    // refreshes. A slow provider does not hold the next available worker slot.
    while (!_closed && _catalogWorkerCount < 2 && _catalogQueue.isNotEmpty) {
      final (target, completion) = _catalogQueue.removeAt(0);
      _catalogWorkerCount++;
      unawaited(
        _loadCatalog(target).whenComplete(() {
          _catalogWorkerCount--;
          _catalogLoading.remove(target.id);
          completion.complete();
          _notify();
          _drainCatalogQueue();
        }),
      );
    }
  }

  Future<void> _loadCatalog(RuntimeTarget target) async {
    if (!visibleRuntimeTargets.any((value) => value.id == target.id)) {
      return;
    }
    _catalogAttemptedAt[target.id] = _clock().toUtc();
    _scheduleCatalogSave();
    try {
      final values = target.id == activeRuntime?.id
          ? await core.listSessions(runtimeTargetId: target.id)
          : await (core as SessionCatalogBridge).listSessionCatalog(
              runtimeTargetId: target.id,
            );
      if (_closed ||
          !visibleRuntimeTargets.any((value) => value.id == target.id)) {
        return;
      }
      _knownRuntimes[target.id] = target;
      _mergeSessions(target.id, values);
      _hydrateSessionSettingsFromSummaries(target.id);
      _markCatalogSynced(target.id);
    } on Object {
      if (!_closed) _catalogErrors.add(target.id);
    }
  }

  void _markCatalogSynced(String id) {
    _catalogSyncedAt[id] = _clock().toUtc();
    _catalogErrors.remove(id);
    _scheduleCatalogSave();
  }

  void _scheduleCatalogSave() {
    if (_closed ||
        !_catalogRestored ||
        sessionCatalogStore is NoopSessionCatalogStore) {
      return;
    }
    // Coalesce streaming activity without postponing writes indefinitely.
    _catalogSaveTimer ??= Timer(const Duration(milliseconds: 250), () {
      _catalogSaveTimer = null;
      unawaited(flushSessionCatalog());
    });
  }

  Future<void> flushSessionCatalog() {
    _catalogSaveTimer?.cancel();
    _catalogSaveTimer = null;
    if (!_catalogRestored || sessionCatalogStore is NoopSessionCatalogStore) {
      return Future.value();
    }
    final snapshot = SessionCatalogSnapshot(
      runtimes: _knownRuntimes.values.toList(),
      sessions: List.of(sessions),
      dismissedSessions: Set.of(_dismissedSessions),
      syncedAt: Map.of(_catalogSyncedAt),
      attemptedAt: Map.of(_catalogAttemptedAt),
      usedAt: Map.of(_catalogUsedAt),
      protectedSessions: {
        for (final session in sessions)
          if (_isActiveSession(session.runtimeTargetId, session.id) ||
              _activeTurns.containsKey(
                _sessionKey(session.runtimeTargetId, session.id),
              ))
            (session.runtimeTargetId, session.id),
      },
    ).retained(_clock());
    final write = (_catalogSave ?? Future<void>.value())
        .then((_) => sessionCatalogStore.save(snapshot))
        .catchError((Object _) {});
    _catalogSave = write;
    return write;
  }

  Future<void> selectRuntime(String targetId) async {
    final selectingActiveRuntime = activeRuntime?.id == targetId;
    final activeRuntimeUnavailable =
        selectingActiveRuntime &&
        (activeRuntime?.status == 'unavailable' || _switchFailures > 0);
    if (runtimeBusy ||
        sessionBusy ||
        sessionSettingsBusy ||
        submitting ||
        selectingContent) {
      return;
    }
    if (selectingActiveRuntime && !activeRuntimeUnavailable) {
      _cancelSwitchRecovery();
      closeTransientPanels();
      return;
    }
    _cancelSwitchRecovery();
    runtimeBusy = true;
    final epoch = _switchEpoch;
    switchingRuntimeId = targetId;
    question = null;
    previewArtifact = null;
    closeTransientPanels();
    _setStatus('Switching to ${switchingRuntimeName ?? 'agent'}…');
    try {
      await _connectRuntime(targetId, selectionEpoch: epoch);
    } on Object catch (error) {
      if (_closed || epoch != _switchEpoch) return;
      if (!_applyConnectionError(
        targetId,
        error,
        activateTarget:
            activeSessionId == null || activeRuntime?.id == targetId,
      )) {
        _setStatus('Could not switch agent · $error', warning: true);
      }
      _rememberConnectionFailure(targetId);
    } finally {
      if (epoch == _switchEpoch) {
        runtimeBusy = false;
        switchingRuntimeId = null;
        _notify();
      }
    }
  }

  bool _applyConnectionError(
    String targetId,
    Object error, {
    bool activateTarget = true,
  }) {
    final message = error is CoreProtocolException
        ? error.message
        : error.toString();
    final target = _runtimeTarget(targetId);
    _runtimeRecovery = switch ((error, target?.adapterId)) {
      (
        CoreProtocolException(code: 'runtime-update-required'),
        'claude-stream-json',
      ) =>
        (targetId, 'update'),
      (CoreProtocolException(code: 'gateway-unavailable'), 'openclaw-acp') => (
        targetId,
        'setup',
      ),
      _ => null,
    };
    if (_runtimeRecovery != null) {
      _setStatus(message, warning: true);
      return true;
    }
    final authenticationRequired =
        error is CoreProtocolException &&
            error.code == 'authentication-required' ||
        RegExp(
          r'authentication required|sign[ -]?in required|not logged in',
          caseSensitive: false,
        ).hasMatch(message);
    if (!authenticationRequired) return false;
    final index = runtimeTargets.indexWhere((target) => target.id == targetId);
    if (index >= 0) {
      runtimeTargets[index] = runtimeTargets[index].copyWith(
        status: 'sign-in-required',
      );
      if (activateTarget) {
        activeRuntime = runtimeTargets[index];
        capabilities = activeRuntime!.capabilityHints.toSet();
      }
    }
    _setStatus(
      '${_runtimeTarget(targetId)?.displayName ?? 'Agent'} sign-in required · ${error is CoreProtocolException ? error.message : message}',
      warning: true,
    );
    return true;
  }

  Future<void> openRuntimeSignIn({String? runtimeTargetId}) async {
    final runtime = runtimeTargetId == null
        ? activeRuntime
        : _runtimeTarget(runtimeTargetId);
    if (runtime == null) return;
    try {
      await desktop.openRuntimeSignIn(runtime);
      _setStatus('${runtime.displayName} sign-in opened in a terminal');
    } on Object catch (error) {
      _setStatus('Could not open sign-in · $error', warning: true);
    }
  }

  String? get runtimeRecoveryLabel => switch (_runtimeRecovery?.$2) {
    'update' => 'Update Claude Code',
    'setup' => 'Open OpenClaw setup',
    _ => null,
  };

  Future<void> openRuntimeRecovery() async {
    final recovery = _runtimeRecovery;
    if (recovery == null || runtimeBusy || sessionBusy) return;
    final target = _runtimeTarget(recovery.$1);
    if (target == null) return;
    try {
      if (recovery.$2 == 'update') {
        await desktop.openRuntimeUpdate(target);
      } else {
        await desktop.openRuntimeSignIn(target);
      }
      _setStatus(
        'Finish ${target.displayName} setup in the terminal, then retry the connection.',
        warning: true,
      );
    } on Object catch (error) {
      _setStatus(
        'Could not open ${target.displayName} setup · $error',
        warning: true,
      );
    }
  }

  Future<String?> chooseRuntimeExecutable({
    required String executionHostId,
  }) async {
    final host = runtimeOverrideHosts.cast<Map<String, Object?>?>().firstWhere(
      (value) => value?['id'] == executionHostId,
      orElse: () => null,
    );
    if (host == null) return null;
    final selected = await desktop.selectRuntimeExecutable();
    if (selected == null || selected.trim().isEmpty) return null;
    return normalizeRuntimeExecutablePath(selected, host);
  }

  Future<String?> saveRuntimeOverride({
    required String adapterId,
    required String locator,
    String? executionHostId,
  }) async {
    if (core is! RuntimeConfigurationBridge) return null;
    final configuration = core as RuntimeConfigurationBridge;
    if (runtimeOverrideBusy || locator.trim().isEmpty) return null;
    final adapter = runtimeOverrideAdapters
        .cast<Map<String, Object?>?>()
        .firstWhere(
          (value) => value?['adapterId'] == adapterId,
          orElse: () => null,
        );
    if (adapter == null) return null;
    final acceptsEndpoint = adapter['acceptsEndpoint'] == true;
    final host = acceptsEndpoint
        ? <String, Object?>{
            'id': 'remote:${Platform.operatingSystem}',
            'kind': 'remote',
            'platform': Platform.operatingSystem,
            'displayName': 'Remote Gateway',
            'isDefault': false,
          }
        : runtimeOverrideHosts.cast<Map<String, Object?>?>().firstWhere(
            (value) => value?['id'] == executionHostId,
            orElse: () => null,
          );
    if (host == null) {
      _setStatus('Choose an execution host for this override.', warning: true);
      return null;
    }
    runtimeOverrideBusy = true;
    _notify();
    try {
      final discovery = await configuration.addRuntimeOverride({
        'id': '',
        'adapterId': adapterId,
        'executionHost': host,
        if (acceptsEndpoint) 'endpoint': locator.trim(),
        if (!acceptsEndpoint) 'executablePath': locator.trim(),
      });
      _replaceDiscovery(discovery);
      final added = visibleRuntimeTargets
          .where((target) => target.id == discovery.selectedTargetId)
          .firstOrNull;
      if (added == null || added.adapterId != adapterId) {
        _setStatus(
          'Could not detect the configured runtime. Check the CLI path and try again.',
          warning: true,
        );
        return null;
      }
      _setStatus('${added.displayName} detected and added');
      return added.id;
    } on Object catch (error) {
      _setStatus('Could not add runtime override · $error', warning: true);
      return null;
    } finally {
      runtimeOverrideBusy = false;
      _notify();
    }
  }

  Future<void> removeRuntimeOverride(String overrideId) async {
    if (core is! RuntimeConfigurationBridge) return;
    final configuration = core as RuntimeConfigurationBridge;
    if (runtimeOverrideBusy) return;
    runtimeOverrideBusy = true;
    _notify();
    try {
      final discovery = await configuration.removeRuntimeOverride(overrideId);
      _replaceDiscovery(discovery);
      _setStatus('Runtime override removed');
    } on Object catch (error) {
      _setStatus('Could not remove runtime override · $error', warning: true);
    } finally {
      runtimeOverrideBusy = false;
      _notify();
    }
  }

  Future<void> _connectRuntime(
    String targetId, {
    String? coreVersion,
    int? selectionEpoch,
  }) async {
    _rememberActiveSessionSettings();
    final connection = await core.connectRuntime(runtimeTargetId: targetId);
    _connectedRuntimes.add(connection.runtimeTargetId);
    if (_closed || (selectionEpoch != null && selectionEpoch != _switchEpoch)) {
      return;
    }
    await _applySessionConnection(connection, focusComposer: false);
    if (selectionEpoch != null && connection.sessions.isNotEmpty) {
      _markCatalogSynced(connection.runtimeTargetId);
    }
    if (_closed || (selectionEpoch != null && selectionEpoch != _switchEpoch)) {
      return;
    }
    final version = connection.runtimeVersion ?? coreVersion;
    coreConnectionFailed = false;
    connectionErrorTargetId = null;
    _setStatus('$activeRuntimeName${version == null ? '' : ' $version'} ready');
  }

  Future<void> _readActiveHistory({
    Map<String, Object?>? history,
    int? historyRevision,
    bool retryOnFailure = false,
  }) async {
    final runtimeTargetId = activeRuntime?.id;
    final sessionId = activeSessionId;
    if (runtimeTargetId == null || sessionId == null) return;
    final sessionKey = _sessionKey(runtimeTargetId, sessionId);
    final revisionBeforeRead =
        historyRevision ?? _transcriptRevisions[sessionKey] ?? 0;
    final historyEpoch = _historyEpochs[sessionKey] ?? 0;
    if (!capabilities.contains('history.read.v1')) {
      _turnsBySession.putIfAbsent(sessionKey, () => []);
      return;
    }
    try {
      final inlineThread = mapValue(history?['thread']);
      final response =
          inlineThread['id'] == sessionId && inlineThread['turns'] is List
          ? history!
          : await core.readSession(
              runtimeTargetId: runtimeTargetId,
              sessionId: sessionId,
            );
      if ((_historyEpochs[sessionKey] ?? 0) != historyEpoch) return;
      final discarded = _discardedTurnIds[sessionKey] ?? const <String>{};
      final canonical = mapThreadHistory(response)
          .where(
            (turn) =>
                !discarded.contains(turn.id) &&
                !discarded.contains(turn.runtimeTurnId),
          )
          .toList();
      final cached = _turnsBySession[sessionKey] ?? const <ConversationTurn>[];
      final changedDuringRead =
          (_transcriptRevisions[sessionKey] ?? 0) != revisionBeforeRead;
      final pagination = mapValue(response['pagination']);
      final next = pagination['nextCursor'];
      if (next is String && next.isNotEmpty) {
        _historyNextCursor[sessionKey] = next;
      } else {
        _historyNextCursor.remove(sessionKey);
      }
      _historyPageErrors.remove(sessionKey);
      _turnsBySession[sessionKey] = response.containsKey('pagination')
          ? mergeRecentHistory(
              canonical,
              cached,
              preserveUpdates:
                  changedDuringRead || _activeTurns.containsKey(sessionKey),
            )
          : mergeSessionHistory(
              canonical,
              cached,
              preserveCached:
                  _activeTurns.containsKey(sessionKey) || changedDuringRead,
              preferCachedUpdates: changedDuringRead,
              reconcileLocalTurnIds:
                  !changedDuringRead &&
                  !_activeTurns.containsKey(sessionKey) &&
                  (_runtimeCapabilities[runtimeTargetId]?.contains(
                        'session.rewind.prepare.v1',
                      ) ??
                      false),
            );
      _transcriptChanged(sessionKey);
    } on Object catch (error) {
      if ((_historyEpochs[sessionKey] ?? 0) != historyEpoch) return;
      _turnsBySession.putIfAbsent(sessionKey, () => []);
      if (retryOnFailure) rethrow;
      _setStatus('History unavailable · $error', warning: true);
    }
    _notify();
  }

  Future<void> createSession({String? runtimeTargetId}) async {
    final targetId = runtimeTargetId ?? activeRuntime?.id;
    final target = targetId == null ? null : _runtimeTarget(targetId);
    if (target == null ||
        starting ||
        sessionBusy ||
        runtimeBusy ||
        sessionSettingsBusy ||
        submitting ||
        selectingContent ||
        !canCreateSession(target)) {
      return;
    }
    _cancelSwitchRecovery();
    final epoch = _switchEpoch;
    sessionBusy = true;
    final changingRuntime = activeRuntime?.id != target.id;
    switchingRuntimeId = target.id;
    _rememberActiveSessionSettings();
    final inherited = changingRuntime ? null : activeSessionSettings;
    _setStatus('Creating a chat in ${target.displayName}…');
    try {
      final connection = await core.createSession(
        runtimeTargetId: target.id,
        model: _nonEmpty(inherited?.model),
        effort: _nonEmpty(inherited?.effort),
        cwd: _nonEmpty(inherited?.workspace),
        profile: _nonEmpty(inherited?.profile),
      );
      if (_closed || epoch != _switchEpoch) return;
      _newSessions.add(
        _sessionKey(connection.runtimeTargetId, connection.sessionId),
      );
      await _applySessionConnection(connection, inherited: inherited);
      if (_closed || epoch != _switchEpoch) return;
      coreConnectionFailed = false;
      connectionErrorTargetId = null;
      _recordSessionActivity(connection.runtimeTargetId, connection.sessionId);
      _setStatus('New chat ready');
    } on Object catch (error) {
      if (_closed || epoch != _switchEpoch) return;
      _rememberConnectionFailure(target.id, create: true);
      if (!_applyConnectionError(target.id, error, activateTarget: false)) {
        _setStatus('Could not create chat · $error', warning: true);
      }
    } finally {
      if (epoch == _switchEpoch) {
        sessionBusy = false;
        switchingRuntimeId = null;
        _notify();
      }
    }
  }

  Future<void> switchSession(
    String sessionId, {
    String? runtimeTargetId,
  }) async {
    final targetId = runtimeTargetId ?? activeRuntime?.id;
    if (_closed ||
        targetId == null ||
        starting ||
        runtimeBusy ||
        sessionSettingsBusy ||
        submitting ||
        selectingContent) {
      return;
    }
    if (sessionBusy && _switchWorker == null) return;
    final recovering = _switchFailures > 0;
    _switchRetryTimer?.cancel();
    _switchFailures = 0;
    _switchEpoch++;
    if (_switchWorker == null &&
        !recovering &&
        _isActiveSession(targetId, sessionId) &&
        !sessionReadOnly) {
      _pendingSwitch = null;
      return;
    }
    _pendingSwitch = (targetId, sessionId);
    if (_switchWorker case final worker?) {
      if (_switchWorkerTargetId == targetId) return worker;
    }
    final worker = _drainSessionSwitches(++_switchWorkerGeneration);
    _switchWorker = worker;
    try {
      await worker;
    } finally {
      if (identical(_switchWorker, worker)) {
        _switchWorker = null;
        _switchWorkerTargetId = null;
      }
    }
  }

  Future<void> _drainSessionSwitches(int generation) async {
    while (!_closed &&
        generation == _switchWorkerGeneration &&
        _pendingSwitch != null) {
      final (targetId, sessionId) = _pendingSwitch!;
      _pendingSwitch = null;
      _switchWorkerTargetId = targetId;
      await _switchSessionOnce(sessionId, targetId, _switchEpoch);
    }
  }

  Future<void> _switchSessionOnce(
    String sessionId,
    String targetId,
    int epoch,
  ) async {
    if (starting ||
        runtimeBusy ||
        sessionSettingsBusy ||
        submitting ||
        selectingContent) {
      return;
    }
    sessionBusy = true;
    final changingRuntime = activeRuntime?.id != targetId;
    switchingRuntimeId = changingRuntime ? targetId : null;
    _rememberActiveSessionSettings();
    final targetSettings = _settingsForSession(targetId, sessionId);
    final historyRevision =
        _transcriptRevisions[_sessionKey(targetId, sessionId)] ?? 0;
    _notify();
    try {
      RuntimeConnection? initialConnection;
      if (!_connectedRuntimes.contains(targetId) ||
          _runtimeTarget(targetId)?.status == 'unavailable' ||
          _switchFailures > 0) {
        initialConnection = await core.connectRuntime(
          runtimeTargetId: targetId,
          preferredSessionId: sessionId,
          cwd: _nonEmpty(targetSettings.workspace),
        );
        _connectedRuntimes.add(initialConnection.runtimeTargetId);
      }
      if (_closed || epoch != _switchEpoch) return;
      // A cold connection already resumes the requested chat. A warm host can
      // instead return its previous selection; only reuse an exact match, and
      // keep explicit reopen semantics for recovery and profile changes.
      final reuseInitial =
          initialConnection != null &&
          initialConnection.runtimeTargetId == targetId &&
          initialConnection.sessionId == sessionId &&
          _switchFailures == 0 &&
          initialConnection.sessionMetadata['readOnly'] != true &&
          (targetSettings.profile.isEmpty ||
              initialConnection.sessionMetadata['profile'] ==
                  targetSettings.profile);
      final connection = reuseInitial
          ? initialConnection
          : await core.openSession(
              runtimeTargetId: targetId,
              sessionId: sessionId,
              cwd: _nonEmpty(targetSettings.workspace),
              profile: _nonEmpty(targetSettings.profile),
            );
      if (initialConnection != null) _cacheConnection(initialConnection);
      if (_closed || epoch != _switchEpoch) return;
      await _applySessionConnection(
        connection,
        historyRevision: historyRevision,
      );
      if (_closed || epoch != _switchEpoch) return;
      _switchFailures = 0;
      coreConnectionFailed = false;
      connectionErrorTargetId = null;
      _setStatus(
        sessionReadOnly
            ? 'Chat is open elsewhere · reconnecting automatically'
            : 'Chat switched',
      );
    } on Object catch (error) {
      if (_closed || epoch != _switchEpoch) return;
      if (_canRetrySwitch(error)) {
        _scheduleSwitchRecovery(targetId, sessionId, epoch);
      } else {
        final detail = error is CoreProtocolException
            ? error.message
            : error.toString();
        _setStatus('Could not open chat · $detail', warning: true);
        _rememberConnectionFailure(targetId, session: sessionId);
      }
    } finally {
      if (epoch == _switchEpoch) {
        sessionBusy = false;
        switchingRuntimeId = null;
        _notify();
      }
    }
  }

  static bool _canRetrySwitch(Object error) =>
      error is TimeoutException ||
      (error is CoreProtocolException &&
          const {
            'runtime-recovering',
            'runtime-exited',
            'runtime-unavailable',
            'runtime-overloaded',
            'unknown-outcome',
            'session-busy',
            'core-unavailable',
            'core-timeout',
            'core-exited',
            'core-transport-failed',
            'runtime-timeout',
            'wsl-startup-failed',
            'request-expired',
          }.contains(error.code));

  void _scheduleSwitchRecovery(String targetId, String sessionId, int epoch) {
    _switchRetryTimer?.cancel();
    _switchFailures++;
    if (_switchFailures > 3) {
      _rememberConnectionFailure(targetId, session: sessionId);
      _setStatus(
        'Could not reconnect to ${_runtimeTarget(targetId)?.displayName ?? 'agent'}. Your chat and draft are kept. Retry or choose another agent.',
        warning: true,
      );
      return;
    }
    _setStatus('Reconnecting to chat… Your draft is kept.');
    final delay = Duration(
      seconds: (1 << (_switchFailures - 1).clamp(0, 4)).clamp(1, 15),
    );
    _switchRetryTimer = Timer(delay, () {
      if (_closed || epoch != _switchEpoch || _switchWorker != null) return;
      _pendingSwitch = (targetId, sessionId);
      final worker = _drainSessionSwitches(++_switchWorkerGeneration);
      _switchWorker = worker;
      unawaited(
        worker.whenComplete(() {
          if (identical(_switchWorker, worker)) {
            _switchWorker = null;
            _switchWorkerTargetId = null;
          }
        }),
      );
    });
  }

  void _cancelSwitchRecovery() {
    _switchRetryTimer?.cancel();
    _pendingSwitch = null;
    _switchFailures = 0;
    _switchEpoch++;
  }

  static String? _nonEmpty(String? value) =>
      value == null || value.isEmpty ? null : value;

  void _cacheConnection(RuntimeConnection connection) {
    _connectedRuntimes.add(connection.runtimeTargetId);
    final key = _sessionKey(connection.runtimeTargetId, connection.sessionId);
    if (connection.sessionMetadata['readOnly'] == true) {
      _readOnlySessions.add(key);
      _pausedQueues.add(key);
    } else {
      _readOnlySessions.remove(key);
    }
    final target = _runtimeTarget(connection.runtimeTargetId);
    if (target != null) _knownRuntimes[target.id] = target;
    _runtimeCapabilities[connection.runtimeTargetId] = {
      ...?_runtimeCapabilities[connection.runtimeTargetId],
      ...?target?.capabilityHints,
      ...connection.capabilities,
    };
    for (final capability in [
      'session.rewind.v1',
      'session.rewind.prepare.v1',
      'model.select.v1',
      'reasoning.select.v1',
    ]) {
      if (!connection.capabilities.contains(capability)) {
        _runtimeCapabilities[connection.runtimeTargetId]!.remove(capability);
      }
    }
    // A connection describes this session/profile's inventory, including an
    // empty result. Retaining the prior profile's options can send its model
    // back to a provider that does not support it.
    _modelCatalogs[connection.runtimeTargetId] = List.of(connection.models);
    if (connection.models.isEmpty) {
      _runtimeCapabilities[connection.runtimeTargetId]!.removeAll({
        'model.select.v1',
        'reasoning.select.v1',
      });
    }
    _mergeSessions(connection.runtimeTargetId, connection.sessions);
    // Connections can carry cached summaries. Only an explicit catalog/list
    // response renews its TTL, so switching cannot starve catalog refreshes.
  }

  void _activateConnection(RuntimeConnection connection) {
    final changingRuntime = activeRuntime?.id != connection.runtimeTargetId;
    final previousKey = _activeSessionKey;
    final changingSession =
        previousKey !=
        _sessionKey(connection.runtimeTargetId, connection.sessionId);
    if (changingSession) _saveSessionDraft();
    if (changingSession) {
      commandOutput = null;
      goalPanelOpen = false;
      previewAttachment = null;
    }
    _cacheConnection(connection);
    activeRuntime = _runtimeTarget(connection.runtimeTargetId);
    activeSessionId =
        _dismissedSessions.contains((
          connection.runtimeTargetId,
          connection.sessionId,
        ))
        ? null
        : connection.sessionId;
    // Content captured before the first connection belongs to that first chat.
    if (changingSession && previousKey != null) _restoreSessionDraft();
    _catalogUsedAt[connection.runtimeTargetId] = _clock().toUtc();
    _scheduleCatalogSave();
    capabilities = _runtimeCapabilities[connection.runtimeTargetId] ?? {};
    models
      ..clear()
      ..addAll(_modelCatalogs[connection.runtimeTargetId] ?? const []);
    if (changingRuntime) {
      selectedModel = '';
      selectedEffort = '';
      selectedWorkspace = '';
      selectedProfile = '';
      profiles = [];
    }
    if (!sessionSettingsBusy) {
      question = null;
      previewArtifact = null;
      modelPanelOpen = false;
      workspacePanelOpen = false;
      sessionSettingsDetailOpen = false;
    }
    _unreadSessions.remove(_activeSessionKey);
    _ensureSession(connection.sessionId);
    _hydrateProfiles(connection);
  }

  Future<void> _applySessionConnection(
    RuntimeConnection connection, {
    SessionSettings? inherited,
    int? historyRevision,
    bool focusComposer = true,
  }) async {
    _activateConnection(connection);
    _hydrateSessionSettingsFromSummaries(connection.runtimeTargetId);
    final key = _sessionKey(connection.runtimeTargetId, connection.sessionId);
    if (inherited != null) _sessionSettings[key] = inherited;
    _restoreSessionSettings(connection);
    _rememberActiveSessionSettings();
    // Paint cached history while an adapter finishes reading the selected chat.
    _notify();
    await _readActiveHistory(
      history: connection.history,
      historyRevision: historyRevision,
      retryOnFailure: true,
    );
    if (!_isActiveSession(connection.runtimeTargetId, connection.sessionId)) {
      return;
    }
    // Each runtime processes requests in order. Optional command discovery must
    // not get ahead of the selected transcript or hold the composer busy.
    unawaited(refreshCommands());
    unawaited(_refreshGoal());
    if (focusComposer) focusComposerEpoch++;
  }

  Future<void> submit(
    String message, {
    String? inlineMessage,
    List<String>? attachmentOrder,
  }) async {
    final text = message.trim();
    if (sessionReadOnly && !isReadOnlyCodexCommand(text)) {
      _setStatus(
        'Chat is open elsewhere · your draft is kept until it reconnects',
      );
      return;
    }
    final runtimeTargetId = activeRuntime?.id;
    final sessionId = activeSessionId;
    if (text.isEmpty || selectingContent || sessionBusy || runtimeBusy) {
      return;
    }
    if (runtimeTargetId == null || sessionId == null) {
      _setStatus(
        'No agent session is ready. Choose or refresh an agent.',
        warning: true,
      );
      return;
    }
    final sessionKey = _sessionKey(runtimeTargetId, sessionId);
    final command = commandFor(text);
    if (isCodexCommand(text) && (command == null || command.native)) {
      if (!submitting) await _submitCodexCommand(text);
      return;
    }
    final runtimeCommand = isRuntimeCommand(text);
    if (runtimeCommand) {
      if (command == null) {
        _commandError(
          _commandErrors[sessionKey] ??
              'This command is not advertised by $activeRuntimeName. Refresh commands or choose one from the menu.',
        );
        return;
      }
      if (!command.enabled ||
          turnActive ||
          submitting ||
          attachments.isNotEmpty ||
          core is! RuntimeCommandBridge) {
        _commandError(
          command.disabledReason ??
              (attachments.isNotEmpty
                  ? 'Send or remove attachments before running a command.'
                  : 'Wait for this chat to be ready before running a command.'),
        );
        return;
      }
      commandComposerEpoch++;
    }
    _newSessions.remove(sessionKey);
    final draftValue = composerValue;
    final draftAttachmentSequence = _attachmentSequence;
    composerValue = TextEditingValue.empty;
    final sendingAttachments = _orderedAttachments(attachmentOrder);
    attachments.clear();
    _attachmentSequence = 0;
    previewAttachment = null;
    final operationId =
        'flutter:${DateTime.now().microsecondsSinceEpoch}:${++_localTurnSequence}';
    final pendingMessage = QueuedMessage(
      id: operationId,
      isCommand: runtimeCommand,
      runtimeTargetId: runtimeTargetId,
      runtimeName: activeRuntimeName,
      sessionId: sessionId,
      text: text,
      inlineText: inlineMessage ?? text,
      attachments: sendingAttachments,
      settings: activeSessionSettings,
      draftValue: draftValue,
      attachmentSequence: draftAttachmentSequence,
      createdAt: _clock(),
    );
    await _enqueueMessage(pendingMessage);
  }

  bool get messageEditingSupported =>
      core is SessionRewindBridge && capabilities.contains('session.rewind.v1');

  /// Replace the edited turn and all following history before starting its
  /// replacement. The unrelated composer draft and attachments stay untouched.
  Future<bool> resendMessage(ConversationTurn original, String message) async {
    final text = message.trim();
    final runtime = activeRuntime;
    final sessionId = activeSessionId;
    if (text.isEmpty ||
        runtime == null ||
        sessionId == null ||
        sessionReadOnly ||
        sessionBusy ||
        runtimeBusy ||
        selectingContent ||
        !messageEditingSupported ||
        original.runtimeTurnId == null ||
        !turns.contains(original)) {
      return false;
    }
    final inlineText = original.attachments.isEmpty
        ? text
        : '$text\n${List.filled(original.attachments.length, '\u{fffc}').join(' ')}';
    var pendingMessage = QueuedMessage(
      id: 'flutter:${DateTime.now().microsecondsSinceEpoch}:${++_localTurnSequence}',
      runtimeTargetId: runtime.id,
      runtimeName: activeRuntimeName,
      sessionId: sessionId,
      text: text,
      inlineText: inlineText,
      attachments: original.attachments,
      settings: activeSessionSettings,
      draftValue: TextEditingValue(text: inlineText),
      attachmentSequence: original.attachments.fold(0, (sequence, attachment) {
        final index = attachment.reference.codeUnits.fold(
          0,
          (value, char) => value * 26 + char - 64,
        );
        return index > sequence ? index : sequence;
      }),
      createdAt: _clock(),
    );
    final sessionKey = _sessionKey(runtime.id, sessionId);
    final wasPaused = _pausedQueues.contains(sessionKey);
    final wasRunning =
        _activeTurns.containsKey(sessionKey) ||
        _startingSessions.contains(sessionKey);
    var rewound = false;
    sessionBusy = true;
    _pausedQueues.add(sessionKey);
    _notify();
    try {
      if (wasRunning) {
        await interrupt();
        if (_activeTurns.containsKey(sessionKey) &&
            !_interruptingSessions.contains(sessionKey)) {
          throw StateError('The current response could not be stopped.');
        }
        await _waitForIdleSession(sessionKey);
      }
      if (_closed || !_isActiveSession(runtime.id, sessionId)) return false;
      final current = List<ConversationTurn>.of(_turnsBySession[sessionKey]!);
      final index = current.indexWhere(
        (turn) => turn.runtimeTurnId == original.runtimeTurnId,
      );
      if (index < 0) {
        throw StateError('The chat changed. Reopen it before resending.');
      }
      var prepared = current;
      var offset = 0;
      if (capabilities.contains('session.rewind.prepare.v1') ||
          _historyNextCursor.containsKey(sessionKey)) {
        // Editing a paged transcript still verifies the complete native prefix
        // before the runtime truncates its history.
        final snapshot = capabilities.contains('session.rewind.prepare.v1')
            ? await (core as SessionRewindBridge).prepareSessionRewind(
                runtimeTargetId: runtime.id,
                sessionId: sessionId,
              )
            : await core.readSession(
                runtimeTargetId: runtime.id,
                sessionId: sessionId,
              );
        if (mapValue(snapshot['thread'])['id'] != sessionId) {
          throw StateError('Rewind preparation returned a different chat.');
        }
        prepared = mapThreadHistory(snapshot);
        offset = prepared.length - current.length;
        if (offset < 0 ||
            (offset > 0 &&
                current.every((turn) => turn.id.startsWith('flutter:')))) {
          throw StateError('The chat changed. Reopen it before resending.');
        }
        for (var i = 0; i < current.length; i++) {
          final fresh = prepared[offset + i];
          final shown = current[i];
          // Live receipts can identify a run rather than a persisted user
          // entry. Reconcile only local turns, once by position, after matching
          // the complete visible message sequence (including repeated text).
          if (fresh.userText != shown.userText ||
              (fresh.runtimeTurnId != shown.runtimeTurnId &&
                  !shown.id.startsWith('flutter:'))) {
            throw StateError('The chat changed. Reopen it before resending.');
          }
        }
      }
      final targetIndex = index + offset;
      final nativeId = prepared[targetIndex].runtimeTurnId;
      final lastTurnId = prepared.last.runtimeTurnId;
      if (nativeId == null || lastTurnId == null) {
        throw StateError(
          'The runtime did not expose exact message identities.',
        );
      }
      _setStatus('Returning to the edited message…');
      final history = await (core as SessionRewindBridge).rewindSession(
        runtimeTargetId: runtime.id,
        sessionId: sessionId,
        turnId: nativeId,
        expectedLastTurnId: lastTurnId,
      );
      final thread = mapValue(history['thread']);
      final nextSessionId = thread['id']?.toString();
      final retained = mapThreadHistory(history);
      if (nextSessionId == null ||
          thread['turns'] is! List ||
          retained.length != targetIndex) {
        throw StateError('The runtime returned unexpected rewound history.');
      }
      for (var i = 0; i < retained.length; i++) {
        if (retained[i].runtimeTurnId != prepared[i].runtimeTurnId) {
          throw StateError(
            'The runtime did not preserve the earlier conversation.',
          );
        }
      }
      final nextKey = _sessionKey(runtime.id, nextSessionId);
      if (nextSessionId != sessionId) {
        final connection = RuntimeConnection.fromJson(
          mapValue(history['connection']),
        );
        if (history['sourceSessionId'] != sessionId ||
            connection.runtimeTargetId != runtime.id ||
            connection.sessionId != nextSessionId) {
          throw StateError('The runtime returned a different edit branch.');
        }
        _saveSessionDraft();
        _drafts[nextKey] = _drafts[sessionKey]!;
        _sessionSettings[nextKey] = pendingMessage.settings;
        _activateConnection(connection);
        _restoreSessionSettings(connection);
        unawaited(refreshCommands());
        pendingMessage = pendingMessage.forSession(nextSessionId);
      }
      rewound = true;
      if (nextKey != sessionKey) {
        _historyEpochs[sessionKey] = (_historyEpochs[sessionKey] ?? 0) + 1;
      }
      _historyEpochs[nextKey] = (_historyEpochs[nextKey] ?? 0) + 1;
      _historyNextCursor.remove(nextKey);
      _historyPageErrors.remove(nextKey);
      final discarded = _discardedTurnIds.putIfAbsent(nextKey, () => {});
      for (final turn in [
        ...current.skip(index),
        ...prepared.skip(targetIndex),
      ]) {
        discarded.add(turn.id);
        if (turn.runtimeTurnId case final id?) discarded.add(id);
      }
      _turnsBySession[nextKey] = [
        for (var i = 0; i < retained.length; i++)
          if (i < offset)
            retained[i]
          else
            mergeConversationTurn(
              retained[i],
              current[i - offset],
              userPresentation: current[i - offset],
            ),
      ];
      // Follow-ups written for the removed history must not run in the rewrite.
      _messageQueues.remove(sessionKey);
      _newSessions.remove(sessionKey);
      _pausedQueues.remove(sessionKey);
      question = null;
      previewArtifact = null;
      _transcriptChanged(nextKey);
      await _enqueueMessage(pendingMessage);
      return true;
    } on Object catch (error) {
      _setStatus('Could not resend from this message · $error', warning: true);
      return false;
    } finally {
      if (!rewound && !wasPaused && !wasRunning) {
        _pausedQueues.remove(sessionKey);
      }
      sessionBusy = false;
      _notify();
    }
  }

  Future<void> _waitForIdleSession(String sessionKey) async {
    final complete = Completer<void>();
    void check() {
      if (_closed ||
          (!_activeTurns.containsKey(sessionKey) &&
              !_startingSessions.contains(sessionKey))) {
        if (!complete.isCompleted) complete.complete();
      }
    }

    addListener(check);
    check();
    try {
      await complete.future.timeout(const Duration(seconds: 30));
    } finally {
      removeListener(check);
    }
  }

  Future<void> _enqueueMessage(QueuedMessage pendingMessage) async {
    final sessionKey = _sessionKey(
      pendingMessage.runtimeTargetId,
      pendingMessage.sessionId,
    );
    final text = pendingMessage.text;
    final sessionId = pendingMessage.sessionId;
    final history = _inputHistory.putIfAbsent(sessionKey, () => []);
    history.remove(text);
    history.add(text);
    if (history.length > composerHistoryLimit) history.removeAt(0);
    _updateSessionTitle(sessionId, text);
    if (_activeTurns.containsKey(sessionKey) ||
        _startingSessions.contains(sessionKey) ||
        (_messageQueues[sessionKey]?.isNotEmpty ?? false)) {
      _messageQueues.putIfAbsent(sessionKey, () => []).add(pendingMessage);
      _setStatus(
        queuePaused ? 'Message queued · queue paused' : 'Message queued',
      );
      _drainMessageQueue(sessionKey);
      return;
    }
    _pausedQueues.remove(sessionKey);
    await _startMessage(pendingMessage);
  }

  Future<void> _startMessage(QueuedMessage message) async {
    final runtimeTargetId = message.runtimeTargetId;
    final sessionId = message.sessionId;
    final sessionKey = _sessionKey(runtimeTargetId, sessionId);
    final operationId = message.id;
    final sendingAttachments = message.attachments;
    final settings = message.settings;
    final localTurn = ConversationTurn(
      id: operationId,
      number: (_turnsBySession[sessionKey]?.length ?? 0) + 1,
      userText: message.text,
      inlineUserText: message.inlineText,
      createdAt: message.createdAt ?? _clock(),
      contextTokens: sendingAttachments
          .where((item) => !item.hasImage)
          .map((item) => item.token)
          .toList(),
      attachments: sendingAttachments,
    );
    _turnsBySession.putIfAbsent(sessionKey, () => []).add(localTurn);
    _transcriptChanged(sessionKey);
    _activeTurns[sessionKey] = operationId;
    _startingSessions.add(sessionKey);
    if (_isActiveSession(runtimeTargetId, sessionId)) {
      _setStatus('Starting ${message.runtimeName} turn…');
    } else {
      _notify();
    }
    try {
      final receipt = message.isCommand
          ? await (core as RuntimeCommandBridge).startCommand(
              runtimeTargetId: runtimeTargetId,
              sessionId: sessionId,
              message: message.text,
              clientOperationId: operationId,
              model: settings.model.isEmpty ? null : settings.model,
              effort: settings.effort.isEmpty ? null : settings.effort,
              cwd: settings.workspace.isEmpty ? null : settings.workspace,
              profile: settings.profile.isEmpty ? null : settings.profile,
            )
          : await core.startTurn(
              runtimeTargetId: runtimeTargetId,
              sessionId: sessionId,
              message: message.text,
              snapshots: contextHandoffSnapshots(sendingAttachments),
              images: sendingAttachments
                  .map((item) => item.imageDataUrl)
                  .whereType<String>()
                  .toList(growable: false),
              clientOperationId: operationId,
              model: settings.model.isEmpty ? null : settings.model,
              effort: settings.effort.isEmpty ? null : settings.effort,
              cwd: settings.workspace.isEmpty ? null : settings.workspace,
              profile: settings.profile.isEmpty ? null : settings.profile,
            );
      if (!receipt.accepted) {
        throw StateError('Agent did not accept the message');
      }
      localTurn.runtimeTurnId = receipt.turnId;
      final completedIdentity = _turnIdentity(
        receipt.runtimeTargetId,
        receipt.turnId,
      );
      if (!_completedTurnIds.containsKey(completedIdentity)) {
        _activeTurns[sessionKey] = receipt.turnId;
        if (_isActiveSession(runtimeTargetId, sessionId)) {
          _setStatus('$activeRuntimeName is responding…');
        }
        if (_cancelRequestedSessions.remove(sessionKey)) {
          await _interruptExact(
            runtimeTargetId: runtimeTargetId,
            sessionId: sessionId,
            turnId: receipt.turnId,
          );
        }
      } else {
        if (_activeTurns[sessionKey] == operationId ||
            _activeTurns[sessionKey] == receipt.turnId) {
          _activeTurns.remove(sessionKey);
        }
        if (_completedTurnIds[completedIdentity] != 'completed') {
          _pausedQueues.add(sessionKey);
        }
        _cancelRequestedSessions.remove(sessionKey);
        _interruptingSessions.remove(sessionKey);
      }
    } on Object catch (error) {
      _pausedQueues.add(sessionKey);
      _activeTurns.remove(sessionKey);
      _cancelRequestedSessions.remove(sessionKey);
      _interruptingSessions.remove(sessionKey);
      if (error is CoreProtocolException &&
          (const {'runtime-recovering', 'session-busy'}.contains(error.code) ||
              (message.isCommand && error.code == 'command-unavailable'))) {
        // These errors happen before submission. Preserve the editable draft;
        // uncertain outcomes remain in the transcript and are never replayed.
        _turnsBySession[sessionKey]?.remove(localTurn);
        if (_isActiveSession(runtimeTargetId, sessionId) &&
            composerValue.text.isEmpty &&
            attachments.isEmpty) {
          composerValue = message.draftValue.text.isEmpty
              ? TextEditingValue(text: message.inlineText)
              : message.draftValue;
          attachments.addAll(sendingAttachments);
          _attachmentSequence = message.attachmentSequence;
          commandComposerEpoch++;
        } else {
          // A queued start may fail after the user switches chats or begins
          // another draft. Keep it in its original queue without overwriting.
          _messageQueues.putIfAbsent(sessionKey, () => []).insert(0, message);
        }
        // A busy turn does not imply a foreign writer lease. Only connection
        // metadata owns read-only state, so a local busy race cannot lock Send.
        if (_isActiveSession(runtimeTargetId, sessionId)) {
          _setStatus('Chat is reconnecting · your message is kept');
        }
        _transcriptChanged(sessionKey);
        return;
      }
      localTurn.blocks.add(
        TranscriptBlock(
          id: '$operationId:error',
          kind: TranscriptKind.error,
          title: 'Error',
          text: error.toString(),
          lifecycle: TranscriptLifecycle.completed,
          expanded: true,
        ),
      );
      if (_isActiveSession(runtimeTargetId, sessionId)) {
        _setStatus('Core request failed · $error', warning: true);
      }
      _transcriptChanged(sessionKey);
    } finally {
      _startingSessions.remove(sessionKey);
      _notify();
      _drainMessageQueue(sessionKey);
    }
  }

  List<ContextAttachment> _orderedAttachments(List<String>? order) {
    if (order == null || order.isEmpty) {
      return List<ContextAttachment>.of(attachments);
    }
    final byId = {
      for (final attachment in attachments) attachment.id: attachment,
    };
    final result = <ContextAttachment>[];
    for (final id in order) {
      final attachment = byId.remove(id);
      if (attachment != null) result.add(attachment);
    }
    result.addAll(
      attachments.where((attachment) => byId.containsKey(attachment.id)),
    );
    return result;
  }

  Future<void> interrupt() async {
    final target = activeRuntime?.id;
    final session = activeSessionId;
    final turn = activeTurnId;
    if (target == null || session == null || turn == null) return;
    final sessionKey = _sessionKey(target, session);
    if (_interruptingSessions.contains(sessionKey)) return;
    _pausedQueues.add(sessionKey);
    _setStatus('Stopping $activeRuntimeName turn…');
    if (turn.startsWith('flutter:')) {
      _cancelRequestedSessions.add(sessionKey);
      _interruptingSessions.add(sessionKey);
      _notify();
      return;
    }
    await _interruptExact(
      runtimeTargetId: target,
      sessionId: session,
      turnId: turn,
    );
  }

  Future<void> _interruptExact({
    required String runtimeTargetId,
    required String sessionId,
    required String turnId,
  }) async {
    final sessionKey = _sessionKey(runtimeTargetId, sessionId);
    _interruptingSessions.add(sessionKey);
    _notify();
    try {
      await core.interruptTurn(
        runtimeTargetId: runtimeTargetId,
        sessionId: sessionId,
        turnId: turnId,
      );
      if (_isActiveSession(runtimeTargetId, sessionId)) {
        _setStatus('Stop sent to $activeRuntimeName…');
      }
    } on Object catch (error) {
      _interruptingSessions.remove(sessionKey);
      _cancelRequestedSessions.remove(sessionKey);
      _setStatus('Stop failed · $error', warning: true);
      _notify();
    }
  }

  Future<void> addImageContext() async {
    if (!imageInputSupported || selectingContent) return;
    selectingContent = true;
    _notify();
    try {
      final prepare = prepareImageCapture;
      if (prepare != null && !await prepare()) return;
      final attachment = await desktop.selectImageContext();
      if (attachment != null) {
        addAttachment(attachment);
        _setStatus('Image context attached');
      }
    } on Object catch (error) {
      _setStatus('Image selection failed · $error', warning: true);
    } finally {
      selectingContent = false;
      _notify();
    }
  }

  Future<void> addPointerContext({String? replacingId}) async {
    if (selectingContent) return;
    selectingContent = true;
    previewAttachment = null;
    _notify();
    try {
      final prepare = prepareImageCapture;
      if (prepare != null && !await prepare()) return;
      final selected = await desktop.selectPointerContext();
      final prepared = <ContextAttachment>[];
      for (var attachment in selected) {
        if (attachment.hasImage && !imageInputSupported) {
          if (mapValue(attachment.snapshot?['region'])['status'] ==
              'image-only') {
            _setStatus(
              'This selection needs an agent that accepts images.',
              warning: true,
            );
            return;
          }
          attachment = ContextAttachment(
            id: attachment.id,
            token: attachment.token,
            snapshot: attachment.snapshot,
            previewText: attachment.previewText,
            bounds: attachment.bounds,
          );
        }
        prepared.add(attachment);
      }
      if (prepared.isNotEmpty) {
        if (replacingId != null) {
          final index = attachments.indexWhere(
            (item) => item.id == replacingId,
          );
          if (index < 0) return;
          final previous = attachments[index];
          final attachment = prepared.removeAt(0);
          attachments[index] = ContextAttachment(
            id: previous.id,
            token: previous.token,
            snapshot: attachment.snapshot,
            previewText: attachment.previewText,
            imageDataUrl: attachment.imageDataUrl,
            bounds: attachment.bounds,
          );
        }
        for (final attachment in prepared) {
          attachments.add(attachment.withToken(_attachmentToken()));
        }
        _setStatus(
          selected.length > 1
              ? '${selected.length} selections attached'
              : replacingId == null
              ? 'Content attached'
              : 'Selection updated',
        );
      }
    } on Object catch (error) {
      _setStatus('Selection failed · $error', warning: true);
    } finally {
      selectingContent = false;
      focusComposerEpoch++;
      _notify();
      await desktop.showPanel();
    }
  }

  void addAttachment(ContextAttachment attachment) {
    attachments.add(attachment.withToken(_attachmentToken()));
    previewAttachment = null;
    focusComposerEpoch++;
    _notify();
  }

  void removeAttachment(String id) {
    attachments.removeWhere((attachment) => attachment.id == id);
    if (attachments.isEmpty) _attachmentSequence = 0;
    if (previewAttachment?.id == id) previewAttachment = null;
    _notify();
  }

  String _attachmentToken() {
    var index = ++_attachmentSequence;
    var label = '';
    while (index > 0) {
      index--;
      label = String.fromCharCode(65 + index % 26) + label;
      index ~/= 26;
    }
    return '[$label]';
  }

  void showAttachmentPreview(ContextAttachment attachment) {
    previewAttachment = attachment;
    _notify();
  }

  void hideAttachmentPreview() {
    if (previewAttachment == null) return;
    previewAttachment = null;
    _notify();
  }

  Future<void> showArtifact(ArtifactPreview artifact) async {
    previewArtifact = artifact;
    _notify();
    try {
      final loaded = await artifactLoader.load(artifact, target: activeRuntime);
      if (_closed || !identical(previewArtifact, artifact)) return;
      previewArtifact = loaded;
    } on Object catch (error) {
      if (_closed || !identical(previewArtifact, artifact)) return;
      previewArtifact = ArtifactPreview(
        id: artifact.id,
        kind: 'error',
        title: artifact.title,
        path: artifact.path,
        html: 'Preview unavailable · $error',
      );
    }
    _notify();
  }

  void closeArtifact() {
    previewArtifact = null;
    _notify();
  }

  Future<void> resolveApproval(String? optionId) async {
    final request = approval;
    if (request == null || resolvingPrompt) return;
    resolvingPrompt = true;
    _notify();
    try {
      await core.resolveApproval(
        runtimeTargetId: request.runtimeTargetId,
        sessionId: request.sessionId,
        approvalId: request.id,
        optionId: optionId,
      );
      _approvals.remove(request);
      _setStatus(
        optionId == null ? 'Permission denied' : 'Permission response sent',
      );
    } on Object catch (error) {
      if (error is CoreProtocolException &&
          const [
            'approval-expired',
            'invalid-request',
            'runtime-exited',
            'runtime-unavailable',
          ].contains(error.code)) {
        _approvals.remove(request);
      }
      _setStatus('Could not answer permission · $error', warning: true);
    } finally {
      resolvingPrompt = false;
      _notify();
    }
  }

  Future<void> resolveQuestion(Map<String, Object?> answer) async {
    final request = question;
    if (request == null || resolvingPrompt) return;
    resolvingPrompt = true;
    _notify();
    try {
      await core.resolveQuestion(
        runtimeTargetId: request.runtimeTargetId,
        sessionId: request.sessionId,
        questionId: request.id,
        answer: answer,
      );
      question = null;
      _setStatus(answer.isEmpty ? 'Question cancelled' : 'Answer sent');
    } on Object catch (error) {
      _setStatus('Could not answer question · $error', warning: true);
    } finally {
      resolvingPrompt = false;
      _notify();
    }
  }

  void setModel(String value) {
    if (sessionBusy || runtimeBusy) return;
    selectedModel = value;
    final efforts = effortsForModel(_selectedModel());
    if (efforts.isNotEmpty && !efforts.contains(selectedEffort)) {
      selectedEffort =
          _selectedModel()?['defaultReasoningEffort']?.toString() ??
          efforts.first;
    }
    _rememberActiveSessionSettings();
    _notify();
  }

  void setEffort(String value) {
    if (sessionBusy || runtimeBusy) return;
    selectedEffort = value;
    _rememberActiveSessionSettings();
    _notify();
  }

  Future<String?> chooseWorkspace() async {
    final selected = await desktop.selectWorkspaceDirectory();
    final runtime = activeRuntime;
    if (selected == null || selected.trim().isEmpty || runtime == null) {
      return null;
    }
    final normalized = normalizeWorkspacePath(selected, runtime.executionHost);
    if (normalized.isEmpty) return null;
    clearWorkspaceError();
    return normalized;
  }

  Future<bool> setWorkspace(String value) async {
    final runtime = activeRuntime;
    final sessionId = activeSessionId;
    if (runtime == null ||
        sessionId == null ||
        sessionSettingsBusy ||
        sessionBusy ||
        runtimeBusy) {
      return false;
    }
    final normalized = normalizeWorkspacePath(value, runtime.executionHost);
    if (normalized.isEmpty) {
      workspaceError = 'Choose an existing folder.';
      _setStatus('Workspace folder is required', warning: true);
      _notify();
      return false;
    }
    if (normalized == selectedWorkspace) {
      workspaceError = null;
      _notify();
      return true;
    }
    final previous = activeSessionSettings;
    final proposed = previous.copyWith(workspace: normalized);
    workspaceError = null;
    sessionSettingsBusy = true;
    _notify();
    try {
      final connection = await core.configureSession(
        runtimeTargetId: runtime.id,
        sessionId: sessionId,
        cwd: normalized,
        profile: selectedProfile.isEmpty ? null : selectedProfile,
        model: selectedModel.isEmpty ? null : selectedModel,
        effort: selectedEffort.isEmpty ? null : selectedEffort,
      );
      await _applySessionConnection(connection, inherited: proposed);
      workspaceError = null;
      _setStatus('Workspace updated');
      return true;
    } on Object catch (error) {
      _applySettings(previous);
      workspaceError = switch (error) {
        CoreProtocolException(code: 'workspace-not-found') =>
          'Folder does not exist on ${runtime.executionHost['displayName'] ?? runtime.executionHost['name'] ?? 'this runtime'}.',
        CoreProtocolException(code: 'invalid-workspace') =>
          'Enter an absolute folder path.',
        CoreProtocolException(:final message) => message,
        _ => 'Could not use this folder.',
      };
      _setStatus('Could not change workspace · $error', warning: true);
      return false;
    } finally {
      sessionSettingsBusy = false;
      _notify();
    }
  }

  void clearWorkspaceError() {
    if (workspaceError == null) return;
    workspaceError = null;
    _notify();
  }

  Future<void> setProfile(String value) async {
    final runtime = activeRuntime;
    final sessionId = activeSessionId;
    final profile = value.trim();
    if (runtime == null ||
        sessionId == null ||
        sessionSettingsBusy ||
        sessionBusy ||
        runtimeBusy ||
        profile.isEmpty ||
        profile == selectedProfile) {
      return;
    }
    final previous = activeSessionSettings;
    final selected = previous.copyWith(profile: profile, model: '', effort: '');
    sessionSettingsBusy = true;
    _notify();
    try {
      final connection = await core.configureSession(
        runtimeTargetId: runtime.id,
        sessionId: sessionId,
        cwd: selected.workspace.isEmpty ? null : selected.workspace,
        profile: profile,
        model: selected.model.isEmpty ? null : selected.model,
        effort: selected.effort.isEmpty ? null : selected.effort,
      );
      await _applySessionConnection(connection, inherited: selected);
      _setStatus(
        connection.sessionId == sessionId
            ? 'Profile updated'
            : '$profile profile · new chat ready',
      );
    } on Object catch (error) {
      _applySettings(previous);
      _setStatus('Could not change Hermes profile · $error', warning: true);
    } finally {
      sessionSettingsBusy = false;
      _notify();
    }
  }

  List<String> get selectedModelEfforts => effortsForModel(_selectedModel());

  void toggleSessionPanel([bool? open]) {
    sessionPanelOpen = open ?? !sessionPanelOpen;
    if (sessionPanelOpen) {
      modelPanelOpen = false;
      workspacePanelOpen = false;
      sessionSettingsDetailOpen = false;
      appSettingsPanelOpen = false;
    }
    _notify();
    if (sessionPanelOpen) unawaited(refreshSessionCatalog());
  }

  void toggleRuntimeSetupPanel([bool? open]) {
    runtimeSetupPanelOpen = open ?? !runtimeSetupPanelOpen;
    if (runtimeSetupPanelOpen) {
      modelPanelOpen = false;
      workspacePanelOpen = false;
      sessionSettingsDetailOpen = false;
      appSettingsPanelOpen = false;
    }
    _notify();
  }

  void toggleModelPanel() {
    if (modelPanelOpen) {
      if (sessionSettingsDetailOpen) {
        sessionSettingsDetailOpen = false;
        sessionSettingsOverviewEpoch++;
      } else {
        modelPanelOpen = false;
      }
    } else {
      modelPanelOpen = true;
      workspacePanelOpen = false;
      sessionSettingsDetailOpen = false;
      runtimeSetupPanelOpen = false;
      appSettingsPanelOpen = false;
    }
    _notify();
  }

  void toggleWorkspacePanel() {
    workspacePanelOpen = !workspacePanelOpen;
    if (workspacePanelOpen) {
      runtimeSetupPanelOpen = false;
      modelPanelOpen = false;
      sessionSettingsDetailOpen = false;
      appSettingsPanelOpen = false;
    }
    _notify();
  }

  void dismissWorkspacePanel() {
    if (!workspacePanelOpen) return;
    workspacePanelOpen = false;
    _notify();
  }

  void closeTransientPanels() {
    sessionPanelOpen = false;
    runtimeSetupPanelOpen = false;
    modelPanelOpen = false;
    workspacePanelOpen = false;
    sessionSettingsDetailOpen = false;
    appSettingsPanelOpen = false;
    _notify();
  }

  void toggleAppSettingsPanel() {
    appSettingsPanelOpen = !appSettingsPanelOpen;
    if (appSettingsPanelOpen) {
      runtimeSetupPanelOpen = false;
      modelPanelOpen = false;
      workspacePanelOpen = false;
      sessionSettingsDetailOpen = false;
    }
    _notify();
  }

  void dismissAppSettingsPanel() {
    if (!appSettingsPanelOpen) return;
    appSettingsPanelOpen = false;
    _notify();
  }

  void setSessionSettingsDetailOpen(bool value) {
    if (sessionSettingsDetailOpen == value) return;
    sessionSettingsDetailOpen = value;
    _notify();
  }

  void dismissSessionPanel() {
    if (!sessionPanelOpen) return;
    sessionPanelOpen = false;
    _notify();
  }

  void dismissModelPanel() {
    if (!modelPanelOpen) return;
    modelPanelOpen = false;
    sessionSettingsDetailOpen = false;
    _notify();
  }

  void dismissRuntimeSetupPanel() {
    if (!runtimeSetupPanelOpen) return;
    runtimeSetupPanelOpen = false;
    _notify();
  }

  Future<void> setExpanded(bool value, {bool focus = false}) async {
    if (!surfaceTransitioning && expanded == value) {
      if (value && focus) {
        focusComposerEpoch++;
        _notify();
        await desktop.showPanel();
      }
      return;
    }
    await _transitionSurface(
      targetExpanded: value,
      targetLarge: largePanel,
      targetMaximized: maximizedPanel,
      focus: focus,
      errorLabel: 'Window presentation degraded',
    );
  }

  Future<void> toggleLargePanel() => setWindowSize(
    largePanel ? WindowSizeSetting.standard : WindowSizeSetting.wide,
  );

  Future<void> toggleMaximized() async {
    if (surfaceTransitioning) return;
    surfaceTransitioning = true;
    _notify();
    try {
      _applyWindowMaximized(await desktop.toggleMaximized());
    } on Object catch (error) {
      _setStatus('Window resize failed · $error', warning: true);
    } finally {
      surfaceTransitioning = false;
      _notify();
    }
  }

  void _applyWindowMaximized(bool maximized) {
    if (maximized == maximizedPanel) return;
    if (maximized) {
      _restoredWindowSize = windowSize;
      windowSize = WindowSizeSetting.maximized;
    } else {
      windowSize = _restoredWindowSize;
    }
    _notify();
  }

  Future<void> setWindowSize(WindowSizeSetting setting) => _transitionSurface(
    targetExpanded: true,
    targetLarge: setting == WindowSizeSetting.wide,
    targetMaximized: setting == WindowSizeSetting.maximized,
    errorLabel: 'Window resize failed',
  );

  Future<void> _transitionSurface({
    required bool targetExpanded,
    required bool targetLarge,
    bool targetMaximized = false,
    required String errorLabel,
    bool focus = false,
  }) async {
    final transitionEpoch = ++_surfaceTransitionEpoch;
    surfaceTransitioning = true;
    surfaceTransitionAnimating = true;
    transitionTargetExpanded = targetExpanded;
    transitionTargetLarge = targetLarge;
    _notify();
    var applied = false;
    try {
      await desktop.setSurface(
        expanded: targetExpanded,
        large: targetLarge,
        maximized: targetExpanded && targetMaximized,
        animate: true,
      );
      applied = true;
    } on Object catch (error) {
      _setStatus('$errorLabel · $error', warning: true);
    } finally {
      if (transitionEpoch == _surfaceTransitionEpoch) {
        if (applied) {
          expanded = targetExpanded;
          windowSize = targetMaximized
              ? WindowSizeSetting.maximized
              : targetLarge
              ? WindowSizeSetting.wide
              : WindowSizeSetting.standard;
        }
        surfaceTransitioning = false;
        surfaceTransitionAnimating = false;
        if (targetExpanded && focus) focusComposerEpoch++;
        _notify();
      }
    }
    if (transitionEpoch == _surfaceTransitionEpoch && targetExpanded && focus) {
      await desktop.showPanel();
    }
  }

  Future<void> hideWindow() => desktop.hide();

  Future<void> closeWindow() => desktop.closeWindow();

  Future<void> startDragging() => desktop.startDragging();

  Future<void> copyText(String value) => desktop.copyText(value);

  Future<void> copyImage(String dataUrl) => desktop.copyImage(dataUrl);

  Future<void> openExternalLink(String value) async {
    final kind = artifactKindFromPath(value);
    if (kind != null &&
        !RegExp(r'^https?:', caseSensitive: false).hasMatch(value)) {
      await showArtifact(
        ArtifactPreview(
          id: value,
          kind: kind,
          title: Uri.tryParse(value)?.pathSegments.lastOrNull ?? 'Document',
          path: value,
          cwd: selectedWorkspace,
        ),
      );
      return;
    }
    final uri = Uri.tryParse(value.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      _setStatus('Only web links can be opened in the browser.', warning: true);
      return;
    }
    try {
      await desktop.openExternalUrl(uri);
    } on Object catch (error) {
      _setStatus('Could not open link · $error', warning: true);
    }
  }

  SessionPresence presenceFor(String sessionId, {String? runtimeTargetId}) {
    runtimeTargetId ??= activeRuntime?.id;
    if (runtimeTargetId == null) return SessionPresence.done;
    final sessionKey = _sessionKey(runtimeTargetId, sessionId);
    if (_activeTurns.containsKey(sessionKey)) return SessionPresence.running;
    if (_unreadSessions.contains(sessionKey)) return SessionPresence.unread;
    if (_isActiveSession(runtimeTargetId, sessionId)) {
      return SessionPresence.active;
    }
    return SessionPresence.done;
  }

  void setBlockExpanded(TranscriptBlock block, bool expanded) {
    block.expanded = expanded;
    _notify();
  }

  void setTurnActivityExpanded(
    ConversationTurn turn,
    bool expanded, {
    String? groupId,
  }) {
    if (groupId == null || turn.historySummary) {
      turn.activityExpanded = expanded;
      turn.activityGroupExpansion.clear();
    } else {
      turn.activityGroupExpansion[groupId] = expanded;
    }
    _notify();
    if (expanded && turn.historySummary) unawaited(loadTurnHistory(turn));
  }

  Future<void> _handleDesktopInvocation(DesktopInvocation invocation) async {
    if (invocation.kind == DesktopInvocationKind.openSession) {
      final runtime = invocation.runtimeTargetId;
      final session = invocation.sessionId;
      if (runtime == null || session == null || _closed) return;
      await setExpanded(true, focus: true);
      if (!_canOpenNotification) {
        _pendingNotificationOpen = invocation;
        return;
      }
      _pendingNotificationOpen = null;
      await switchSession(session, runtimeTargetId: runtime);
      return;
    }
    if (invocation.kind == DesktopInvocationKind.windowState) {
      if (invocation.maximized case final maximized?) {
        _applyWindowMaximized(maximized);
      }
      return;
    }
    if (invocation.kind == DesktopInvocationKind.selectContent) {
      await addPointerContext();
      return;
    }
    if (invocation.kind == DesktopInvocationKind.captureStarted) {
      _setStatus(invocation.message ?? 'Capturing context…');
      await setExpanded(true);
      await desktop.showPanel(focus: false);
      return;
    }
    if (invocation.attachment case final attachment?) {
      // The capture already happened before this event. Attach it before any
      // show/focus request so the shortcut can never capture Focalet itself.
      addAttachment(attachment);
    }
    if (invocation.message case final message?) {
      _setStatus(message, warning: invocation.warning);
    }
    if (invocation.kind == DesktopInvocationKind.status) return;
    await setExpanded(true, focus: true);
  }

  void _handleCoreEvent(CoreEvent event) {
    if (_closed) return;
    if (event.name == 'core.disconnected') {
      coreConnectionFailed = true;
      _cancelSwitchRecovery();
      _connectedRuntimes.clear();
      _lastSequences.clear();
      _runtimePreparations.clear();
      _runtimePreparationQueue.clear();
      _commandContexts.clear();
      _commandCatalogs.clear();
      _commandRequests.updateAll((_, value) => value + 1);
      for (final entry in _activeTurns.entries.toList()) {
        final identity = entry.key.split('\u0000');
        _handleCoreEvent(
          CoreEvent(
            name: 'turn.completed',
            sequence: 0,
            runtimeTargetId: identity[0],
            sessionId: identity[1],
            turnId: entry.value,
            payload: {'status': 'unknown', 'error': event.payload['message']},
          ),
        );
      }
      _pausedQueues.addAll(_messageQueues.keys);
      for (var index = 0; index < runtimeTargets.length; index++) {
        final target = runtimeTargets[index];
        if (target.status == 'ready' ||
            target.status == 'connecting' ||
            target.status == 'recovering') {
          runtimeTargets[index] = target.copyWith(status: 'unavailable');
        }
      }
      if (activeRuntime case final runtime?) {
        activeRuntime = runtime.copyWith(status: 'unavailable');
        _rememberConnectionFailure(runtime.id, session: activeSessionId);
      }
      starting = false;
      sessionBusy = false;
      runtimeBusy = false;
      switchingRuntimeId = null;
      _approvals.clear();
      _startingSessions.clear();
      question = null;
      _setStatus(
        'Agent connection lost. Your chats and drafts are kept; submitted requests were not resent.',
        warning: true,
      );
      final runtime = activeRuntime?.id;
      final session = activeSessionId;
      if (runtime != null && session != null && !runtimeSetupPending) {
        _scheduleSwitchRecovery(runtime, session, _switchEpoch);
      }
      return;
    }
    final sequenceKey = '${event.runtimeTargetId}:${event.sessionId ?? ''}';
    final previous = _lastSequences[sequenceKey] ?? 0;
    if (event.sequence > 0 && event.sequence <= previous) return;
    if (event.sequence > 0) _lastSequences[sequenceKey] = event.sequence;
    final sessionId = event.sessionId ?? activeSessionId;
    final discarded = sessionId == null
        ? null
        : _discardedTurnIds[_sessionKey(event.runtimeTargetId, sessionId)];
    if (discarded != null &&
        (discarded.contains(event.turnId) ||
            discarded.contains(event.clientOperationId))) {
      return;
    }
    switch (event.name) {
      case 'commands.updated':
        if (event.sessionId == null) return;
        final key = _sessionKey(event.runtimeTargetId, event.sessionId!);
        _commandRevisions[key] = (_commandRevisions[key] ?? 0) + 1;
        _commandCatalogs[key] = _parseRuntimeCommands(
          event.payload['commands'],
        );
        _commandErrors.remove(key);
        _notify();
      case 'commands.invalidated':
        _commandCatalogs.removeWhere(
          (key, _) => key.startsWith('${event.runtimeTargetId}\u0000'),
        );
        _commandRequests.updateAll(
          (key, value) => key.startsWith('${event.runtimeTargetId}\u0000')
              ? value + 1
              : value,
        );
        _commandContexts.removeWhere(
          (key, _) => key.startsWith('${event.runtimeTargetId}\u0000'),
        );
        if (event.runtimeTargetId == activeRuntime?.id) {
          unawaited(refreshCommands(force: true));
        }
      case 'session.refreshed':
        final connection = RuntimeConnection.fromJson(
          mapValue(event.payload['connection']),
        );
        if (connection.runtimeTargetId != event.runtimeTargetId ||
            connection.sessionId != event.sessionId) {
          return;
        }
        _cacheConnection(connection);
        if (!_isActiveSession(
              connection.runtimeTargetId,
              connection.sessionId,
            ) ||
            sessionBusy) {
          return;
        }
        unawaited(_readActiveHistory(history: connection.history));
        _setStatus(
          sessionReadOnly
              ? 'Chat is open elsewhere · reconnecting automatically'
              : 'Chat reconnected',
        );
        return;
      case 'goal.updated':
        if (sessionId == null) return;
        final key = _sessionKey(event.runtimeTargetId, sessionId);
        _goalRevisions[key] = (_goalRevisions[key] ?? 0) + 1;
        final value = event.payload['goal'];
        _goalsBySession[key] = value is Map ? mapValue(value) : null;
        _notify();
        return;
      case 'runtime.recovered':
        bool belongsToRuntime(String key) =>
            key.startsWith('${event.runtimeTargetId}\u0000');
        _commandContexts.removeWhere((key, _) => belongsToRuntime(key));
        _commandCatalogs.removeWhere((key, _) => belongsToRuntime(key));
        _commandRequests.updateAll(
          (key, value) => belongsToRuntime(key) ? value + 1 : value,
        );
        final connection = RuntimeConnection.fromJson(
          mapValue(event.payload['connection']),
        );
        if (connection.runtimeTargetId != event.runtimeTargetId ||
            connection.sessionId.isEmpty) {
          return;
        }
        _cacheConnection(connection);
        if (activeRuntime?.id == event.runtimeTargetId &&
            activeSessionId == event.payload['previousSessionId']) {
          _rememberActiveSessionSettings();
          _activateConnection(connection);
          _restoreSessionSettings(connection);
          _rememberActiveSessionSettings();
          _setStatus('$activeRuntimeName connection restored');
        }
        _notify();
        return;
      case 'runtime.status':
        if (const [
          'unavailable',
          'recovering',
          'stopped',
        ].contains(event.payload['status'])) {
          _approvals.removeWhere(
            (request) => request.runtimeTargetId == event.runtimeTargetId,
          );
        }
        final message = event.payload['message']?.toString();
        final runtimeStatus = event.payload['status']?.toString();
        if (runtimeStatus?.isNotEmpty == true) {
          final index = runtimeTargets.indexWhere(
            (target) => target.id == event.runtimeTargetId,
          );
          if (index >= 0) {
            runtimeTargets[index] = runtimeTargets[index].copyWith(
              status: runtimeStatus,
            );
            if (activeRuntime?.id == event.runtimeTargetId) {
              activeRuntime = runtimeTargets[index];
              if (runtimeStatus == 'unavailable' ||
                  runtimeStatus == 'recovering') {
                question = null;
              }
            }
          }
        }
        if (message?.isNotEmpty == true &&
            (activeRuntime?.id == event.runtimeTargetId ||
                switchingRuntimeId == event.runtimeTargetId)) {
          _setStatus(
            message!,
            warning: event.payload['status']?.toString() == 'degraded',
          );
        }
        _notify();
        return;
      case 'turn.started':
        if (sessionId == null) return;
        final sessionKey = _sessionKey(event.runtimeTargetId, sessionId);
        final turnId = event.turnId;
        if (turnId != null &&
            _completedTurnIds.containsKey(
              _turnIdentity(event.runtimeTargetId, turnId),
            )) {
          return;
        }
        if (turnId != null && turnId.isNotEmpty) {
          _activeTurns[sessionKey] = turnId;
          if (event.clientOperationId == null &&
              _goalsBySession[sessionKey] != null) {
            final turns = _turnsBySession.putIfAbsent(sessionKey, () => []);
            if (!turns.any((turn) => turn.id == turnId)) {
              turns.add(
                ConversationTurn(
                  id: turnId,
                  runtimeTurnId: turnId,
                  number: turns.length + 1,
                  userText: 'Continue goal',
                  createdAt: messageTimestamp(event.payload) ?? _clock(),
                ),
              );
              _transcriptChanged(sessionKey);
            }
          }
        }
        _scheduleCatalogSave();
        if (_isActiveSession(event.runtimeTargetId, sessionId)) {
          _setStatus('$activeRuntimeName is responding…');
        }
        _notify();
        return;
      case 'item.update':
        if (sessionId == null) return;
        _applyItemUpdate(event.runtimeTargetId, sessionId, event);
        return;
      case 'approval.requested':
        if (sessionId == null || event.sessionId == null) return;
        final request = PendingApproval.fromEvent(
          event.runtimeTargetId,
          sessionId,
          event.payload,
          turnId: event.turnId,
        );
        if (request.id.isEmpty) return;
        if (!_approvals.any(
          (item) =>
              item.id == request.id &&
              item.runtimeTargetId == request.runtimeTargetId &&
              item.sessionId == sessionId,
        )) {
          _approvals.add(request);
        }
        _notify();
        return;
      case 'approval.resolved':
        if (event.sessionId == null) return;
        _approvals.removeWhere(
          (request) =>
              request.id == event.payload['approvalId'] &&
              request.runtimeTargetId == event.runtimeTargetId &&
              request.sessionId == sessionId,
        );
        _notify();
        return;
      case 'question.requested':
        if (sessionId == null) return;
        if (_isActiveSession(event.runtimeTargetId, sessionId)) {
          question = PendingQuestion.fromEvent(
            event.runtimeTargetId,
            sessionId,
            event.payload,
          );
        }
        _notify();
        return;
      case 'turn.completed':
        if (sessionId == null) return;
        final sessionKey = _sessionKey(event.runtimeTargetId, sessionId);
        final turnId = event.turnId;
        // A late completion cannot release a newer queued follow-up.
        final activeId = _activeTurns[sessionKey];
        final completesActive =
            activeId != null &&
            (activeId == turnId || activeId == event.clientOperationId);
        if (turnId != null) {
          final identity = _turnIdentity(event.runtimeTargetId, turnId);
          if (_completedTurnIds.containsKey(identity)) return;
          if (_completedTurnIds.length >= 512) _completedTurnIds.clear();
          _completedTurnIds[identity] =
              event.payload['status']?.toString().toLowerCase() ?? 'completed';
        }
        if (activeId != null &&
            !completesActive &&
            !_startingSessions.contains(sessionKey)) {
          return;
        }
        _approvals.removeWhere(
          (request) =>
              request.runtimeTargetId == event.runtimeTargetId &&
              request.sessionId == sessionId &&
              (request.turnId == null || request.turnId == event.turnId),
        );
        if (completesActive) {
          _activeTurns.remove(sessionKey);
          _interruptingSessions.remove(sessionKey);
          _cancelRequestedSessions.remove(sessionKey);
        }
        _scheduleCatalogSave();
        if (!_isActiveSession(event.runtimeTargetId, sessionId)) {
          _unreadSessions.add(sessionKey);
        }
        final statusValue = event.payload['status']?.toString() ?? 'completed';
        if (completesActive && statusValue.toLowerCase() != 'completed') {
          _pausedQueues.add(sessionKey);
        }
        if (statusValue == 'unknown') {
          final sessionTurns =
              _turnsBySession[sessionKey] ?? const <ConversationTurn>[];
          final interrupted =
              sessionTurns
                  .where(
                    (turn) =>
                        turn.id == event.clientOperationId || turn.id == turnId,
                  )
                  .lastOrNull ??
              sessionTurns.lastOrNull;
          final errorId =
              '${turnId ?? event.clientOperationId}:connection-lost';
          final detail = event.payload['error']?.toString().trim() ?? '';
          if (interrupted != null &&
              !interrupted.blocks.any((block) => block.id == errorId)) {
            interrupted.blocks.add(
              TranscriptBlock(
                id: errorId,
                kind: TranscriptKind.error,
                title: 'Connection lost',
                text:
                    '${_runtimeTarget(event.runtimeTargetId)?.displayName ?? 'Agent'} disconnected before this turn finished. The request was not resent.'
                    '${detail.isEmpty ? '' : '\n\n$detail'}',
                lifecycle: TranscriptLifecycle.completed,
                expanded: true,
              ),
            );
          }
        }
        if (statusValue.toLowerCase() == 'completed') {
          _recordSessionActivity(event.runtimeTargetId, sessionId);
          final completedId = event.turnId ?? event.clientOperationId;
          if (event.sessionId != null && completedId != null) {
            unawaited(
              _notifyResponseReady(
                event.runtimeTargetId,
                sessionId,
                completedId,
              ),
            );
          }
        }
        for (final turn in _turnsBySession[sessionKey] ?? const []) {
          turn.activityExpanded = false;
          turn.activityGroupExpansion.clear();
          for (final block in turn.blocks) {
            if (block.isActivity) {
              block.lifecycle = TranscriptLifecycle.completed;
              block.expanded = false;
            }
          }
        }
        _transcriptChanged(sessionKey);
        if (_isActiveSession(event.runtimeTargetId, sessionId)) {
          _setStatus(switch (statusValue.toLowerCase()) {
            'completed' => '$activeRuntimeName reply complete',
            'interrupted' => '$activeRuntimeName turn stopped',
            'unknown' => '$activeRuntimeName outcome unknown · runtime exited',
            _ => '$activeRuntimeName turn $statusValue',
          }, warning: statusValue.toLowerCase() == 'unknown');
          focusComposerEpoch++;
        }
        _notify();
        if (completesActive) _drainMessageQueue(sessionKey);
        return;
    }
  }

  void _applyItemUpdate(
    String runtimeTargetId,
    String sessionId,
    CoreEvent event,
  ) {
    final sessionKey = _sessionKey(runtimeTargetId, sessionId);
    final sessionTurns = _turnsBySession.putIfAbsent(sessionKey, () => []);
    final eventIdentity = event.clientOperationId ?? event.turnId;
    ConversationTurn? turn;
    if (eventIdentity != null) {
      for (final candidate in sessionTurns.reversed) {
        if (candidate.id == eventIdentity) {
          turn = candidate;
          break;
        }
      }
    }
    if (turn == null &&
        _isActiveSession(runtimeTargetId, sessionId) &&
        sessionTurns.isNotEmpty &&
        sessionTurns.last.id.startsWith('flutter:') &&
        _activeTurns.containsKey(sessionKey)) {
      turn = sessionTurns.last;
    }
    if (turn == null) {
      turn = ConversationTurn(
        id: eventIdentity ?? 'runtime-turn-${sessionTurns.length + 1}',
        runtimeTurnId: event.turnId,
        number: sessionTurns.length + 1,
        userText: 'Continue',
        createdAt: messageTimestamp(event.payload) ?? _clock(),
      );
      sessionTurns.add(turn);
    }
    final kind = _transcriptKind(event.payload['kind']?.toString());
    final lifecycle = _lifecycle(event.payload['lifecycle']?.toString());
    final nativeItemId = event.payload['itemId']?.toString() ?? '';
    final incomingText = event.payload['text']?.toString() ?? '';
    if (kind.isMessage && incomingText.isNotEmpty) {
      _recordSessionActivity(runtimeTargetId, sessionId);
    }
    final sourceMatch = nativeItemId.isEmpty
        ? null
        : _latestBlockForSource(turn.blocks, kind, nativeItemId);
    TranscriptBlock? block = nativeItemId.isEmpty
        ? _latestIncompleteBlock(turn.blocks, kind)
        : sourceMatch != null &&
              _continuesCurrentSegment(turn.blocks, sourceMatch, lifecycle)
        ? sourceMatch
        : null;
    if (block == null &&
        kind == TranscriptKind.assistant &&
        event.payload['textMode'] != 'append') {
      block = _overlappingTrailingAssistant(turn.blocks, incomingText);
    }
    final blockId = nativeItemId.isEmpty
        ? '${kind.name}:${event.sequence}'
        : sourceMatch == null
        ? nativeItemId
        : '$nativeItemId:${event.sequence}';
    // The folded header only displays presence, tool count and completion.
    // Store every delta, but avoid notifying the entire UI (and auto-following)
    // when none of that visible state changes. Opening the group reads the
    // latest stored content, including deltas received while it was folded.
    final foldedActivity = !turn.hasExpandedActivity && kind.isFoldedActivity;
    final previousHeader = block == null
        ? null
        : (
            block.completed,
            block.text.trim().isNotEmpty || block.artifacts.isNotEmpty,
          );
    if (block == null) {
      block = TranscriptBlock(
        id: blockId,
        sourceId: nativeItemId.isEmpty ? blockId : nativeItemId,
        kind: kind,
        title: event.payload['title']?.toString() ?? _kindTitle(kind),
        lifecycle: lifecycle,
        status: event.payload['status']?.toString(),
        expanded: kind == TranscriptKind.error,
        createdAt: messageTimestamp(event.payload) ?? _clock(),
      );
      final beforeItemId = event.payload['beforeItemId']?.toString();
      final beforeIndex = beforeItemId == null
          ? -1
          : turn.blocks.indexWhere((item) => item.sourceId == beforeItemId);
      if (beforeIndex < 0) {
        turn.blocks.add(block);
      } else {
        turn.blocks.insert(beforeIndex, block);
      }
    }
    block.text = mergeActivityText(
      block.text,
      incomingText,
      kind,
      lifecycle,
      replace: event.payload['replace'] == true,
      append: event.payload['textMode'] == 'append',
    );
    block.lifecycle = lifecycle;
    block.status = event.payload['status']?.toString() ?? block.status;
    final preview = event.payload['preview']?.toString() ?? '';
    if (preview.isNotEmpty) block.preview = preview;
    for (final artifactValue in mapList(event.payload['artifacts'])) {
      final artifact = ArtifactPreview.fromJson(artifactValue);
      if (!block.artifacts.any(
        (existing) => existing.identity == artifact.identity,
      )) {
        block.artifacts.add(artifact);
      }
    }
    final backgroundStarted =
        !_isActiveSession(runtimeTargetId, sessionId) &&
        !_activeTurns.containsKey(sessionKey);
    if (!_isActiveSession(runtimeTargetId, sessionId)) {
      _activeTurns.putIfAbsent(sessionKey, () => event.turnId ?? 'running');
    }
    if (foldedActivity &&
        previousHeader ==
            (
              block.completed,
              block.text.trim().isNotEmpty || block.artifacts.isNotEmpty,
            )) {
      if (backgroundStarted) _notify();
      return;
    }
    _transcriptChanged(sessionKey);
    _notify();
  }

  void _ensureSession(String sessionId) {
    final runtimeTargetId = activeRuntime?.id;
    if (sessionId.isEmpty ||
        runtimeTargetId == null ||
        _dismissedSessions.contains((runtimeTargetId, sessionId))) {
      return;
    }
    if (!sessions.any(
      (session) =>
          session.id == sessionId && session.runtimeTargetId == runtimeTargetId,
    )) {
      sessions.insert(
        0,
        SessionSummary(
          id: sessionId,
          runtimeTargetId: runtimeTargetId,
          title: 'New $activeRuntimeName chat',
          updatedAt: _clock().toUtc().toIso8601String(),
        ),
      );
      _sortSessions();
      _scheduleCatalogSave();
    }
    _turnsBySession.putIfAbsent(
      _sessionKey(runtimeTargetId, sessionId),
      () => [],
    );
  }

  void _mergeSessions(
    String runtimeTargetId,
    List<Map<String, Object?>> values,
  ) {
    for (final value in values) {
      final session = SessionSummary.fromJson(
        value,
        runtimeTargetId: runtimeTargetId,
      );
      if (session.id.isEmpty) continue;
      if (_dismissedSessions.contains((runtimeTargetId, session.id))) continue;
      final index = sessions.indexWhere(
        (existing) =>
            existing.runtimeTargetId == runtimeTargetId &&
            existing.id == session.id,
      );
      if (index < 0) {
        sessions.add(session);
      } else {
        final existing = sessions[index];
        // Reopening a chat can return an older provider snapshot. Keep the
        // latest observed reply time when merging that snapshot.
        final hasTitle = [
          'name',
          'preview',
          'title',
        ].any((key) => value[key]?.toString().trim().isNotEmpty == true);
        sessions[index] = session.copyWith(
          title:
              existing.customTitle ??
              (hasTitle ? session.title : existing.title),
          customTitle: existing.customTitle,
          pinned: existing.pinned,
          cwd: session.cwd ?? existing.cwd,
          profile: session.profile ?? existing.profile,
          updatedAt:
              (existing.activityTime?.microsecondsSinceEpoch ?? 0) >
                  (session.activityTime?.microsecondsSinceEpoch ?? 0)
              ? existing.updatedAt
              : session.updatedAt,
        );
      }
    }
    _sortSessions();
    _scheduleCatalogSave();
  }

  void _recordSessionActivity(String runtimeTargetId, String sessionId) {
    final index = sessions.indexWhere(
      (session) =>
          session.runtimeTargetId == runtimeTargetId && session.id == sessionId,
    );
    if (index < 0) return;
    final session = sessions
        .removeAt(index)
        .copyWith(updatedAt: _clock().toUtc().toIso8601String());
    sessions.insert(0, session);
    _sortSessions();
    _catalogUsedAt[runtimeTargetId] = _clock().toUtc();
    _scheduleCatalogSave();
  }

  void _sortSessions() {
    final ordered =
        [
          for (final (index, session) in sessions.indexed)
            (index, session, session.activityTime?.microsecondsSinceEpoch ?? 0),
        ]..sort((a, b) {
          final byPin = (b.$2.pinned ? 1 : 0).compareTo(a.$2.pinned ? 1 : 0);
          if (byPin != 0) return byPin;
          final byTime = b.$3.compareTo(a.$3);
          return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
        });
    sessions
      ..clear()
      ..addAll(ordered.map((entry) => entry.$2));
  }

  void _updateSessionTitle(String sessionId, String message) {
    final runtimeTargetId = activeRuntime?.id;
    if (runtimeTargetId == null) return;
    final index = sessions.indexWhere(
      (session) =>
          session.id == sessionId && session.runtimeTargetId == runtimeTargetId,
    );
    final title = compactSessionTitle(message);
    if (index < 0) {
      sessions.insert(
        0,
        SessionSummary(
          id: sessionId,
          runtimeTargetId: runtimeTargetId,
          title: title,
        ),
      );
    } else if (sessions[index].customTitle == null &&
        sessions[index].title.startsWith('New ')) {
      sessions[index] = sessions[index].copyWith(title: title);
    }
    _scheduleCatalogSave();
  }

  Map<String, Object?>? _selectedModel() =>
      models.cast<Map<String, Object?>?>().firstWhere(
        (model) => _modelId(model!) == selectedModel,
        orElse: () => null,
      );

  void _replaceDiscovery(RuntimeDiscovery discovery) {
    _runtimeTargetAliases.clear();
    _detectedRuntimeIds.clear();
    final visible = _deduplicateRuntimeTargets(
      discovery.targets,
      aliases: _runtimeTargetAliases,
    );
    runtimeTargets
      ..clear()
      ..addAll(visible);
    _detectedRuntimeIds.addAll(visible.map((target) => target.id));
    runtimeSettings = discovery.settings;
    for (final target in visible) {
      _knownRuntimes[target.id] = target;
    }
    _scheduleCatalogSave();
  }

  String? _visibleSelectedTargetId(String? selectedTargetId) {
    selectedTargetId =
        _runtimeTargetAliases[selectedTargetId] ?? selectedTargetId;
    if (selectedTargetId != null &&
        runtimeTargets.any((target) => target.id == selectedTargetId)) {
      return selectedTargetId;
    }
    return runtimeTargets.isEmpty ? null : runtimeTargets.first.id;
  }

  bool _isVisibleRuntimeTarget(RuntimeTarget target) {
    final status = target.status.toLowerCase();
    final detected = !{
      'unavailable',
      'unreachable',
      'missing',
      'not-detected',
    }.contains(status);
    final hasLocator =
        target.executablePath.trim().isNotEmpty ||
        target.endpoint?.trim().isNotEmpty == true;
    // Discovery and connection health are different states. A detected CLI
    // remains available for retry when its process exits; a missing discovery
    // result must still stay out of the picker.
    return hasLocator &&
        (detected ||
            (status == 'unavailable' &&
                _detectedRuntimeIds.contains(target.id)));
  }

  List<RuntimeTarget> _deduplicateRuntimeTargets(
    Iterable<RuntimeTarget> targets, {
    Map<String, String>? aliases,
  }) {
    final selectedByKey = <String, RuntimeTarget>{};
    final orderedKeys = <String>[];
    final candidatesByKey = <String, List<RuntimeTarget>>{};
    for (final target in targets.where(_isVisibleRuntimeTarget)) {
      final key = target.id;
      candidatesByKey.putIfAbsent(key, () => []).add(target);
      if (!selectedByKey.containsKey(key)) {
        orderedKeys.add(key);
        selectedByKey[key] = target;
      }
    }
    for (final entry in candidatesByKey.entries) {
      final selected = selectedByKey[entry.key]!;
      for (final candidate in entry.value) {
        aliases?[candidate.id] = selected.id;
      }
    }
    return orderedKeys.map((key) => selectedByKey[key]!).toList(growable: false)
      ..sort(compareRuntimeTargets);
  }

  void _rememberActiveSessionSettings() {
    final runtimeTargetId = activeRuntime?.id;
    final sessionId = activeSessionId;
    if (runtimeTargetId == null || sessionId == null) return;
    _sessionSettings[_sessionKey(runtimeTargetId, sessionId)] =
        activeSessionSettings;
    final index = sessions.indexWhere(
      (session) =>
          session.runtimeTargetId == runtimeTargetId && session.id == sessionId,
    );
    if (index >= 0 &&
        (sessions[index].cwd != selectedWorkspace ||
            sessions[index].profile != selectedProfile)) {
      sessions[index] = sessions[index].copyWith(
        cwd: selectedWorkspace,
        profile: selectedProfile,
      );
      _scheduleCatalogSave();
    }
  }

  void _hydrateProfiles(RuntimeConnection connection) {
    final values = mapList(connection.sessionMetadata['profiles']);
    if (values.isNotEmpty) profiles = values;
    if (activeRuntime?.runtimeId != 'hermes') profiles = [];
  }

  void _hydrateSessionSettingsFromSummaries(String runtimeTargetId) {
    for (final session in sessions.where(
      (s) => s.runtimeTargetId == runtimeTargetId,
    )) {
      if (_isActiveSession(runtimeTargetId, session.id)) continue;
      final key = _sessionKey(runtimeTargetId, session.id);
      _sessionSettings.putIfAbsent(
        key,
        () => SessionSettings(
          workspace: session.cwd ?? '',
          model: '',
          effort: '',
          profile: session.profile ?? '',
        ),
      );
    }
  }

  SessionSettings _settingsForSession(
    String runtimeTargetId,
    String sessionId,
  ) {
    final saved = _sessionSettings[_sessionKey(runtimeTargetId, sessionId)];
    if (saved != null) return saved;
    final summary = sessions.cast<SessionSummary?>().firstWhere(
      (session) =>
          session?.id == sessionId &&
          session?.runtimeTargetId == runtimeTargetId,
      orElse: () => null,
    );
    final sameRuntime = runtimeTargetId == activeRuntime?.id;
    return SessionSettings(
      workspace: summary?.cwd ?? (sameRuntime ? selectedWorkspace : ''),
      model: _isActiveSession(runtimeTargetId, sessionId) ? selectedModel : '',
      effort: _isActiveSession(runtimeTargetId, sessionId)
          ? selectedEffort
          : '',
      profile: summary?.profile ?? (sameRuntime ? selectedProfile : ''),
    );
  }

  void _restoreSessionSettings(RuntimeConnection connection) {
    final key = _sessionKey(connection.runtimeTargetId, connection.sessionId);
    final summary = sessions.cast<SessionSummary?>().firstWhere(
      (session) =>
          session?.id == connection.sessionId &&
          session?.runtimeTargetId == connection.runtimeTargetId,
      orElse: () => null,
    );
    final saved = _sessionSettings[key];
    final metadata = connection.sessionMetadata;
    var model = saved?.model ?? '';
    if (model.isEmpty ||
        (models.isNotEmpty && !models.any((item) => _modelId(item) == model))) {
      model =
          metadata['activeModel']?.toString() ??
          metadata['model']?.toString() ??
          _defaultModelId();
    }
    selectedModel = model;
    final efforts = effortsForModel(_selectedModel());
    var effort = saved?.effort ?? '';
    if (effort.isEmpty) {
      effort =
          metadata['activeEffort']?.toString() ??
          metadata['effort']?.toString() ??
          metadata['reasoningEffort']?.toString() ??
          _selectedModel()?['defaultReasoningEffort']?.toString() ??
          (efforts.isEmpty ? '' : efforts.first);
    }
    if (efforts.isNotEmpty && !efforts.contains(effort)) {
      effort =
          _selectedModel()?['defaultReasoningEffort']?.toString() ??
          efforts.first;
    }
    final restored = SessionSettings(
      workspace:
          saved?.workspace ?? metadata['cwd']?.toString() ?? summary?.cwd ?? '',
      model: selectedModel,
      effort: effort,
      profile:
          saved?.profile ??
          metadata['profile']?.toString() ??
          metadata['profileName']?.toString() ??
          summary?.profile ??
          activeRuntime?.profileId ??
          '',
    );
    _sessionSettings[key] = restored;
    _applySettings(restored);
    unawaited(refreshCommands());
  }

  void _applySettings(SessionSettings settings) {
    selectedWorkspace = settings.workspace;
    workspaceError = null;
    selectedModel = settings.model;
    selectedEffort = settings.effort;
    selectedProfile = settings.profile;
  }

  bool _isActiveSession(String runtimeTargetId, String sessionId) =>
      activeRuntime?.id == runtimeTargetId && activeSessionId == sessionId;

  static String _sessionKey(String runtimeTargetId, String sessionId) =>
      '$runtimeTargetId\u0000$sessionId';

  static String _turnIdentity(String runtimeTargetId, String turnId) =>
      '$runtimeTargetId\u0000$turnId';

  String _defaultModelId() {
    final preferred = models.cast<Map<String, Object?>?>().firstWhere(
      (model) => model?['isDefault'] == true,
      orElse: () => null,
    );
    return preferred == null
        ? (models.isEmpty ? '' : _modelId(models.first))
        : _modelId(preferred);
  }

  Future<void> _notifyResponseReady(
    String runtime,
    String session,
    String turn,
  ) async {
    if (!_notifiedTurns.add((runtime, session, turn))) return;
    if (_notifiedTurns.length > 512) {
      _notifiedTurns.remove(_notifiedTurns.first);
    }
    final summary = sessions
        .where(
          (value) => value.runtimeTargetId == runtime && value.id == session,
        )
        .firstOrNull;
    try {
      await desktop.notifyResponseReady(
        runtimeTargetId: runtime,
        sessionId: session,
        turnId: turn,
        runtimeName: _runtimeTarget(runtime)?.displayName ?? 'Agent',
        sessionTitle: summary?.title ?? '',
      );
    } on Object {
      // A disabled desktop notification must not affect a completed response.
    }
  }

  void dismissStatusWarning() {
    _runtimeRecovery = null;
    statusWarning = false;
    _notify();
  }

  void _rememberConnectionFailure(
    String target, {
    String? session,
    bool create = false,
  }) {
    connectionErrorTargetId = target;
    connectionErrorSessionId = session;
    _retryCreatesSession = create;
    _connectedRuntimes.remove(target);
  }

  Future<void> retryConnection({bool restart = false}) async {
    final target = connectionErrorTargetId ?? activeRuntime?.id;
    final session = connectionErrorSessionId;
    final create = _retryCreatesSession;
    if (sessionBusy || runtimeBusy) return;
    _cancelSwitchRecovery();
    try {
      if (restart && core is CoreRecoveryBridge) {
        await (core as CoreRecoveryBridge).restartCore();
        _cancelSwitchRecovery();
      }
      if (target == null) {
        await core.initialize();
        await refreshRuntimes();
        if (runtimeDiscoveryError == null) {
          coreConnectionFailed = false;
          _setStatus('Connection restored. Choose an agent to continue.');
        }
        return;
      }
      if (create) {
        await createSession(runtimeTargetId: target);
      } else if (session != null) {
        await switchSession(session, runtimeTargetId: target);
      } else {
        await connectRuntimeForSetup(target);
      }
    } on Object catch (error) {
      _setStatus('Could not reconnect · $error', warning: true);
    }
  }

  void cancelConnectionAttempt() {
    _cancelSwitchRecovery();
    sessionBusy = false;
    runtimeBusy = false;
    switchingRuntimeId = null;
    if (core is CoreRecoveryBridge) {
      unawaited(
        (core as CoreRecoveryBridge).cancelSelection().catchError(
          (Object _) {},
        ),
      );
    }
    _setStatus('Connection cancelled. Your chat and draft are kept.');
  }

  void _setStatus(String value, {bool warning = false}) {
    if (!warning) _runtimeRecovery = null;
    status = value;
    statusWarning = warning;
    _notify();
  }

  void _notify() {
    if (_closed) return;
    notifyListeners();
    final pending = _pendingNotificationOpen;
    if (pending != null && _canOpenNotification) {
      _pendingNotificationOpen = null;
      // Resume after the operation that blocked navigation has settled.
      scheduleMicrotask(() {
        if (!_closed) unawaited(_handleDesktopInvocation(pending));
      });
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _switchRetryTimer?.cancel();
    _catalogStartupTimer?.cancel();
    _catalogRetentionTimer?.cancel();
    for (final (_, completion) in _catalogQueue) {
      completion.complete();
    }
    _catalogQueue.clear();
    await flushSessionCatalog();
    await _coreEvents?.cancel();
    await _desktopEvents?.cancel();
    await Future.wait([core.close(), desktop.close()]);
    super.dispose();
  }
}

List<ConversationTurn> mergeSessionHistory(
  List<ConversationTurn> canonical,
  List<ConversationTurn> cached, {
  required bool preserveCached,
  bool preferCachedUpdates = false,
  bool reconcileLocalTurnIds = false,
}) {
  if (canonical.isEmpty) return List<ConversationTurn>.of(cached);
  if (cached.isEmpty) return List<ConversationTurn>.of(canonical);
  final merged = List<ConversationTurn>.of(canonical);
  final offset = canonical.length - cached.length;
  final canReconcile =
      reconcileLocalTurnIds &&
      offset >= 0 &&
      (offset == 0 || cached.any((turn) => !turn.id.startsWith('flutter:'))) &&
      List.generate(cached.length, (index) => index).every((index) {
        final fresh = canonical[offset + index];
        final shown = cached[index];
        return fresh.userText == shown.userText &&
            (fresh.runtimeTurnId == shown.runtimeTurnId ||
                shown.id.startsWith('flutter:'));
      });
  for (var cachedIndex = 0; cachedIndex < cached.length; cachedIndex++) {
    final cachedTurn = cached[cachedIndex];
    var index = merged.indexWhere(
      (turn) =>
          turn.id == cachedTurn.id ||
          (cachedTurn.runtimeTurnId != null &&
              turn.runtimeTurnId == cachedTurn.runtimeTurnId),
    );
    if (index < 0 && canReconcile && cachedTurn.id.startsWith('flutter:')) {
      index = offset + cachedIndex;
    }
    if (index < 0 &&
        cachedTurn.runtimeTurnId == null &&
        cachedTurn.id.startsWith('flutter:')) {
      index = merged.lastIndexWhere(
        (turn) => turn.userText == cachedTurn.userText,
      );
    }
    if (index < 0) {
      merged.add(cachedTurn);
    } else {
      merged[index] = preserveCached
          ? mergeConversationTurn(
              cachedTurn,
              merged[index],
              preferPrimaryBlocks: preferCachedUpdates,
              userPresentation: cachedTurn,
            )
          : mergeConversationTurn(
              merged[index],
              cachedTurn,
              userPresentation: cachedTurn,
            );
    }
  }
  return merged;
}

ConversationTurn mergeConversationTurn(
  ConversationTurn primary,
  ConversationTurn secondary, {
  bool preferPrimaryBlocks = false,
  ConversationTurn? userPresentation,
}) {
  final presentation = userPresentation?.attachments.isNotEmpty == true
      ? userPresentation!
      : primary.attachments.isNotEmpty
      ? primary
      : secondary;
  final blocks = List<TranscriptBlock>.of(primary.blocks);
  // Match each rekeyed snapshot once so repeated messages remain separate.
  final matchedIndexes = <int>{};
  final matches = <int>[];
  for (final candidate in secondary.blocks) {
    final match = _matchingTranscriptBlock(blocks, candidate, matchedIndexes);
    matches.add(match);
    if (match >= 0) {
      matchedIndexes.add(match);
      // Events received after the history request began are newer than its
      // snapshot, including a final replacement of an earlier partial reply.
      if (!preferPrimaryBlocks) {
        blocks[match] = mergeTranscriptBlocks(blocks[match], candidate);
      }
    }
  }
  // Place missing history between shared neighbours. Appending everything
  // after the primary snapshot can put old tools/thinking after its answer.
  final insertions = <int, List<TranscriptBlock>>{};
  var previousAnchor = -1;
  for (var index = 0; index < secondary.blocks.length; index++) {
    final match = matches[index];
    if (match >= 0) {
      if (match > previousAnchor) previousAnchor = match;
      continue;
    }
    final nextAnchor = matches
        .skip(index + 1)
        .where((value) => value > previousAnchor)
        .firstOrNull;
    insertions
        .putIfAbsent(nextAnchor ?? blocks.length, () => [])
        .add(secondary.blocks[index]);
  }
  final orderedBlocks = <TranscriptBlock>[
    for (var index = 0; index <= blocks.length; index++) ...[
      ...?insertions[index],
      if (index < blocks.length) blocks[index],
    ],
  ];
  return ConversationTurn(
      id: primary.id,
      runtimeTurnId: primary.runtimeTurnId ?? secondary.runtimeTurnId,
      number: primary.number,
      userText: primary.userText,
      createdAt: primary.createdAt ?? secondary.createdAt,
      inlineUserText: presentation.attachments.isEmpty
          ? primary.inlineUserText
          : presentation.inlineUserText,
      activityExpanded: primary.activityExpanded,
      historySummary: primary.historySummary && secondary.historySummary,
      activityGroupExpansion: primary.activityGroupExpansion,
      contextTokens: presentation.attachments.isNotEmpty
          ? presentation.contextTokens
          : primary.contextTokens.isEmpty
          ? secondary.contextTokens
          : primary.contextTokens,
      attachments: presentation.attachments,
      blocks: normalizeTranscriptBlocks(orderedBlocks),
    )
    ..historyLoading = primary.historyLoading || secondary.historyLoading
    ..historyError = primary.historyError ?? secondary.historyError;
}

int _matchingTranscriptBlock(
  List<TranscriptBlock> blocks,
  TranscriptBlock candidate,
  Set<int> matchedIndexes,
) {
  final identityMatch = blocks.indexWhere(
    (block) => block.kind == candidate.kind && block.id == candidate.id,
  );
  if (identityMatch >= 0) return identityMatch;
  if (candidate.kind == TranscriptKind.tool && candidate.preview.isNotEmpty) {
    for (var index = 0; index < blocks.length; index++) {
      final block = blocks[index];
      if (!matchedIndexes.contains(index) &&
          block.kind == candidate.kind &&
          block.title == candidate.title &&
          block.preview == candidate.preview) {
        return index;
      }
    }
  }
  if (candidate.text.trim().isEmpty) return -1;
  for (var index = 0; index < blocks.length; index++) {
    if (matchedIndexes.contains(index)) continue;
    final block = blocks[index];
    if (block.kind == candidate.kind &&
        (candidate.kind == TranscriptKind.assistant
            ? transcriptTextSnapshotsOverlap(block.text, candidate.text)
            : block.text.trim() == candidate.text.trim())) {
      return index;
    }
  }
  return -1;
}

TranscriptBlock? _latestIncompleteBlock(
  List<TranscriptBlock> blocks,
  TranscriptKind kind,
) {
  if (blocks.isEmpty) return null;
  final trailing = blocks.last;
  return trailing.kind == kind && !trailing.completed ? trailing : null;
}

TranscriptBlock? _latestBlockForSource(
  List<TranscriptBlock> blocks,
  TranscriptKind kind,
  String sourceId,
) {
  for (final block in blocks.reversed) {
    if (block.kind == kind && block.sourceId == sourceId) return block;
  }
  return null;
}

bool _continuesCurrentSegment(
  List<TranscriptBlock> blocks,
  TranscriptBlock block,
  TranscriptLifecycle lifecycle,
) {
  if (block.kind == TranscriptKind.assistant ||
      block.kind == TranscriptKind.tool) {
    return true;
  }
  if (blocks.isNotEmpty && identical(blocks.last, block)) return true;
  return lifecycle == TranscriptLifecycle.completed && !block.completed;
}

TranscriptBlock? _overlappingTrailingAssistant(
  List<TranscriptBlock> blocks,
  String incomingText,
) {
  if (incomingText.trim().isEmpty || blocks.isEmpty) return null;
  final trailing = blocks.last;
  if (trailing.kind != TranscriptKind.assistant) return null;
  return transcriptTextSnapshotsOverlap(trailing.text, incomingText)
      ? trailing
      : null;
}

String normalizeRuntimeExecutablePath(
  String selectedPath,
  Map<String, Object?> executionHost,
) {
  final path = selectedPath.trim();
  if (executionHost['kind'] != 'wsl') return path;
  final distribution = executionHost['name']?.toString().trim() ?? '';
  if (distribution.isEmpty) return path;
  final normalized = path.replaceAll('\\', '/');
  final lower = normalized.toLowerCase();
  for (final prefix in [
    '//wsl.localhost/${distribution.toLowerCase()}/',
    '//wsl\$/${distribution.toLowerCase()}/',
  ]) {
    if (lower.startsWith(prefix)) {
      return '/${normalized.substring(prefix.length)}';
    }
  }
  if (RegExp(r'^[A-Za-z]:/').hasMatch(normalized)) {
    final drive = normalized.substring(0, 1).toLowerCase();
    return '/mnt/$drive/${normalized.substring(3)}';
  }
  return path;
}

String normalizeWorkspacePath(
  String selectedPath,
  Map<String, Object?> executionHost,
) => normalizeRuntimeExecutablePath(selectedPath, executionHost);

List<String> effortsForModel(Map<String, Object?>? model) =>
    (model?['supportedReasoningEfforts'] as List<Object?>? ?? const [])
        .map((option) {
          if (option is String) return option;
          return mapValue(option)['reasoningEffort']?.toString() ?? '';
        })
        .where((value) => value.isNotEmpty)
        .toList(growable: false);

String _modelId(Map<String, Object?> model) =>
    model['model']?.toString() ?? model['id']?.toString() ?? '';

String _formatEffort(String value) => value.isEmpty
    ? ''
    : '${value.substring(0, 1).toUpperCase()}${value.substring(1)}';

TranscriptKind _transcriptKind(String? value) => switch (value?.toLowerCase()) {
  'assistant' => TranscriptKind.assistant,
  'commentary' => TranscriptKind.commentary,
  'thinking' => TranscriptKind.thinking,
  'plan' => TranscriptKind.plan,
  'tool' || 'tooloutput' => TranscriptKind.tool,
  _ => TranscriptKind.tool,
};

TranscriptLifecycle _lifecycle(String? value) => switch (value?.toLowerCase()) {
  'started' => TranscriptLifecycle.started,
  'completed' => TranscriptLifecycle.completed,
  _ => TranscriptLifecycle.delta,
};

String _kindTitle(TranscriptKind kind) => switch (kind) {
  TranscriptKind.assistant || TranscriptKind.commentary => 'Agent',
  TranscriptKind.thinking => 'Thinking',
  TranscriptKind.plan => 'Plan',
  TranscriptKind.tool => 'Tool',
  TranscriptKind.error => 'Error',
};
