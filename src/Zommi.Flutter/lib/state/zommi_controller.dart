import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/desktop/artifact_loader.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/state/history_mapper.dart';
import 'package:zommi_flutter/state/zommi_models.dart';

const int historyPageSize = 18;

final class ZommiController extends ChangeNotifier {
  ZommiController({
    required this.core,
    required this.desktop,
    ArtifactLoader? artifactLoader,
  }) : artifactLoader = artifactLoader ?? const LocalArtifactLoader();

  final CoreBridge core;
  final DesktopBridge desktop;
  final ArtifactLoader artifactLoader;

  final List<RuntimeTarget> runtimeTargets = [];
  final List<SessionSummary> sessions = [];
  final List<Map<String, Object?>> models = [];
  final List<ContextAttachment> attachments = [];
  Map<String, Object?> runtimeSettings = {};
  final Map<String, List<ConversationTurn>> _turnsBySession = {};
  final Map<String, String> _activeTurns = {};
  final Set<String> _unreadSessions = {};
  final Set<String> _cancelRequestedSessions = {};
  final Set<String> _interruptingSessions = {};
  final Set<String> _completedTurnIds = {};
  final Map<String, int> _lastSequences = {};
  final Map<String, SessionSettings> _sessionSettings = {};
  final Map<String, List<Map<String, Object?>>> _modelCatalogs = {};
  final Map<String, String> _runtimeTargetAliases = {};

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
  bool initialized = false;
  bool starting = true;
  bool runtimeBusy = false;
  String? switchingRuntimeId;
  bool runtimeOverrideBusy = false;
  bool sessionBusy = false;
  bool sessionSettingsBusy = false;
  bool submitting = false;
  bool expanded = true;
  bool largePanel = false;
  bool surfaceTransitioning = false;
  bool surfaceTransitionAnimating = false;
  bool transitionTargetExpanded = true;
  bool transitionTargetLarge = false;
  bool sessionPanelOpen = false;
  bool runtimePanelOpen = false;
  bool runtimeSetupPanelOpen = false;
  bool modelPanelOpen = false;
  bool sessionSettingsDetailOpen = false;
  bool contextShortcutRegistered = false;
  bool imageShortcutRegistered = false;
  int focusComposerEpoch = 0;
  int sessionSettingsOverviewEpoch = 0;
  PendingApproval? approval;
  PendingQuestion? question;
  ContextAttachment? previewAttachment;
  ArtifactPreview? previewArtifact;
  bool resolvingPrompt = false;
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

  List<ConversationTurn> get turns =>
      _turnsBySession[_activeSessionKey] ?? const [];

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
      capabilities.contains('session.list.v1') ||
      capabilities.contains('session.resume.v1');

  bool get sessionCreationSupported =>
      capabilities.contains('session.create.v1');

  bool get modelSelectionSupported =>
      capabilities.contains('model.select.v1') && models.isNotEmpty;

  bool get sessionSettingsSupported => activeSessionId != null;

  bool get profileSelectionSupported =>
      activeRuntime?.runtimeId == 'hermes' &&
      activeRuntime?.adapterId == 'hermes-gateway' &&
      profiles.isNotEmpty;

  bool get runtimeOverridesSupported => core is RuntimeConfigurationBridge;

  List<Map<String, Object?>> get runtimeOverrideAdapters =>
      mapList(runtimeSettings['adapters']);

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

