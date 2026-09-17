import 'dart:async';

import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/desktop/artifact_loader.dart';
import 'package:zommi_flutter/desktop/capture_permissions.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/state/zommi_models.dart';

class RichFakeCore
    implements
        CoreBridge,
        RuntimeConfigurationBridge,
        SessionCatalogBridge,
        GoalControlBridge {
  final Map<String, Map<String, Object?>> goals = {};
  final List<Map<String, Object?>> goalCommands = [];
  bool goalCommandFails = false;

  @override
  Future<Map<String, Object?>> goalCommand({
    required String runtimeTargetId,
    required String sessionId,
    required String action,
    String? objective,
    String? model,
    String? effort,
    String? cwd,
  }) async {
    goalCommands.add({
      'sessionId': sessionId,
      'action': action,
      'objective': ?objective,
      'model': ?model,
      'effort': ?effort,
      'cwd': ?cwd,
    });
    if (goalCommandFails) {
      throw const CoreProtocolException(
        'unsupported-method',
        'Goals are unavailable.',
      );
    }
    if (action == 'clear') goals.remove(sessionId);
    if (action == 'set') {
      goals[sessionId] = {
        'threadId': sessionId,
        'objective': objective!,
        'status': 'active',
        'tokensUsed': 0,
        'timeUsedSeconds': 0,
      };
    }
    if (action == 'pause' || action == 'resume') {
      final goal = goals[sessionId];
      if (goal == null) {
        throw const CoreProtocolException('missing-goal', 'No goal set.');
      }
      goal['status'] = action == 'pause' ? 'paused' : 'active';
    }
    return {
      'goal': goals[sessionId] == null ? null : {...goals[sessionId]!},
    };
  }

  final StreamController<CoreEvent> _events =
      StreamController<CoreEvent>.broadcast(sync: true);
  String activeTargetId = 'runtime-codex';
  String activeSessionId = 'session-1';
  String? lastMessage;
  String? lastModel;
  String? lastEffort;
  String? lastCwd;
  String? lastProfile;
  List<Map<String, Object?>> lastSnapshots = [];
  List<String> lastImages = [];
  (String, String, String)? interrupted;
  (String, String, String, String?)? approvalResolution;
  (String, String, String, Map<String, Object?>)? questionResolution;
  int historyCount = 45;
  bool closed = false;
  int connectCount = 0;
  String? connectErrorCode;
  String connectErrorMessage = 'Authentication required';
  bool? lastDiscoveryForce;
  Future<void>? discoveryGate;
  bool discoveryFails = false;
  int discoveryCount = 0;
  Future<void>? initializeGate;
  Future<void>? connectGate;
  Future<void>? startTurnGate;
  bool uniqueTurnIds = false;
  bool startTurnFails = false;
  Object? startTurnError;
  bool startTurnAccepted = true;
  final List<Map<String, Object?>> startedTurns = [];
  Future<void>? createSessionGate;
  Future<void>? openSessionGate;
  Future<void>? readSessionGate;
  int readSessionCount = 0;
  bool createSessionFails = false;
  bool openSessionFails = false;
  final List<Map<String, Object?>> createdSessions = [];
  final List<(String, String)> openedSessions = [];
  final Set<String> missingWorkspaces = {};
  final Map<String, String> activeSessionsByRuntime = {};
  final Map<String, String> activeProfilesByRuntime = {};
  final Map<String, Map<String, Object?>> historyBySession = {};
  final Map<String, Map<String, Object?>> openHistoryBySession = {};
  final Map<String, List<Map<String, Object?>>> modelCatalogByRuntime = {};
  final Map<String, List<Map<String, Object?>>> sessionsByRuntime = {};
  final List<String> catalogRequests = [];
  final Map<String, Future<void>> catalogGates = {};
  final Set<String> catalogFailures = {};
  final List<Map<String, Object?>> configuredOverrides = [
    {
      'id': 'override-existing',
      'adapterId': 'codex-app-server',
      'executionHost': {
        'id': 'native:linux',
        'kind': 'native',
        'platform': 'linux',
        'displayName': 'Linux',
        'isDefault': true,
      },
      'executablePath': '/opt/codex',
    },
  ];

  static const capabilities = [
    'session.list.v1',
    'session.create.v1',
    'session.resume.v1',
    'history.read.v1',
    'turn.stream.v1',
    'turn.interrupt.v1',
    'input.image.v1',
    'model.select.v1',
    'reasoning.select.v1',
    'approval.resolve.v1',
    'question.resolve.v1',
  ];

  static const targets = [
    RuntimeTarget(
      id: 'runtime-codex',
      runtimeId: 'codex',
      adapterId: 'codex-app-server',
      displayName: 'Codex',
      protocolName: 'Codex app-server',
      executablePath: '/usr/bin/codex',
      executionHost: {
        'id': 'native:linux',
        'kind': 'native',
        'displayName': 'Linux',
      },
      capabilityHints: capabilities,
    ),
    RuntimeTarget(
      id: 'runtime-pi',
      runtimeId: 'pi',
      adapterId: 'pi-rpc',
      displayName: 'Pi',
      protocolName: 'Pi RPC',
      executablePath: '/usr/bin/pi',
      executionHost: {
        'id': 'wsl:ubuntu',
        'kind': 'wsl',
        'name': 'Ubuntu',
        'displayName': 'WSL · Ubuntu',
      },
      capabilityHints: capabilities,
    ),
    RuntimeTarget(
      id: 'runtime-claude',
      runtimeId: 'claude',
      adapterId: 'pty-compatibility',
      displayName: 'Claude CLI',
      protocolName: 'Terminal compatibility',
      executablePath: '/usr/bin/claude',
      executionHost: {
        'id': 'native:linux',
        'kind': 'native',
        'displayName': 'Linux',
      },
      capabilityHints: ['turn.stream.v1'],
    ),
  ];
  late final List<RuntimeTarget> discoveredTargets = [...targets];

  static const models = [
    {
      'model': 'fixture-pro',
      'displayName': 'Fixture Pro',
      'description': 'Frontier coding model',
      'isDefault': true,
      'defaultReasoningEffort': 'high',
      'supportedReasoningEfforts': ['low', 'medium', 'high', 'xhigh'],
    },
    {
      'model': 'fixture-mini',
      'displayName': 'Fixture Mini',
      'description': 'Fast agent model',
      'supportedReasoningEfforts': ['low', 'medium'],
    },
  ];

  @override
  Stream<CoreEvent> get events => _events.stream;

  void emit(CoreEvent event) => _events.add(event);

  @override
  Future<CoreStatus> initialize() async {
    if (initializeGate case final gate?) await gate;
    return const CoreStatus(
      version: '0.1.0',
      protocolVersion: coreProtocolVersion,
      capabilities: ['runtime.adapters.v1'],
    );
  }

  @override
  Future<RuntimeDiscovery> discoverRuntimeTargets({
    String? lastSelectedTargetId,
    bool force = false,
  }) async {
    lastDiscoveryForce = force;
    discoveryCount++;
    if (discoveryGate case final gate?) await gate;
    if (discoveryFails) throw StateError('Discovery unavailable');
    return RuntimeDiscovery(
      targets: discoveredTargets,
      selectedTargetId: lastSelectedTargetId ?? activeTargetId,
      settings: _settings(),
    );
  }

  Map<String, Object?> _settings() => {
    'adapters': const [
      {
        'adapterId': 'codex-app-server',
        'displayName': 'Codex',
        'protocolName': 'Codex app-server',
        'acceptsEndpoint': false,
        'hostKinds': ['native', 'wsl'],
      },
      {
        'adapterId': 'openclaw-gateway',
        'displayName': 'OpenClaw',
        'protocolName': 'Direct Gateway',
        'acceptsEndpoint': true,
        'hostKinds': ['remote'],
      },
    ],
    'hosts': const [
      {
        'id': 'native:linux',
        'kind': 'native',
        'platform': 'linux',
        'displayName': 'Linux',
        'isDefault': true,
      },
      {
        'id': 'wsl:ubuntu',
        'kind': 'wsl',
        'platform': 'linux',
        'displayName': 'WSL · Ubuntu',
        'name': 'Ubuntu',
        'isDefault': false,
      },
    ],
    'overrides': configuredOverrides,
  };

  @override
  Future<RuntimeDiscovery> addRuntimeOverride(
    Map<String, Object?> override,
  ) async {
    configuredOverrides.add({...override, 'id': 'override-added'});
    return RuntimeDiscovery(
      targets: discoveredTargets,
      selectedTargetId: activeTargetId,
      settings: _settings(),
    );
  }

  @override
  Future<RuntimeDiscovery> removeRuntimeOverride(String overrideId) async {
    configuredOverrides.removeWhere((value) => value['id'] == overrideId);
    return RuntimeDiscovery(
      targets: discoveredTargets,
      selectedTargetId: activeTargetId,
      settings: _settings(),
    );
  }

  @override
  Future<RuntimeConnection> connectRuntime({
    required String runtimeTargetId,
    String? preferredSessionId,
    String? cwd,
  }) async {
    connectCount++;
    if (connectGate case final gate?) await gate;
    if (connectErrorCode case final code?) {
      throw CoreProtocolException(code, connectErrorMessage);
    }
    activeTargetId = runtimeTargetId;
    activeSessionId =
        preferredSessionId ??
        activeSessionsByRuntime[runtimeTargetId] ??
        (runtimeTargetId == 'runtime-pi' ? 'pi-session' : 'session-1');
    activeSessionsByRuntime[runtimeTargetId] = activeSessionId;
    return _connection();
  }

  RuntimeConnection _connection({Map<String, Object?>? history}) =>
      RuntimeConnection(
        runtimeTargetId: activeTargetId,
        sessionId: activeSessionId,
        protocolVersion: 1,
        runtimeVersion: '9.8.7',
        history: history,
        models:
            modelCatalogByRuntime[activeTargetId] ??
            (activeTargetId == 'runtime-claude' ? const [] : models),
        sessions: _sessions(),
        capabilities: activeTargetId == 'runtime-claude'
            ? const ['turn.stream.v1']
            : capabilities,
        sessionMetadata: activeTargetId == 'runtime-hermes'
            ? const {
                'activeModel': 'fixture-pro',
                'activeEffort': 'high',
                'cwd': '/workspace/hermes',
                'profile': 'default',
                'profiles': [
                  {'name': 'default', 'model': 'fixture-pro'},
                  {
                    'name': 'coder',
                    'model': 'fixture-pro',
                    'description': 'Coding profile',
                  },
                ],
              }
            : const {'activeModel': 'fixture-pro', 'activeEffort': 'high'},
      );

  List<Map<String, Object?>> _sessions() =>
      sessionsByRuntime[activeTargetId] ??
      [
        {'id': activeSessionId, 'name': 'Primary work'},
        {'id': 'session-2', 'preview': 'Secondary chat'},
        {'id': 'session-3', 'preview': 'Finished chat'},
      ];

  @override
  Future<List<Map<String, Object?>>> listSessions({
    required String runtimeTargetId,
  }) async => _sessions();

  @override
  Future<List<Map<String, Object?>>> listSessionCatalog({
    required String runtimeTargetId,
  }) async {
    catalogRequests.add(runtimeTargetId);
    if (catalogGates[runtimeTargetId] case final gate?) await gate;
    if (catalogFailures.contains(runtimeTargetId)) {
      throw const CoreProtocolException(
        'runtime-unavailable',
        'Agent unavailable',
      );
    }
    return sessionsByRuntime[runtimeTargetId] ?? const [];
  }

  @override
  Future<RuntimeConnection> createSession({
    required String runtimeTargetId,
    String? model,
    String? effort,
    String? cwd,
    String? profile,
  }) async {
    createdSessions.add({
      'runtimeTargetId': runtimeTargetId,
      'model': model,
      'effort': effort,
      'cwd': cwd,
      'profile': profile,
    });
    if (createSessionGate case final gate?) await gate;
    if (createSessionFails) {
      throw const CoreProtocolException(
        'runtime-unavailable',
        'Agent unavailable',
      );
    }
    activeTargetId = runtimeTargetId;
    activeSessionId = 'created-session';
    activeSessionsByRuntime[runtimeTargetId] = activeSessionId;
    return _connection();
  }

  @override
  Future<RuntimeConnection> openSession({
    required String runtimeTargetId,
    required String sessionId,
    String? cwd,
    String? profile,
  }) async {
    openedSessions.add((runtimeTargetId, sessionId));
    if (openSessionGate case final gate?) await gate;
    if (openSessionFails) {
      throw const CoreProtocolException(
        'session-unavailable',
        'Chat unavailable',
      );
    }
    activeTargetId = runtimeTargetId;
    activeSessionId = sessionId;
    activeSessionsByRuntime[runtimeTargetId] = sessionId;
    return _connection(
      history: openHistoryBySession['$runtimeTargetId\u0000$sessionId'],
    );
  }

  @override
  Future<RuntimeConnection> configureSession({
    required String runtimeTargetId,
    required String sessionId,
    String? cwd,
    String? profile,
    String? model,
    String? effort,
  }) async {
    lastCwd = cwd;
    lastProfile = profile;
    lastModel = model;
    lastEffort = effort;
    if (cwd != null && missingWorkspaces.contains(cwd)) {
      throw const CoreProtocolException(
        'workspace-not-found',
        'Workspace folder does not exist.',
      );
    }
    if (activeTargetId == 'runtime-hermes' &&
        profile != null &&
        profile.isNotEmpty &&
        profile != (activeProfilesByRuntime[runtimeTargetId] ?? 'default')) {
      activeProfilesByRuntime[runtimeTargetId] = profile;
      activeSessionId = 'hermes-$profile-session';
      activeSessionsByRuntime[runtimeTargetId] = activeSessionId;
    }
    return _connection();
  }

  @override
  Future<Map<String, Object?>> readSession({
    required String runtimeTargetId,
    required String sessionId,
  }) async {
    readSessionCount++;
    if (readSessionGate case final gate?) await gate;
    return historyBySession['$runtimeTargetId\u0000$sessionId'] ??
        {
          'thread': {
            'id': sessionId,
            'cwd': '/workspace',
            'turns': [
              for (var index = 1; index <= historyCount; index++)
                {
                  'id': '$sessionId-turn-$index',
                  'items': [
                    {
                      'type': 'userMessage',
                      'content': [
                        {'type': 'text', 'text': 'history user $index'},
                      ],
                    },
                    {
                      'id': '$sessionId-answer-$index',
                      'type': 'agentMessage',
                      'text': 'history answer $index',
                      'status': 'completed',
                    },
                  ],
                },
            ],
          },
        };
  }

  @override
  Future<TurnReceipt> startTurn({
    required String runtimeTargetId,
    required String sessionId,
    required String message,
    List<Map<String, Object?>> snapshots = const [],
    List<String> images = const [],
    String? clientOperationId,
    String? model,
    String? effort,
    String? cwd,
    String? profile,
  }) async {
    final turnId = uniqueTurnIds
        ? '$sessionId-live-turn-${startedTurns.length + 1}'
        : '$sessionId-live-turn';
    startedTurns.add({
      'runtimeTargetId': runtimeTargetId,
      'sessionId': sessionId,
      'message': message,
      'turnId': turnId,
      'clientOperationId': clientOperationId,
      'snapshots': snapshots,
      'images': images,
      'model': model,
      'effort': effort,
      'cwd': cwd,
      'profile': profile,
    });
    if (startTurnGate case final gate?) await gate;
    if (startTurnError case final error?) throw error;
    if (startTurnFails) throw StateError('Start failed');
    lastMessage = message;
    lastModel = model;
    lastEffort = effort;
    lastCwd = cwd;
    lastProfile = profile;
    lastSnapshots = snapshots;
    lastImages = images;
    return TurnReceipt(
      accepted: startTurnAccepted,
      runtimeTargetId: runtimeTargetId,
      sessionId: sessionId,
      turnId: turnId,
      clientOperationId: clientOperationId ?? 'client:test',
    );
  }

  @override
  Future<void> interruptTurn({
    required String runtimeTargetId,
    required String sessionId,
    required String turnId,
  }) async {
    interrupted = (runtimeTargetId, sessionId, turnId);
  }

  @override
  Future<void> steerTurn({
    required String runtimeTargetId,
    required String sessionId,
    required String turnId,
    required String message,
    List<String> images = const [],
  }) async {}

  @override
  Future<void> resolveApproval({
    required String runtimeTargetId,
    required String sessionId,
    required String approvalId,
    String? optionId,
  }) async {
    approvalResolution = (runtimeTargetId, sessionId, approvalId, optionId);
  }

  @override
  Future<void> resolveQuestion({
    required String runtimeTargetId,
    required String sessionId,
    required String questionId,
    required Map<String, Object?> answer,
  }) async {
    questionResolution = (runtimeTargetId, sessionId, questionId, answer);
  }

  @override
  Future<String> buildContextHandoff({
    required String message,
    List<Map<String, Object?>> snapshots = const [],
    int imageCount = 0,
  }) async => 'prepared handoff';

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _events.close();
  }
}

