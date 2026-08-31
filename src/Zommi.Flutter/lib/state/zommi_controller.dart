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
  final Set<String> _completedTurnIds = {};
  final Map<String, int> _lastSequences = {};

  StreamSubscription<CoreEvent>? _coreEvents;
  StreamSubscription<DesktopInvocation>? _desktopEvents;
  RuntimeTarget? activeRuntime;
  String? activeSessionId;
  Set<String> capabilities = {};
  String selectedModel = '';
  String selectedEffort = '';
  String status = 'Connecting to Rust core…';
  bool statusWarning = false;
  bool initialized = false;
  bool runtimeBusy = false;
  bool runtimeOverrideBusy = false;
  bool sessionBusy = false;
  bool submitting = false;
  bool expanded = false;
  bool largePanel = false;
  bool sessionPanelOpen = false;
  bool runtimePanelOpen = false;
  bool modelPanelOpen = false;
  bool contextShortcutRegistered = false;
  bool imageShortcutRegistered = false;
  int focusComposerEpoch = 0;
  PendingApproval? approval;
  PendingQuestion? question;
  ContextAttachment? previewAttachment;
  ArtifactPreview? previewArtifact;
  bool resolvingPrompt = false;
  bool _closed = false;
  int _localTurnSequence = 0;

  List<ConversationTurn> get turns =>
      _turnsBySession[activeSessionId] ?? const [];

  String? get activeTurnId =>
      activeSessionId == null ? null : _activeTurns[activeSessionId];

  bool get turnActive => activeTurnId != null;

  bool get anyTurnActive => _activeTurns.isNotEmpty;

  bool get imageInputSupported =>
      activeRuntime == null || capabilities.contains('input.image.v1');

  bool get sessionNavigationSupported =>
      capabilities.contains('session.list.v1') ||
      capabilities.contains('session.resume.v1');

  bool get sessionCreationSupported =>
      capabilities.contains('session.create.v1');

  bool get modelSelectionSupported =>
      capabilities.contains('model.select.v1') && models.isNotEmpty;

  bool get runtimeOverridesSupported => core is RuntimeConfigurationBridge;

  List<Map<String, Object?>> get runtimeOverrideAdapters =>
      mapList(runtimeSettings['adapters']);

  List<Map<String, Object?>> get runtimeOverrideHosts =>
      mapList(runtimeSettings['hosts']);

  List<Map<String, Object?>> get runtimeOverrides =>
      mapList(runtimeSettings['overrides']);

  String get activeRuntimeName => activeRuntime?.displayName ?? 'Agent';

  String get runtimeSummary {
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
      runtimeTargets
        ..clear()
        ..addAll(discovery.targets);
      runtimeSettings = discovery.settings;
      final targetId = discovery.selectedTargetId;
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
      _setStatus('Rust core unavailable · $error', warning: true);
    } finally {
      await desktopInitialization;
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
      );
      runtimeTargets
        ..clear()
        ..addAll(discovery.targets);
      runtimeSettings = discovery.settings;
      final selected = discovery.selectedTargetId;
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
    if (runtimeBusy || activeRuntime?.id == targetId) {
      closeTransientPanels();
      return;
    }
    runtimeBusy = true;
    approval = null;
    question = null;
    previewArtifact = null;
    _setStatus('Switching agent runtime…');
    try {
      await _connectRuntime(targetId);
      closeTransientPanels();
    } on Object catch (error) {
      if (!_applyConnectionError(targetId, error)) {
        _setStatus('Could not switch agent · $error', warning: true);
      }
    } finally {
      runtimeBusy = false;
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
      runtimeTargets
        ..clear()
        ..addAll(discovery.targets);
      runtimeSettings = discovery.settings;
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
      runtimeTargets
        ..clear()
        ..addAll(discovery.targets);
      runtimeSettings = discovery.settings;
      _setStatus('Runtime override removed');
    } on Object catch (error) {
      _setStatus('Could not remove runtime override · $error', warning: true);
    } finally {
      runtimeOverrideBusy = false;
      _notify();
    }
  }

  Future<void> _connectRuntime(String targetId, {String? coreVersion}) async {
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
    models
      ..clear()
      ..addAll(connection.models);
    sessions
      ..clear()
      ..addAll(_sessionSummaries(connection.sessions));
    _ensureSession(connection.sessionId);
    _selectInitialModel(connection);
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
    await _readActiveHistory();
    final version = connection.runtimeVersion ?? coreVersion;
    _setStatus('$activeRuntimeName${version == null ? '' : ' $version'} ready');
  }

  void _selectInitialModel(RuntimeConnection connection) {
    selectedModel =
        connection.sessionMetadata['activeModel']?.toString() ??
        connection.sessionMetadata['model']?.toString() ??
        _defaultModelId();
    final model = _selectedModel();
    final efforts = effortsForModel(model);
    selectedEffort =
        connection.sessionMetadata['activeEffort']?.toString() ??
        connection.sessionMetadata['effort']?.toString() ??
        model?['defaultReasoningEffort']?.toString() ??
        (efforts.isEmpty ? '' : efforts.first);
    if (efforts.isNotEmpty && !efforts.contains(selectedEffort)) {
      selectedEffort =
          model?['defaultReasoningEffort']?.toString() ?? efforts.first;
    }
  }

  Future<void> _readActiveHistory() async {
    final runtimeTargetId = activeRuntime?.id;
    final sessionId = activeSessionId;
    if (runtimeTargetId == null || sessionId == null) return;
    if (!capabilities.contains('history.read.v1')) {
      _turnsBySession.putIfAbsent(sessionId, () => []);
      return;
    }
    try {
      final response = await core.readSession(
        runtimeTargetId: runtimeTargetId,
        sessionId: sessionId,
      );
      _turnsBySession[sessionId] = mapThreadHistory(response);
    } on Object catch (error) {
      _turnsBySession.putIfAbsent(sessionId, () => []);
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
      final connection = await core.createSession(
        runtimeTargetId: runtimeTargetId,
        model: selectedModel.isEmpty ? null : selectedModel,
        effort: selectedEffort.isEmpty ? null : selectedEffort,
      );
      await _applySessionConnection(connection);
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
    _notify();
    try {
      final connection = await core.openSession(
        runtimeTargetId: runtimeTargetId,
        sessionId: sessionId,
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

  Future<void> _applySessionConnection(RuntimeConnection connection) async {
    activeSessionId = connection.sessionId;
    _unreadSessions.remove(connection.sessionId);
    capabilities = {...capabilities, ...connection.capabilities};
    if (connection.models.isNotEmpty) {
      models
        ..clear()
        ..addAll(connection.models);
    }
    if (connection.sessions.isNotEmpty) {
      sessions
        ..clear()
        ..addAll(_sessionSummaries(connection.sessions));
    }
    _ensureSession(connection.sessionId);
    _selectInitialModel(connection);
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
    if (_activeTurns.containsKey(sessionId)) return;
    final sendingAttachments = _orderedAttachments(attachmentOrder);
    attachments.clear();
    previewAttachment = null;
    final operationId =
        'flutter:${DateTime.now().microsecondsSinceEpoch}:${++_localTurnSequence}';
    final localTurn = ConversationTurn(
      id: operationId,
      number: (_turnsBySession[sessionId]?.length ?? 0) + 1,
      userText: text,
      inlineUserText: inlineMessage,
      contextTokens: sendingAttachments
          .where((item) => !item.hasImage)
          .map((item) => item.token)
          .toList(),
      attachments: sendingAttachments,
    );
    _turnsBySession.putIfAbsent(sessionId, () => []).add(localTurn);
    _activeTurns[sessionId] = operationId;
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
      );
      if (!_completedTurnIds.contains(receipt.turnId)) {
        _activeTurns[sessionId] = receipt.turnId;
        _setStatus('$activeRuntimeName is responding…');
      }
    } on Object catch (error) {
      _activeTurns.remove(sessionId);
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
    _setStatus('Stopping $activeRuntimeName turn…');
    try {
      await core.interruptTurn(
        runtimeTargetId: target,
        sessionId: session,
        turnId: turn,
      );
    } on Object catch (error) {
      _setStatus('Stop failed · $error', warning: true);
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
    _notify();
  }

  void setEffort(String value) {
    selectedEffort = value;
    _notify();
  }

  List<String> get selectedModelEfforts => effortsForModel(_selectedModel());

  void toggleSessionPanel([bool? open]) {
    sessionPanelOpen = open ?? !sessionPanelOpen;
    if (sessionPanelOpen) {
      runtimePanelOpen = false;
      modelPanelOpen = false;
    }
    _notify();
  }

  void toggleRuntimePanel() {
    runtimePanelOpen = !runtimePanelOpen;
    if (runtimePanelOpen) {
      sessionPanelOpen = false;
      modelPanelOpen = false;
    }
    _notify();
  }

  void toggleModelPanel() {
    modelPanelOpen = !modelPanelOpen;
    if (modelPanelOpen) {
      sessionPanelOpen = false;
      runtimePanelOpen = false;
    }
    _notify();
  }

  void closeTransientPanels() {
    sessionPanelOpen = false;
    runtimePanelOpen = false;
    modelPanelOpen = false;
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

  void dismissModelPanel() {
    if (!modelPanelOpen) return;
    modelPanelOpen = false;
    _notify();
  }

  Future<void> setExpanded(bool value, {bool focus = false}) async {
    expanded = value;
    if (value && focus) focusComposerEpoch++;
    _notify();
    try {
      await desktop.setSurface(expanded: value, large: largePanel);
      if (value && focus) await desktop.showPanel();
    } on Object catch (error) {
      _setStatus('Window presentation degraded · $error', warning: true);
    }
  }

  Future<void> toggleLargePanel() async {
    largePanel = !largePanel;
    _notify();
    try {
      await desktop.setSurface(expanded: true, large: largePanel);
    } on Object catch (error) {
      _setStatus('Window resize failed · $error', warning: true);
    }
  }

  Future<void> hideWindow() => desktop.hide();

  Future<void> startDragging() => desktop.startDragging();

  Future<void> copyText(String value) => desktop.copyText(value);

  Future<void> copyImage(String dataUrl) => desktop.copyImage(dataUrl);

  SessionPresence presenceFor(String sessionId) {
    if (_activeTurns.containsKey(sessionId)) return SessionPresence.running;
    if (_unreadSessions.contains(sessionId)) return SessionPresence.unread;
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
    if (_closed || activeRuntime?.id != event.runtimeTargetId) return;
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
        if (message?.isNotEmpty == true) {
          _setStatus(
            message!,
            warning: event.payload['status']?.toString() == 'degraded',
          );
        }
        return;
      case 'turn.started':
        if (sessionId == null) return;
        final turnId = event.turnId;
        if (turnId != null && turnId.isNotEmpty) {
          _activeTurns[sessionId] = turnId;
        }
        _setStatus('$activeRuntimeName is responding…');
        _notify();
        return;
      case 'item.update':
        if (sessionId == null) return;
        _applyItemUpdate(sessionId, event);
        return;
      case 'approval.requested':
        if (sessionId == null) return;
        approval = PendingApproval.fromEvent(
          event.runtimeTargetId,
          sessionId,
          event.payload,
        );
        _notify();
        return;
      case 'question.requested':
        if (sessionId == null) return;
        question = PendingQuestion.fromEvent(
          event.runtimeTargetId,
          sessionId,
          event.payload,
        );
        _notify();
        return;
      case 'turn.completed':
        if (sessionId == null) return;
        final turnId = event.turnId;
        if (turnId != null) {
          if (_completedTurnIds.length >= 512) _completedTurnIds.clear();
          _completedTurnIds.add(turnId);
        }
        _activeTurns.remove(sessionId);
        if (sessionId != activeSessionId) _unreadSessions.add(sessionId);
        final statusValue = event.payload['status']?.toString() ?? 'completed';
        if (sessionId == activeSessionId) {
          for (final block in turns.expand((turn) => turn.blocks)) {
            if (block.isActivity) {
              block.lifecycle = TranscriptLifecycle.completed;
              block.expanded = false;
            }
          }
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

  void _applyItemUpdate(String sessionId, CoreEvent event) {
    final sessionTurns = _turnsBySession.putIfAbsent(sessionId, () => []);
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
        sessionId == activeSessionId &&
        sessionTurns.isNotEmpty &&
        sessionTurns.last.id.startsWith('flutter:') &&
        _activeTurns.containsKey(sessionId)) {
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
        expanded:
            kind != TranscriptKind.assistant &&
            lifecycle != TranscriptLifecycle.completed,
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
    for (final artifactValue in mapList(event.payload['artifacts'])) {
      final artifact = ArtifactPreview.fromJson(artifactValue);
      if (!block.artifacts.any(
        (existing) => existing.identity == artifact.identity,
      )) {
        block.artifacts.add(artifact);
      }
    }
    if (sessionId != activeSessionId) {
      _activeTurns.putIfAbsent(sessionId, () => event.turnId ?? 'running');
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
    _turnsBySession.putIfAbsent(sessionId, () => []);
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