  String get runtimeSummary {
    if (switchingRuntimeId != null) {
      return 'Switching to ${switchingRuntimeName ?? 'agent'}…';
    }
    final runtime = activeRuntime;
    if (runtime == null) {
      return runtimeBusy ? 'Finding agents…' : 'Choose agent';
    }
    final host = runtime.executionHost;
    final hostName = host['kind'] == 'wsl'
        ? host['name']?.toString() ?? host['displayName']?.toString() ?? 'WSL'
        : host['displayName']?.toString() ?? 'Local';
    return '${runtime.displayName} · $hostName';
  }

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
    try {
      final coreStatus = await core.initialize();
      _setStatus('Finding agent runtimes…');
      final discovery = await core.discoverRuntimeTargets();
      if (_closed) return;
      _replaceDiscovery(discovery);
      final targetId = _visibleSelectedTargetId(discovery.selectedTargetId);
      if (targetId == null || targetId.isEmpty) {
        _setStatus(
          'No supported agent found. Capture remains available.',
          warning: true,
        );
        return;
      }
      try {
        await _connectRuntime(targetId, coreVersion: coreStatus.version);
      } on Object catch (error) {
        if (!_applyConnectionError(targetId, error)) rethrow;
      }
    } on Object catch (error) {
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
    } finally {
      await desktopInitialization;
      starting = false;
      _notify();
    }
  }

  Future<void> _initializeDesktopIntegration() async {
    try {
      final readiness = await desktop.initialize();
      contextShortcutRegistered = readiness.contextShortcut;
      imageShortcutRegistered = readiness.imageShortcut;
      _notify();
    } on Object catch (error) {
      _setStatus('Desktop integration unavailable · $error', warning: true);
    }
  }

  Future<void> refreshRuntimes() async {
    if (runtimeBusy) return;
    runtimeBusy = true;
    _setStatus('Finding agent runtimes…');
    try {
      final discovery = await core.discoverRuntimeTargets(
        lastSelectedTargetId: activeRuntime?.id,
        force: true,
      );
      _replaceDiscovery(discovery);
      final selected = _visibleSelectedTargetId(discovery.selectedTargetId);
      if (activeRuntime == null && selected != null) {
        await _connectRuntime(selected);
      } else if (runtimeTargets.isEmpty) {
        _setStatus(
          'No supported agent found. Capture remains available.',
          warning: true,
        );
      } else {
        _setStatus('${runtimeTargets.length} agent targets found');
      }
    } on Object catch (error) {
      _setStatus('Agent discovery failed · $error', warning: true);
    } finally {
      runtimeBusy = false;
      _notify();
    }
  }

  Future<void> selectRuntime(String targetId) async {
    final selectingActiveRuntime = activeRuntime?.id == targetId;
    final activeRuntimeUnavailable =
        selectingActiveRuntime && activeRuntime?.status == 'unavailable';
    if (runtimeBusy || (selectingActiveRuntime && !activeRuntimeUnavailable)) {
      closeTransientPanels();
      return;
    }
    runtimeBusy = true;
    switchingRuntimeId = targetId;
    approval = null;
    question = null;
    previewArtifact = null;
    closeTransientPanels();
    _setStatus('Switching to ${switchingRuntimeName ?? 'agent'}…');
    try {
      await _connectRuntime(targetId);
    } on Object catch (error) {
      if (!_applyConnectionError(targetId, error)) {
        _setStatus('Could not switch agent · $error', warning: true);
      }
    } finally {
      runtimeBusy = false;
      switchingRuntimeId = null;
      _notify();
    }
  }

  bool _applyConnectionError(String targetId, Object error) {
    final message = error.toString();
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
      activeRuntime = runtimeTargets[index];
      capabilities = activeRuntime!.capabilityHints.toSet();
    }
    _setStatus('$activeRuntimeName sign-in required', warning: true);
    return true;
  }

  Future<void> openRuntimeSignIn() async {
    final runtime = activeRuntime;
    if (runtime == null) return;
    try {
      await desktop.openRuntimeSignIn(runtime);
      _setStatus('${runtime.displayName} sign-in opened in a terminal');
    } on Object catch (error) {
      _setStatus('Could not open sign-in · $error', warning: true);
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

  Future<void> saveRuntimeOverride({
    required String adapterId,
    required String locator,
    String? executionHostId,
  }) async {
    if (core is! RuntimeConfigurationBridge) return;
    final configuration = core as RuntimeConfigurationBridge;
    if (runtimeOverrideBusy || locator.trim().isEmpty) return;
    final adapter = runtimeOverrideAdapters
        .cast<Map<String, Object?>?>()
        .firstWhere(
          (value) => value?['adapterId'] == adapterId,
          orElse: () => null,
        );
    if (adapter == null) return;
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
      return;
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
      _setStatus('Runtime override added');
    } on Object catch (error) {
      _setStatus('Could not add runtime override · $error', warning: true);
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

  Future<void> _connectRuntime(String targetId, {String? coreVersion}) async {
    _rememberActiveSessionSettings();
    final connection = await core.connectRuntime(runtimeTargetId: targetId);
    activeRuntime = runtimeTargets.cast<RuntimeTarget?>().firstWhere(
      (target) => target?.id == connection.runtimeTargetId,
      orElse: () => null,
    );
    activeSessionId = connection.sessionId;
    capabilities = {
      ...?activeRuntime?.capabilityHints,
      ...connection.capabilities,
    };
    if (connection.models.isNotEmpty) {
      _modelCatalogs[connection.runtimeTargetId] = List.of(connection.models);
    }
    models
      ..clear()
      ..addAll(
        connection.models.isNotEmpty
            ? connection.models
            : _modelCatalogs[connection.runtimeTargetId] ?? const [],
      );
    sessions
      ..clear()
      ..addAll(_sessionSummaries(connection.sessions));
    _ensureSession(connection.sessionId);
    _hydrateProfiles(connection);
    if (capabilities.contains('session.list.v1')) {
      try {
        final values = await core.listSessions(
          runtimeTargetId: connection.runtimeTargetId,
        );
        sessions
          ..clear()
          ..addAll(_sessionSummaries(values));
        _ensureSession(connection.sessionId);
      } on Object {
        // The exact connection remains usable when optional listing fails.
      }
    }
    _hydrateSessionSettingsFromSummaries(connection.runtimeTargetId);
    _restoreSessionSettings(connection);
    await _readActiveHistory();
    _rememberActiveSessionSettings();
    final version = connection.runtimeVersion ?? coreVersion;
    _setStatus('$activeRuntimeName${version == null ? '' : ' $version'} ready');
  }

  Future<void> _readActiveHistory() async {
    final runtimeTargetId = activeRuntime?.id;
    final sessionId = activeSessionId;
    if (runtimeTargetId == null || sessionId == null) return;
    final sessionKey = _sessionKey(runtimeTargetId, sessionId);
    if (!capabilities.contains('history.read.v1')) {
      _turnsBySession.putIfAbsent(sessionKey, () => []);
      return;
    }
    try {
      final response = await core.readSession(
        runtimeTargetId: runtimeTargetId,
        sessionId: sessionId,
      );
      final canonical = mapThreadHistory(response);
      final cached = _turnsBySession[sessionKey] ?? const <ConversationTurn>[];
      _turnsBySession[sessionKey] = mergeSessionHistory(
        canonical,
        cached,
        preserveCached: _activeTurns.containsKey(sessionKey),
      );
    } on Object catch (error) {
      _turnsBySession.putIfAbsent(sessionKey, () => []);
      _setStatus('History unavailable · $error', warning: true);
    }
    _notify();
  }

  Future<void> createSession() async {
    final runtimeTargetId = activeRuntime?.id;
    if (runtimeTargetId == null || sessionBusy || !sessionCreationSupported) {
      return;
    }
    sessionBusy = true;
    _notify();
    try {
      final inherited = activeSessionSettings;
      final connection = await core.createSession(
        runtimeTargetId: runtimeTargetId,
        model: selectedModel.isEmpty ? null : selectedModel,
        effort: selectedEffort.isEmpty ? null : selectedEffort,
        cwd: selectedWorkspace.isEmpty ? null : selectedWorkspace,
        profile: selectedProfile.isEmpty ? null : selectedProfile,
      );
      await _applySessionConnection(connection, inherited: inherited);
      _setStatus('New chat ready');
    } on Object catch (error) {
      _setStatus('Could not create chat · $error', warning: true);
    } finally {
      sessionBusy = false;
      _notify();
    }
  }

  Future<void> switchSession(String sessionId) async {
    final runtimeTargetId = activeRuntime?.id;
    if (runtimeTargetId == null ||
        sessionBusy ||
        sessionId == activeSessionId) {
      sessionPanelOpen = false;
      _notify();
      return;
    }
    sessionBusy = true;
    _rememberActiveSessionSettings();
    _notify();
    try {
      final targetSettings = _settingsForSession(runtimeTargetId, sessionId);
      final connection = await core.openSession(
        runtimeTargetId: runtimeTargetId,
        sessionId: sessionId,
        cwd: targetSettings.workspace.isEmpty ? null : targetSettings.workspace,
        profile: targetSettings.profile.isEmpty ? null : targetSettings.profile,
      );
      await _applySessionConnection(connection);
      _setStatus('Chat switched');
      sessionPanelOpen = false;
    } on Object catch (error) {
      _setStatus('Could not switch chat · $error', warning: true);
    } finally {
      sessionBusy = false;
      _notify();
    }
  }

  Future<void> _applySessionConnection(
    RuntimeConnection connection, {
    SessionSettings? inherited,
  }) async {
    activeSessionId = connection.sessionId;
    _unreadSessions.remove(
      _sessionKey(connection.runtimeTargetId, connection.sessionId),
    );
    capabilities = {...capabilities, ...connection.capabilities};
    if (connection.models.isNotEmpty) {
      _modelCatalogs[connection.runtimeTargetId] = List.of(connection.models);
      models
        ..clear()
        ..addAll(connection.models);
    } else if (models.isEmpty) {
      models.addAll(_modelCatalogs[connection.runtimeTargetId] ?? const []);
    }
    if (connection.sessions.isNotEmpty) {
      sessions
        ..clear()
        ..addAll(_sessionSummaries(connection.sessions));
    }
    _ensureSession(connection.sessionId);
    _hydrateProfiles(connection);
    _hydrateSessionSettingsFromSummaries(connection.runtimeTargetId);
    final key = _sessionKey(connection.runtimeTargetId, connection.sessionId);
    if (inherited != null) _sessionSettings[key] = inherited;
    _restoreSessionSettings(connection);
    _rememberActiveSessionSettings();
    await _readActiveHistory();
    focusComposerEpoch++;
  }

  Future<void> submit(
    String message, {
    String? inlineMessage,
    List<String>? attachmentOrder,
  }) async {
    final text = message.trim();
    final runtimeTargetId = activeRuntime?.id;
    final sessionId = activeSessionId;
    if (text.isEmpty || submitting) return;
    if (runtimeTargetId == null || sessionId == null) {
      _setStatus(
        'No agent session is ready. Choose or refresh an agent.',
        warning: true,
      );
      return;
    }
    final sessionKey = _sessionKey(runtimeTargetId, sessionId);
    if (_activeTurns.containsKey(sessionKey)) return;
    final sendingAttachments = _orderedAttachments(attachmentOrder);
    attachments.clear();
    previewAttachment = null;
    final operationId =
        'flutter:${DateTime.now().microsecondsSinceEpoch}:${++_localTurnSequence}';
    final localTurn = ConversationTurn(
      id: operationId,
      number: (_turnsBySession[sessionKey]?.length ?? 0) + 1,
      userText: text,
      inlineUserText: inlineMessage,
      contextTokens: sendingAttachments
          .where((item) => !item.hasImage)
          .map((item) => item.token)
          .toList(),
      attachments: sendingAttachments,
    );
    _turnsBySession.putIfAbsent(sessionKey, () => []).add(localTurn);
    _activeTurns[sessionKey] = operationId;
    _updateSessionTitle(sessionId, text);
    submitting = true;
    _setStatus('Starting $activeRuntimeName turn…');
    try {
      final receipt = await core.startTurn(
        runtimeTargetId: runtimeTargetId,
        sessionId: sessionId,
        message: text,
        snapshots: sendingAttachments
            .map((item) => item.snapshot)
            .whereType<Map<String, Object?>>()
            .toList(growable: false),
        images: sendingAttachments
            .map((item) => item.imageDataUrl)
            .whereType<String>()
            .toList(growable: false),
        clientOperationId: operationId,
        model: selectedModel.isEmpty ? null : selectedModel,
        effort: selectedEffort.isEmpty ? null : selectedEffort,
        cwd: selectedWorkspace.isEmpty ? null : selectedWorkspace,
        profile: selectedProfile.isEmpty ? null : selectedProfile,
      );
      final completedIdentity = _turnIdentity(
        receipt.runtimeTargetId,
        receipt.turnId,
      );
      if (!_completedTurnIds.contains(completedIdentity)) {
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
        _cancelRequestedSessions.remove(sessionKey);
        _interruptingSessions.remove(sessionKey);
      }
    } on Object catch (error) {
      _activeTurns.remove(sessionKey);
      _cancelRequestedSessions.remove(sessionKey);
      _interruptingSessions.remove(sessionKey);
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
      _setStatus('Core request failed · $error', warning: true);
    } finally {
      submitting = false;
      _notify();
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
    if (!imageInputSupported) return;
    try {
      final attachment = await desktop.selectImageContext();
      if (attachment != null) {
        addAttachment(attachment);
        _setStatus('Image context attached');
      }
    } on Object catch (error) {
      _setStatus('Image selection failed · $error', warning: true);
    }
  }

  Future<void> addPointerContext() async {
    var attachmentAdded = false;
    try {
      final attachment = await desktop.captureContext(hidePanel: true);
      if (attachment != null) {
        addAttachment(attachment);
        attachmentAdded = true;
        _setStatus('Context attached');
      } else {
        _setStatus(
          'No accessible context was exposed under the pointer',
          warning: true,
        );
      }
    } on Object catch (error) {
      _setStatus('Context capture failed · $error', warning: true);
    } finally {
      if (!attachmentAdded) {
        focusComposerEpoch++;
        _notify();
      }
      await desktop.showPanel();
    }
  }

  void addAttachment(ContextAttachment attachment) {
    attachments.add(attachment.withToken(_attachmentToken(attachment)));
    previewAttachment = null;
    focusComposerEpoch++;
    _notify();
  }

  void removeAttachment(String id) {
    attachments.removeWhere((attachment) => attachment.id == id);
    if (previewAttachment?.id == id) previewAttachment = null;
    _notify();
  }

  String _attachmentToken(ContextAttachment attachment) {
    var label = 'image';
    final snapshot = attachment.snapshot;
    if (!attachment.hasImage && snapshot != null) {
      final locator = mapValue(snapshot['locator']);
      if (locator['kind']?.toString().toLowerCase() == 'url') {
        final uri = Uri.tryParse(locator['value']?.toString() ?? '');
        label =
            uri?.host.replaceFirst(
              RegExp(r'^www\.', caseSensitive: false),
              '',
            ) ??
            '';
        if (label.isEmpty) label = 'context';
      } else {
        label = (snapshot['application']?.toString() ?? 'context')
            .toLowerCase()
            .replaceAll(RegExp(r'\s+'), '-');
      }
    }
    if (label.length > 30) label = label.substring(0, 30);
    final used = attachments.map((item) => item.token).toSet();
    var token = '[$label]';
    for (var suffix = 2; used.contains(token); suffix++) {
      token = '[$label $suffix]';
    }
    return token;
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
      previewArtifact = await artifactLoader.load(
        artifact,
        target: activeRuntime,
      );
    } on Object catch (error) {
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
      approval = null;
      _setStatus(
        optionId == null ? 'Permission denied' : 'Permission response sent',
      );
    } on Object catch (error) {
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
    if (runtime == null || sessionId == null || sessionSettingsBusy) {
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
        profile.isEmpty ||
        profile == selectedProfile) {
      return;
    }
    final previous = activeSessionSettings;
    final selected = previous.copyWith(profile: profile);
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
      runtimePanelOpen = false;
      modelPanelOpen = false;
      sessionSettingsDetailOpen = false;
    }
    _notify();
  }

  void toggleRuntimePanel() {
    runtimePanelOpen = !runtimePanelOpen;
    if (runtimePanelOpen) {
      sessionPanelOpen = false;
      runtimeSetupPanelOpen = false;
      modelPanelOpen = false;
      sessionSettingsDetailOpen = false;
    }
    _notify();
  }

  void toggleRuntimeSetupPanel([bool? open]) {
    runtimeSetupPanelOpen = open ?? !runtimeSetupPanelOpen;
    if (runtimeSetupPanelOpen) {
      sessionPanelOpen = false;
      runtimePanelOpen = false;
      modelPanelOpen = false;
      sessionSettingsDetailOpen = false;
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
      sessionSettingsDetailOpen = false;
      sessionPanelOpen = false;
      runtimePanelOpen = false;
      runtimeSetupPanelOpen = false;
    }
    _notify();
  }

  void closeTransientPanels() {
    sessionPanelOpen = false;
    runtimePanelOpen = false;
    runtimeSetupPanelOpen = false;
    modelPanelOpen = false;
    sessionSettingsDetailOpen = false;
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

  void dismissRuntimePanel() {
    if (!runtimePanelOpen) return;
    runtimePanelOpen = false;
    _notify();
  }

  void dismissRuntimeSetupPanel() {
    if (!runtimeSetupPanelOpen) return;
    runtimeSetupPanelOpen = false;
    _notify();
  }

  void dismissModelPanel() {
    if (!modelPanelOpen) return;
    modelPanelOpen = false;
    sessionSettingsDetailOpen = false;
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
      focus: focus,
      errorLabel: 'Window presentation degraded',
    );
  }

  Future<void> toggleLargePanel() => _transitionSurface(
    targetExpanded: true,
    targetLarge: !largePanel,
    errorLabel: 'Window resize failed',
  );

  Future<void> _transitionSurface({
    required bool targetExpanded,
    required bool targetLarge,
    required String errorLabel,
    bool focus = false,
  }) async {
    final transitionEpoch = ++_surfaceTransitionEpoch;
    final fromArea = expanded
        ? (largePanel
              ? largeWindowSize.width * largeWindowSize.height
              : normalWindowSize.width * normalWindowSize.height)
        : compactWindowSize.width * compactWindowSize.height;
    final toArea = targetExpanded
        ? (targetLarge
              ? largeWindowSize.width * largeWindowSize.height
              : normalWindowSize.width * normalWindowSize.height)
        : compactWindowSize.width * compactWindowSize.height;
    final growing = toArea >= fromArea;
    surfaceTransitioning = true;
    surfaceTransitionAnimating = false;
    transitionTargetExpanded = targetExpanded;
    transitionTargetLarge = targetLarge;
    _notify();
    try {
      final transitionClock = Stopwatch()..start();
      Future<void>? growingSurfaceChange;
      if (growing) {
        growingSurfaceChange = desktop.setSurface(
          expanded: targetExpanded,
          large: targetLarge,
          animate: false,
        );
      }
      surfaceTransitionAnimating = true;
      _notify();
      if (growingSurfaceChange != null) {
        await growingSurfaceChange;
      }
      if (transitionEpoch != _surfaceTransitionEpoch) return;
      final remaining = surfaceTransitionDuration - transitionClock.elapsed;
      if (remaining > Duration.zero) {
        await Future<void>.delayed(remaining);
      }
      if (transitionEpoch != _surfaceTransitionEpoch) return;
      if (!growing) {
        await desktop.setSurface(
          expanded: targetExpanded,
          large: targetLarge,
          animate: false,
        );
      }
    } on Object catch (error) {
      _setStatus('$errorLabel · $error', warning: true);
    } finally {
      if (transitionEpoch == _surfaceTransitionEpoch) {
        expanded = targetExpanded;
        largePanel = targetLarge;
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

  Future<void> startDragging() => desktop.startDragging();

  Future<void> copyText(String value) => desktop.copyText(value);

  Future<void> copyImage(String dataUrl) => desktop.copyImage(dataUrl);

  Future<void> openExternalLink(String value) async {
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

  SessionPresence presenceFor(String sessionId) {
    final runtimeTargetId = activeRuntime?.id;
    if (runtimeTargetId == null) return SessionPresence.done;
    final sessionKey = _sessionKey(runtimeTargetId, sessionId);
    if (_activeTurns.containsKey(sessionKey)) return SessionPresence.running;
    if (_unreadSessions.contains(sessionKey)) return SessionPresence.unread;
    if (sessionId == activeSessionId) return SessionPresence.active;
    return SessionPresence.done;
  }

  void setBlockExpanded(TranscriptBlock block, bool expanded) {
    block.expanded = expanded;
    _notify();
  }

  Future<void> _handleDesktopInvocation(DesktopInvocation invocation) async {
    if (invocation.attachment case final attachment?) {
      // The capture already happened before this event. Attach it before any
      // show/focus request so the shortcut can never capture Zommi itself.
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
    final sequenceKey = '${event.runtimeTargetId}:${event.sessionId ?? ''}';
    final previous = _lastSequences[sequenceKey] ?? 0;
    if (event.sequence > 0 && event.sequence <= previous) return;
    if (event.sequence > 0) _lastSequences[sequenceKey] = event.sequence;
    final sessionId = event.sessionId ?? activeSessionId;
    switch (event.name) {
      case 'runtime.status':
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
            }
          }
        }
        if (message?.isNotEmpty == true &&
            activeRuntime?.id == event.runtimeTargetId) {
          _setStatus(
            message!,
            warning: event.payload['status']?.toString() == 'degraded',
          );
        }
        return;
      case 'turn.started':
        if (sessionId == null) return;
        final sessionKey = _sessionKey(event.runtimeTargetId, sessionId);
        final turnId = event.turnId;
        if (turnId != null && turnId.isNotEmpty) {
          _activeTurns[sessionKey] = turnId;
        }
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
        if (sessionId == null) return;
        if (_isActiveSession(event.runtimeTargetId, sessionId)) {
          approval = PendingApproval.fromEvent(
            event.runtimeTargetId,
            sessionId,
            event.payload,
          );
        }
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
        if (turnId != null) {
          if (_completedTurnIds.length >= 512) _completedTurnIds.clear();
          _completedTurnIds.add(_turnIdentity(event.runtimeTargetId, turnId));
        }
        _activeTurns.remove(sessionKey);
        _interruptingSessions.remove(sessionKey);
        _cancelRequestedSessions.remove(sessionKey);
        if (!_isActiveSession(event.runtimeTargetId, sessionId)) {
          _unreadSessions.add(sessionKey);
        }
        final statusValue = event.payload['status']?.toString() ?? 'completed';
        for (final block in (_turnsBySession[sessionKey] ?? const []).expand(
          (turn) => turn.blocks,
        )) {
          if (block.isActivity) {
            block.lifecycle = TranscriptLifecycle.completed;
            block.expanded = false;
          }
        }
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
        number: sessionTurns.length + 1,
        userText: 'Continue',
      );
      sessionTurns.add(turn);
    }
    final kind = _transcriptKind(event.payload['kind']?.toString());
    final lifecycle = _lifecycle(event.payload['lifecycle']?.toString());
    if (kind == TranscriptKind.tool &&
        !turn.blocks.any((block) => block.kind == TranscriptKind.thinking)) {
      turn.blocks.add(
        TranscriptBlock(
          id: 'turn-thinking',
          kind: TranscriptKind.thinking,
          title: 'Thinking',
          lifecycle: lifecycle,
          expanded: false,
        ),
      );
    }
    final nativeItemId = event.payload['itemId']?.toString() ?? '';
    final blockId = kind == TranscriptKind.thinking
        ? 'turn-thinking'
        : nativeItemId.isEmpty
        ? '${kind.name}:${event.payload['title'] ?? ''}'
        : nativeItemId;
    var block = turn.block(blockId);
    if (block == null) {
      block = TranscriptBlock(
        id: blockId,
        kind: kind,
        title: event.payload['title']?.toString() ?? _kindTitle(kind),
        lifecycle: lifecycle,
        status: event.payload['status']?.toString(),
        expanded: kind == TranscriptKind.error,
      );
      turn.blocks.add(block);
    }
    block.text = mergeActivityText(
      block.text,
      event.payload['text']?.toString() ?? '',
      kind,
      lifecycle,
      replace: event.payload['replace'] == true,
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
    if (!_isActiveSession(runtimeTargetId, sessionId)) {
      _activeTurns.putIfAbsent(sessionKey, () => event.turnId ?? 'running');
    }
    _notify();
  }

  void _ensureSession(String sessionId) {
    if (sessionId.isEmpty) return;
    if (!sessions.any((session) => session.id == sessionId)) {
      sessions.insert(
        0,
        SessionSummary(id: sessionId, title: 'New $activeRuntimeName chat'),
      );
    }
    final runtimeTargetId = activeRuntime?.id;
    if (runtimeTargetId != null) {
      _turnsBySession.putIfAbsent(
        _sessionKey(runtimeTargetId, sessionId),
        () => [],
      );
    }
  }

  List<SessionSummary> _sessionSummaries(List<Map<String, Object?>> values) =>
      values
          .map(SessionSummary.fromJson)
          .where((session) => session.id.isNotEmpty)
          .toList(growable: false);

  void _updateSessionTitle(String sessionId, String message) {
    final index = sessions.indexWhere((session) => session.id == sessionId);
    final title = compactSessionTitle(message);
    if (index < 0) {
      sessions.insert(0, SessionSummary(id: sessionId, title: title));
    } else if (sessions[index].title.startsWith('New ')) {
      sessions[index] = sessions[index].copyWith(title: title);
    }
  }

  Map<String, Object?>? _selectedModel() =>
      models.cast<Map<String, Object?>?>().firstWhere(
        (model) => _modelId(model!) == selectedModel,
        orElse: () => null,
      );

  void _replaceDiscovery(RuntimeDiscovery discovery) {
    _runtimeTargetAliases.clear();
    final visible = _deduplicateRuntimeTargets(
      discovery.targets,
      aliases: _runtimeTargetAliases,
    );
    runtimeTargets
      ..clear()
      ..addAll(visible);
    runtimeSettings = discovery.settings;
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
    return detected && hasLocator;
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
    return orderedKeys
        .map((key) => selectedByKey[key]!)
        .toList(growable: false);
  }

  void _rememberActiveSessionSettings() {
    final runtimeTargetId = activeRuntime?.id;
    final sessionId = activeSessionId;
    if (runtimeTargetId == null || sessionId == null) return;
    _sessionSettings[_sessionKey(runtimeTargetId, sessionId)] =
        activeSessionSettings;
  }

  void _hydrateProfiles(RuntimeConnection connection) {
    final values = mapList(connection.sessionMetadata['profiles']);
    if (values.isNotEmpty) profiles = values;
    if (activeRuntime?.runtimeId != 'hermes') profiles = [];
  }

  void _hydrateSessionSettingsFromSummaries(String runtimeTargetId) {
    for (final session in sessions) {
      final key = _sessionKey(runtimeTargetId, session.id);
      _sessionSettings.putIfAbsent(
        key,
        () => SessionSettings(
          workspace: session.cwd ?? '',
          model: selectedModel,
          effort: selectedEffort,
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
      (session) => session?.id == sessionId,
      orElse: () => null,
    );
    return SessionSettings(
      workspace: summary?.cwd ?? selectedWorkspace,
      model: selectedModel,
      effort: selectedEffort,
      profile: summary?.profile ?? selectedProfile,
    );
  }

  void _restoreSessionSettings(RuntimeConnection connection) {
    final key = _sessionKey(connection.runtimeTargetId, connection.sessionId);
    final summary = sessions.cast<SessionSummary?>().firstWhere(
      (session) => session?.id == connection.sessionId,
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

  void _setStatus(String value, {bool warning = false}) {
    status = value;
    statusWarning = warning;
    _notify();
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
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
}) {
  if (canonical.isEmpty) return List<ConversationTurn>.of(cached);
  if (cached.isEmpty) return List<ConversationTurn>.of(canonical);
  final merged = List<ConversationTurn>.of(canonical);
  for (final cachedTurn in cached) {
    var index = merged.indexWhere((turn) => turn.id == cachedTurn.id);
    if (index < 0 && cachedTurn.id.startsWith('flutter:')) {
      index = merged.lastIndexWhere(
        (turn) => turn.userText == cachedTurn.userText,
      );
    }
    if (index < 0) {
      merged.add(cachedTurn);
    } else {
      merged[index] = preserveCached
          ? mergeConversationTurn(cachedTurn, merged[index])
          : mergeConversationTurn(merged[index], cachedTurn);
    }
  }
  return merged;
}

ConversationTurn mergeConversationTurn(
  ConversationTurn primary,
  ConversationTurn secondary,
) {
  final blocks = List<TranscriptBlock>.of(primary.blocks);
  for (final candidate in secondary.blocks) {
    if (candidate.kind == TranscriptKind.thinking) {
      // Canonical history and the live cache can use different item IDs for
      // commentary/reasoning. Keep both inputs here and consolidate them into
      // one Thinking block below instead of dropping the canonical detail.
      blocks.add(candidate);
      continue;
    }
    final duplicate = blocks.any(
      (block) =>
          block.id == candidate.id ||
          (block.kind == candidate.kind &&
              block.text.trim().isNotEmpty &&
              block.text.trim() == candidate.text.trim()),
    );
    if (!duplicate) blocks.add(candidate);
  }
  return ConversationTurn(
    id: primary.id,
    number: primary.number,
    userText: primary.userText,
    inlineUserText: primary.inlineUserText,
    contextTokens: primary.contextTokens.isEmpty
        ? secondary.contextTokens
        : primary.contextTokens,
    attachments: primary.attachments.isEmpty
        ? secondary.attachments
        : primary.attachments,
    blocks: normalizeTranscriptBlocks(blocks),
  );
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
  TranscriptKind.assistant => 'Agent',
  TranscriptKind.thinking => 'Thinking',
  TranscriptKind.plan => 'Plan',
  TranscriptKind.tool => 'Tool',
  TranscriptKind.error => 'Error',
};