final class FakeDesktopBridge
    implements DesktopBridge, BrowserCaptureSettings, CapturePermissionBridge {
  @override
  bool supportsCapturePermissions = false;
  final List<String> permissionRequests = [];
  bool grantPermissionOnRequest = true;
  CapturePermissionStatus permissionStatus = const CapturePermissionStatus(
    accessibility: false,
    screenRecording: false,
  );
  @override
  Future<CapturePermissionStatus> capturePermissions() async =>
      permissionStatus;
  @override
  Future<CapturePermissionStatus> requestCapturePermission(
    CapturePermission permission,
  ) async {
    permissionRequests.add(permission.name);
    if (grantPermissionOnRequest) {
      permissionStatus = CapturePermissionStatus(
        accessibility:
            permissionStatus.accessibility ||
            permission == CapturePermission.accessibility,
        screenRecording:
            permissionStatus.screenRecording ||
            permission == CapturePermission.screenRecording,
      );
    }
    return permissionStatus;
  }

  @override
  bool supportsBrowserPageDetails = false;
  bool browserPageDetails = true;
  @override
  void setBrowserPageDetails(bool enabled) => browserPageDetails = enabled;
  final StreamController<DesktopInvocation> _invocations =
      StreamController<DesktopInvocation>.broadcast(sync: true);
  final List<String> calls = [];
  final List<bool> surfaceAnimations = [];
  ContextAttachment? nextContext;
  List<ContextAttachment>? nextSelections;
  ContextAttachment? nextImage;
  String? copiedText;
  String? copiedImage;
  Uri? openedUrl;
  String? nextRuntimeExecutable;
  String? nextWorkspaceDirectory;
  bool closed = false;
  Future<DesktopReadiness>? initializeGate;
  Future<void>? surfaceGate;
  bool maximized = false;
  Future<ContextAttachment?>? selectionGate;
  bool pointerWithinSurface = false;

  @override
  Stream<DesktopInvocation> get invocations => _invocations.stream;

  void emit(DesktopInvocation value) => _invocations.add(value);

  @override
  Future<DesktopReadiness> initialize() async {
    calls.add('initialize');
    if (initializeGate case final gate?) return gate;
    return const DesktopReadiness(contextShortcut: true, imageShortcut: true);
  }

  @override
  Future<ContextAttachment?> captureContext({bool hidePanel = false}) async {
    calls.add('capture:$hidePanel');
    return nextContext;
  }

  @override
  Future<List<ContextAttachment>> selectPointerContext() async {
    calls.add('selectPointerContext');
    if (nextSelections case final selected?) return selected;
    final selected = await (selectionGate ?? Future.value(nextContext));
    return selected == null ? [] : [selected];
  }

  @override
  Future<ContextAttachment?> selectImageContext({
    bool includePointerContext = false,
  }) async {
    calls.add('selectImage:$includePointerContext');
    return nextImage;
  }

  @override
  Future<void> setSurface({
    required bool expanded,
    bool large = false,
    bool maximized = false,
    bool animate = true,
  }) async {
    calls.add('surface:$expanded:$large');
    if (maximized) calls.add('maximize');
    surfaceAnimations.add(animate);
    if (surfaceGate case final gate?) await gate;
    this.maximized = maximized;
  }

  @override
  Future<bool> isPointerWithinSurface() async {
    calls.add('isPointerWithinSurface');
    return pointerWithinSurface;
  }

  @override
  Future<void> showPanel({bool focus = true}) async {
    calls.add(focus ? 'showPanel' : 'showPanelInactive');
  }

  @override
  Future<void> hide() async {
    calls.add('hide');
  }

  @override
  Future<void> closeWindow() async {
    calls.add('closeWindow');
  }

  @override
  Future<bool> toggleMaximized() async {
    calls.add('toggleMaximized');
    if (surfaceGate case final gate?) await gate;
    return maximized = !maximized;
  }

  @override
  Future<void> startDragging() async {
    calls.add('startDragging');
  }

  @override
  Future<void> openRuntimeSignIn(RuntimeTarget target) async {
    calls.add('signIn:${target.id}');
  }

  @override
  Future<String?> selectRuntimeExecutable() async {
    calls.add('selectRuntimeExecutable');
    return nextRuntimeExecutable;
  }

  @override
  Future<String?> selectWorkspaceDirectory() async {
    calls.add('selectWorkspaceDirectory');
    return nextWorkspaceDirectory;
  }

  @override
  Future<void> copyText(String value) async {
    copiedText = value;
  }

  @override
  Future<void> copyImage(String dataUrl) async {
    copiedImage = dataUrl;
  }

  @override
  Future<void> openExternalUrl(Uri uri) async {
    openedUrl = uri;
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _invocations.close();
  }
}

final class FakeArtifactLoader implements ArtifactLoader {
  @override
  Future<ArtifactPreview> load(
    ArtifactPreview artifact, {
    RuntimeTarget? target,
  }) async {
    if (artifact.kind == 'html') {
      return artifact.copyWith(html: '<h1>ZOMMI_HTML_PREVIEW</h1>');
    }
    return artifact;
  }
}
