import 'dart:async';

import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/desktop/artifact_loader.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/state/zommi_models.dart';

final class RichFakeCore implements CoreBridge, RuntimeConfigurationBridge {
  final StreamController<CoreEvent> _events =
      StreamController<CoreEvent>.broadcast(sync: true);
  String activeTargetId = 'runtime-codex';
  String activeSessionId = 'session-1';
  String? lastMessage;
  String? lastModel;
  String? lastEffort;
  List<Map<String, Object?>> lastSnapshots = [];
  List<String> lastImages = [];
  (String, String, String)? interrupted;
  (String, String, String, String?)? approvalResolution;
  (String, String, String, Map<String, Object?>)? questionResolution;
  int historyCount = 45;
  bool closed = false;
  String? connectErrorCode;
  Future<void>? initializeGate;
  Future<void>? connectGate;
  Future<void>? startTurnGate;
  final Map<String, String> activeSessionsByRuntime = {};
  final Map<String, Map<String, Object?>> historyBySession = {};
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
  }) async => RuntimeDiscovery(
    targets: discoveredTargets,
    selectedTargetId: lastSelectedTargetId ?? activeTargetId,
    settings: _settings(),
  );

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
    if (connectGate case final gate?) await gate;
    if (connectErrorCode case final code?) {
      throw CoreProtocolException(code, 'Authentication required');
    }
    activeTargetId = runtimeTargetId;
    activeSessionId =
        preferredSessionId ??
        activeSessionsByRuntime[runtimeTargetId] ??
        (runtimeTargetId == 'runtime-pi' ? 'pi-session' : 'session-1');
    activeSessionsByRuntime[runtimeTargetId] = activeSessionId;
    return _connection();
  }

  RuntimeConnection _connection() => RuntimeConnection(
    runtimeTargetId: activeTargetId,
    sessionId: activeSessionId,
    protocolVersion: 1,
    runtimeVersion: '9.8.7',
    models: activeTargetId == 'runtime-claude' ? const [] : models,
    sessions: _sessions(),
    capabilities: activeTargetId == 'runtime-claude'
        ? const ['turn.stream.v1']
        : capabilities,
    sessionMetadata: const {
      'activeModel': 'fixture-pro',
      'activeEffort': 'high',
    },
  );

  List<Map<String, Object?>> _sessions() => [
    {'id': activeSessionId, 'name': 'Primary work'},
    {'id': 'session-2', 'preview': 'Secondary chat'},
    {'id': 'session-3', 'preview': 'Finished chat'},
  ];

  @override
  Future<List<Map<String, Object?>>> listSessions({
    required String runtimeTargetId,
  }) async => _sessions();

  @override
  Future<RuntimeConnection> createSession({
    required String runtimeTargetId,
    String? model,
    String? effort,
  }) async {
    activeSessionId = 'created-session';
    activeSessionsByRuntime[runtimeTargetId] = activeSessionId;
    return _connection();
  }

  @override
  Future<RuntimeConnection> openSession({
    required String runtimeTargetId,
    required String sessionId,
  }) async {
    activeSessionId = sessionId;
    activeSessionsByRuntime[runtimeTargetId] = sessionId;
    return _connection();
  }

  @override
  Future<Map<String, Object?>> readSession({
    required String runtimeTargetId,
    required String sessionId,
  }) async =>
      historyBySession['$runtimeTargetId\u0000$sessionId'] ??
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
  }) async {
    if (startTurnGate case final gate?) await gate;
    lastMessage = message;
    lastModel = model;
    lastEffort = effort;
    lastSnapshots = snapshots;
    lastImages = images;
    return TurnReceipt(
      accepted: true,
      runtimeTargetId: runtimeTargetId,
      sessionId: sessionId,
      turnId: '$sessionId-live-turn',
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

final class FakeDesktopBridge implements DesktopBridge {
  final StreamController<DesktopInvocation> _invocations =
      StreamController<DesktopInvocation>.broadcast(sync: true);
  final List<String> calls = [];
  final List<bool> surfaceAnimations = [];
  ContextAttachment? nextContext;
  ContextAttachment? nextImage;
  String? copiedText;
  String? copiedImage;
  String? nextRuntimeExecutable;
  bool closed = false;
  Future<DesktopReadiness>? initializeGate;
  Future<void>? surfaceGate;

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
  Future<ContextAttachment?> captureContext() async {
    calls.add('capture');
    return nextContext;
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
    bool animate = true,
  }) async {
    calls.add('surface:$expanded:$large');
    surfaceAnimations.add(animate);
    if (surfaceGate case final gate?) await gate;
  }

  @override
  Future<void> showPanel() async {
    calls.add('showPanel');
  }

  @override
  Future<void> hide() async {
    calls.add('hide');
  }

  @override
  Future<void> toggleMaximized() async {
    calls.add('toggleMaximized');
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
  Future<void> copyText(String value) async {
    copiedText = value;
  }

  @override
  Future<void> copyImage(String dataUrl) async {
    copiedImage = dataUrl;
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
