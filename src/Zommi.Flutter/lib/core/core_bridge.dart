import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:zommi_flutter/core/runtime_environment.dart';

const int coreProtocolVersion = 1;

abstract interface class CoreBridge {
  Stream<CoreEvent> get events;

  Future<CoreStatus> initialize();

  Future<RuntimeDiscovery> discoverRuntimeTargets({
    String? lastSelectedTargetId,
    bool force = false,
  });

  Future<RuntimeConnection> connectRuntime({
    required String runtimeTargetId,
    String? preferredSessionId,
    String? cwd,
  });

  Future<List<Map<String, Object?>>> listSessions({
    required String runtimeTargetId,
  });

  Future<RuntimeConnection> createSession({
    required String runtimeTargetId,
    String? model,
    String? effort,
    String? cwd,
    String? profile,
  });

  Future<RuntimeConnection> openSession({
    required String runtimeTargetId,
    required String sessionId,
    String? cwd,
    String? profile,
  });

  Future<RuntimeConnection> configureSession({
    required String runtimeTargetId,
    required String sessionId,
    String? cwd,
    String? profile,
    String? model,
    String? effort,
  });

  Future<Map<String, Object?>> readSession({
    required String runtimeTargetId,
    required String sessionId,
  });

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
  });

  Future<void> interruptTurn({
    required String runtimeTargetId,
    required String sessionId,
    required String turnId,
  });

  Future<void> steerTurn({
    required String runtimeTargetId,
    required String sessionId,
    required String turnId,
    required String message,
    List<String> images = const [],
  });

  Future<void> resolveApproval({
    required String runtimeTargetId,
    required String sessionId,
    required String approvalId,
    String? optionId,
  });

  Future<void> resolveQuestion({
    required String runtimeTargetId,
    required String sessionId,
    required String questionId,
    required Map<String, Object?> answer,
  });

  Future<String> buildContextHandoff({
    required String message,
    List<Map<String, Object?>> snapshots = const [],
    int imageCount = 0,
  });

  Future<void> close();
}

abstract interface class RuntimeConfigurationBridge {
  Future<RuntimeDiscovery> addRuntimeOverride(Map<String, Object?> override);

  Future<RuntimeDiscovery> removeRuntimeOverride(String overrideId);
}

abstract interface class SessionForkBridge {
  Future<RuntimeConnection> forkSession({
    required String runtimeTargetId,
    required String sessionId,
  });
}

abstract interface class SessionRewindBridge {
  Future<Map<String, Object?>> prepareSessionRewind({
    required String runtimeTargetId,
    required String sessionId,
  });

  Future<Map<String, Object?>> rewindSession({
    required String runtimeTargetId,
    required String sessionId,
    required String turnId,
    required String expectedLastTurnId,
  });
}

abstract interface class SessionCatalogBridge {
  /// Lists stored chats without creating, resuming, or selecting a session.
  Future<List<Map<String, Object?>>> listSessionCatalog({
    required String runtimeTargetId,
  });
}

abstract interface class RuntimeCommandBridge {
  Future<Map<String, Object?>> listCommands({
    required String runtimeTargetId,
    required String sessionId,
    bool force = false,
  });
  Future<TurnReceipt> startCommand({
    required String runtimeTargetId,
    required String sessionId,
    required String message,
    required String clientOperationId,
    String? model,
    String? effort,
    String? cwd,
    String? profile,
  });
}

abstract interface class RuntimePreparationBridge {
  /// Prepare a runtime transport without selecting or creating a chat.
  Future<void> prepareRuntime({required String runtimeTargetId});
}

abstract interface class SessionStatusBridge {
  Future<Map<String, Object?>> sessionStatus({
    required String runtimeTargetId,
    required String sessionId,
  });
}

abstract interface class GoalControlBridge {
  Future<Map<String, Object?>> goalCommand({
    required String runtimeTargetId,
    required String sessionId,
    required String action,
    String? objective,
    String? model,
    String? effort,
    String? cwd,
  });
}

final class RuntimeTarget {
  const RuntimeTarget({
    required this.id,
    required this.runtimeId,
    required this.adapterId,
    required this.displayName,
    required this.protocolName,
    required this.executablePath,
    required this.executionHost,
    this.status = 'detected',
    this.priority = 0,
    this.capabilityHints = const [],
    this.runtimeHome,
    this.source,
    this.endpoint,
    this.profileId,
  });

  factory RuntimeTarget.fromJson(Map<String, Object?> json) => RuntimeTarget(
    id: json['id']?.toString() ?? '',
    runtimeId: json['runtimeId']?.toString() ?? '',
    adapterId: json['adapterId']?.toString() ?? '',
    displayName: json['displayName']?.toString() ?? '',
    protocolName: json['protocolName']?.toString() ?? '',
    executablePath: json['executablePath']?.toString() ?? '',
    executionHost: _map(json['executionHost']),
    status: json['status']?.toString() ?? 'detected',
    priority: json['priority'] as int? ?? 0,
    capabilityHints: (json['capabilityHints'] as List<Object?>? ?? const [])
        .map((value) => value.toString())
        .toList(growable: false),
    runtimeHome: json['runtimeHome']?.toString(),
    source: json['source']?.toString(),
    endpoint: json['endpoint']?.toString(),
    profileId: json['profileId']?.toString(),
  );

  final String id;
  final String runtimeId;
  final String adapterId;
  final String displayName;
  final String protocolName;
  final String executablePath;
  final Map<String, Object?> executionHost;
  final String status;
  final int priority;
  final List<String> capabilityHints;
  final String? runtimeHome;
  final String? source;
  final String? endpoint;
  final String? profileId;

  RuntimeTarget copyWith({String? status}) => RuntimeTarget(
    id: id,
    runtimeId: runtimeId,
    adapterId: adapterId,
    displayName: displayName,
    protocolName: protocolName,
    executablePath: executablePath,
    executionHost: executionHost,
    status: status ?? this.status,
    priority: priority,
    capabilityHints: capabilityHints,
    runtimeHome: runtimeHome,
    source: source,
    endpoint: endpoint,
    profileId: profileId,
  );
}

final class RuntimeDiscovery {
  const RuntimeDiscovery({
    required this.targets,
    this.selectedTargetId,
    this.settings = const <String, Object?>{},
    this.binding = const <String, Object?>{},
  });

  final List<RuntimeTarget> targets;
  final String? selectedTargetId;
  final Map<String, Object?> settings;
  final Map<String, Object?> binding;
}

final class RuntimeConnection {
  const RuntimeConnection({
    required this.runtimeTargetId,
    required this.sessionId,
    required this.protocolVersion,
    required this.models,
    required this.sessions,
    required this.capabilities,
    this.sessionMetadata = const <String, Object?>{},
    this.runtimeVersion,
    this.history,
  });

  factory RuntimeConnection.fromJson(Map<String, Object?> json) =>
      RuntimeConnection(
        runtimeTargetId: json['runtimeTargetId']?.toString() ?? '',
        sessionId: json['sessionId']?.toString() ?? '',
        protocolVersion: json['protocolVersion'] as int? ?? 0,
        runtimeVersion: json['runtimeVersion']?.toString(),
        models: _mapList(json['models']),
        sessions: _mapList(json['sessions']),
        capabilities: (json['capabilities'] as List<Object?>? ?? const [])
            .map((value) => value.toString())
            .toList(growable: false),
        sessionMetadata: _map(json['sessionMetadata']),
        history: json['history'] is Map ? _map(json['history']) : null,
      );

  final String runtimeTargetId;
  final String sessionId;
  final int protocolVersion;
  final String? runtimeVersion;
  final List<Map<String, Object?>> models;
  final List<Map<String, Object?>> sessions;
  final List<String> capabilities;
  final Map<String, Object?> sessionMetadata;

  /// Canonical history included by adapters that read it while opening a chat.
  /// Null means the caller must use readSession; an empty transcript is valid.
  final Map<String, Object?>? history;
}

final class TurnReceipt {
  const TurnReceipt({
    required this.accepted,
    required this.runtimeTargetId,
    required this.sessionId,
    required this.turnId,
    required this.clientOperationId,
  });

  factory TurnReceipt.fromJson(Map<String, Object?> json) => TurnReceipt(
    accepted: json['accepted'] == true,
    runtimeTargetId: json['runtimeTargetId']?.toString() ?? '',
    sessionId: json['sessionId']?.toString() ?? '',
    turnId: json['turnId']?.toString() ?? '',
    clientOperationId: json['clientOperationId']?.toString() ?? '',
  );

  final bool accepted;
  final String runtimeTargetId;
  final String sessionId;
  final String turnId;
  final String clientOperationId;
}

final class CoreEvent {
  const CoreEvent({
    required this.name,
    required this.sequence,
    required this.runtimeTargetId,
    required this.payload,
    this.sessionId,
    this.turnId,
    this.clientOperationId,
  });

  factory CoreEvent.fromJson(Map<String, Object?> json) => CoreEvent(
    name: json['name']?.toString() ?? '',
    sequence: json['sequence'] as int? ?? 0,
    runtimeTargetId: json['runtimeTargetId']?.toString() ?? '',
    sessionId: json['sessionId']?.toString(),
    turnId: json['turnId']?.toString(),
    clientOperationId: json['clientOperationId']?.toString(),
    payload: _map(json['payload']),
  );

  final String name;
  final int sequence;
  final String runtimeTargetId;
  final String? sessionId;
  final String? turnId;
  final String? clientOperationId;
  final Map<String, Object?> payload;
}

final class CoreStatus {
  const CoreStatus({
    required this.version,
    required this.protocolVersion,
    required this.capabilities,
  });

  final String version;
  final int protocolVersion;
  final List<String> capabilities;
}

final class CoreProtocolException implements Exception {
  const CoreProtocolException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'CoreProtocolException($code): $message';
}

final class ProcessCoreBridge
    implements
        CoreBridge,
        RuntimeConfigurationBridge,
        RuntimePreparationBridge,
        SessionCatalogBridge,
        SessionForkBridge,
        SessionRewindBridge,
        GoalControlBridge,
        SessionStatusBridge,
        RuntimeCommandBridge {
  ProcessCoreBridge({
    this.executablePath,
    this.requestTimeout = const Duration(seconds: 30),
    this.connectionTimeout = const Duration(seconds: 90),
    this.environment = const {},
  }) : _catalogWorker = false;

  ProcessCoreBridge._catalog({
    required this.executablePath,
    required this.environment,
  }) : requestTimeout = const Duration(seconds: 90),
       connectionTimeout = const Duration(seconds: 90),
       _catalogWorker = true;

  final String? executablePath;
  final Duration requestTimeout;
  final Duration connectionTimeout;
  final Map<String, String> environment;
  final bool _catalogWorker;
  final Map<String, Completer<Map<String, Object?>>> _pending = {};
  final StreamController<CoreEvent> _events =
      StreamController<CoreEvent>.broadcast(sync: true);
  Process? _process;
  Future<void>? _starting;
  Future<void> _writeTail = Future<void>.value();
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  int _nextId = 0;
  String _stderr = '';
  bool _closing = false;
  Future<void>? _closeFuture;
  final Set<ProcessCoreBridge> _catalogWorkers = {};

  @override
  Stream<CoreEvent> get events => _events.stream;

  @override
  Future<CoreStatus> initialize() async {
    final result = await _request('core.initialize');
    final capabilities = (result['capabilities'] as List<Object?>? ?? const [])
        .map((value) => value.toString())
        .toList(growable: false);
    return CoreStatus(
      version: result['coreVersion']?.toString() ?? 'unknown',
      protocolVersion: result['protocolVersion'] as int? ?? 0,
      capabilities: capabilities,
    );
  }

  @override
  Future<RuntimeDiscovery> discoverRuntimeTargets({
    String? lastSelectedTargetId,
    bool force = false,
  }) async {
    final result = await _request('runtime.discover', <String, Object?>{
      'lastSelectedTargetId': ?lastSelectedTargetId,
      'force': force,
    });
    final targets = (result['targets'] as List<Object?>? ?? const [])
        .map(_map)
        .map(RuntimeTarget.fromJson)
        .toList(growable: false);
    return RuntimeDiscovery(
      targets: targets,
      selectedTargetId: result['selectedTargetId']?.toString(),
      settings: _map(result['settings']),
      binding: _map(result['binding']),
    );
  }

  @override
  Future<RuntimeDiscovery> addRuntimeOverride(
    Map<String, Object?> override,
  ) async {
    final result = await _request('runtime.addOverride', <String, Object?>{
      'override': override,
    });
    return _runtimeDiscovery(result);
  }

  @override
  Future<RuntimeDiscovery> removeRuntimeOverride(String overrideId) async {
    final result = await _request('runtime.removeOverride', <String, Object?>{
      'overrideId': overrideId,
    });
    return _runtimeDiscovery(result);
  }

  RuntimeDiscovery _runtimeDiscovery(Map<String, Object?> result) {
    final targets = (result['targets'] as List<Object?>? ?? const [])
        .map(_map)
        .map(RuntimeTarget.fromJson)
        .toList(growable: false);
    return RuntimeDiscovery(
      targets: targets,
      selectedTargetId: result['selectedTargetId']?.toString(),
      settings: _map(result['settings']),
      binding: _map(result['binding']),
    );
  }

  @override
  Future<RuntimeConnection> connectRuntime({
    required String runtimeTargetId,
    String? preferredSessionId,
    String? cwd,
  }) async {
    final result = await _request('runtime.connect', <String, Object?>{
      'runtimeTargetId': runtimeTargetId,
      'preferredSessionId': ?preferredSessionId,
      'cwd': ?cwd,
    });
    return RuntimeConnection.fromJson(result);
  }

  @override
  Future<List<Map<String, Object?>>> listSessions({
    required String runtimeTargetId,
  }) async {
    final result = await _request('session.list', <String, Object?>{
      'runtimeTargetId': runtimeTargetId,
    });
    return _mapList(result['data']);
  }

  @override
  Future<void> prepareRuntime({required String runtimeTargetId}) async {
    await _request('runtime.prepare', {'runtimeTargetId': runtimeTargetId});
  }

  @override
  Future<List<Map<String, Object?>>> listSessionCatalog({
    required String runtimeTargetId,
  }) async {
    if (_closing) {
      throw const CoreProtocolException(
        'core-closed',
        'The Rust core was closed.',
      );
    }
    // Runtime startup can be slow. A short-lived listing host keeps it off the
    // foreground host's request queue and never changes the persisted binding.
    final worker = ProcessCoreBridge._catalog(
      executablePath: executablePath,
      environment: environment,
    );
    _catalogWorkers.add(worker);
    try {
      await worker.initialize();
      final result = await worker._request('session.catalog', {
        'runtimeTargetId': runtimeTargetId,
      });
      return _mapList(result['data']);
    } finally {
      await worker.close();
      _catalogWorkers.remove(worker);
    }
  }

  @override
  Future<RuntimeConnection> createSession({
    required String runtimeTargetId,
    String? model,
    String? effort,
    String? cwd,
    String? profile,
  }) async {
    final result = await _request('session.create', <String, Object?>{
      'runtimeTargetId': runtimeTargetId,
      'model': ?model,
      'effort': ?effort,
      'cwd': ?cwd,
      'profile': ?profile,
    });
    return RuntimeConnection.fromJson(result);
  }

  @override
  Future<RuntimeConnection> forkSession({
    required String runtimeTargetId,
    required String sessionId,
  }) async => RuntimeConnection.fromJson(
    await _request('session.fork', {
      'runtimeTargetId': runtimeTargetId,
      'sessionId': sessionId,
    }),
  );

  @override
  Future<Map<String, Object?>> prepareSessionRewind({
    required String runtimeTargetId,
    required String sessionId,
  }) => _request('session.rewind.prepare', {
    'runtimeTargetId': runtimeTargetId,
    'sessionId': sessionId,
  });

  @override
  Future<Map<String, Object?>> rewindSession({
    required String runtimeTargetId,
    required String sessionId,
    required String turnId,
    required String expectedLastTurnId,
  }) => _request('session.rewind', {
    'runtimeTargetId': runtimeTargetId,
    'sessionId': sessionId,
    'turnId': turnId,
    'expectedLastTurnId': expectedLastTurnId,
  });

  @override
  Future<RuntimeConnection> openSession({
    required String runtimeTargetId,
    required String sessionId,
    String? cwd,
    String? profile,
  }) async {
    final result = await _request('session.open', <String, Object?>{
      'runtimeTargetId': runtimeTargetId,
      'sessionId': sessionId,
      'cwd': ?cwd,
      'profile': ?profile,
    });
    return RuntimeConnection.fromJson(result);
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
    final result = await _request('session.configure', <String, Object?>{
      'runtimeTargetId': runtimeTargetId,
      'sessionId': sessionId,
      'cwd': ?cwd,
      'profile': ?profile,
      'model': ?model,
      'effort': ?effort,
    });
    return RuntimeConnection.fromJson(result);
  }

  @override
  Future<Map<String, Object?>> readSession({
    required String runtimeTargetId,
    required String sessionId,
  }) => _request('session.read', <String, Object?>{
    'runtimeTargetId': runtimeTargetId,
    'sessionId': sessionId,
  });

  @override
  Future<Map<String, Object?>> sessionStatus({
    required String runtimeTargetId,
    required String sessionId,
  }) => _request('session.status', {
    'runtimeTargetId': runtimeTargetId,
    'sessionId': sessionId,
  });

  @override
  Future<Map<String, Object?>> goalCommand({
    required String runtimeTargetId,
    required String sessionId,
    required String action,
    String? objective,
    String? model,
    String? effort,
    String? cwd,
  }) => _request('session.goal', {
    'runtimeTargetId': runtimeTargetId,
    'sessionId': sessionId,
    'action': action,
    'objective': ?objective,
    'model': ?model,
    'effort': ?effort,
    'cwd': ?cwd,
  });

  @override
  Future<Map<String, Object?>> listCommands({
    required String runtimeTargetId,
    required String sessionId,
    bool force = false,
  }) => _request('session.commands', {
    'runtimeTargetId': runtimeTargetId,
    'sessionId': sessionId,
    'force': force,
  });

  @override
  Future<TurnReceipt> startCommand({
    required String runtimeTargetId,
    required String sessionId,
    required String message,
    required String clientOperationId,
    String? model,
    String? effort,
    String? cwd,
    String? profile,
  }) async {
    final result = await _request('command.execute', {
      'runtimeTargetId': runtimeTargetId,
      'sessionId': sessionId,
      'message': message,
      'clientOperationId': clientOperationId,
      'model': ?model,
      'effort': ?effort,
      'cwd': ?cwd,
      'profile': ?profile,
    });
    return TurnReceipt.fromJson(result);
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
    final result = await _request('turn.start', <String, Object?>{
      'runtimeTargetId': runtimeTargetId,
      'sessionId': sessionId,
      'message': message,
      'snapshots': snapshots,
      'images': images,
      'clientOperationId': ?clientOperationId,
      'model': ?model,
      'effort': ?effort,
      'cwd': ?cwd,
      'profile': ?profile,
    });
    return TurnReceipt.fromJson(result);
  }

  @override
  Future<void> interruptTurn({
    required String runtimeTargetId,
    required String sessionId,
    required String turnId,
  }) async {
    await _request('turn.interrupt', <String, Object?>{
      'runtimeTargetId': runtimeTargetId,
      'sessionId': sessionId,
      'turnId': turnId,
    });
  }

  @override
  Future<void> steerTurn({
    required String runtimeTargetId,
    required String sessionId,
    required String turnId,
    required String message,
    List<String> images = const [],
  }) async {
    await _request('turn.steer', <String, Object?>{
      'runtimeTargetId': runtimeTargetId,
      'sessionId': sessionId,
      'turnId': turnId,
      'message': message,
      'images': images,
    });
  }

  @override
  Future<void> resolveApproval({
    required String runtimeTargetId,
    required String sessionId,
    required String approvalId,
    String? optionId,
  }) async {
    await _request('approval.resolve', <String, Object?>{
      'runtimeTargetId': runtimeTargetId,
      'sessionId': sessionId,
      'approvalId': approvalId,
      'optionId': ?optionId,
    });
  }

  @override
  Future<void> resolveQuestion({
    required String runtimeTargetId,
    required String sessionId,
    required String questionId,
    required Map<String, Object?> answer,
  }) async {
    await _request('question.resolve', <String, Object?>{
      'runtimeTargetId': runtimeTargetId,
      'sessionId': sessionId,
      'questionId': questionId,
      'answer': answer,
    });
  }

  @override
  Future<String> buildContextHandoff({
    required String message,
    List<Map<String, Object?>> snapshots = const [],
    int imageCount = 0,
  }) async {
    final result = await _request('context.buildHandoff', <String, Object?>{
      'message': message,
      'snapshots': snapshots,
      'imageCount': imageCount,
    });
    return result['text']?.toString() ?? '';
  }

  Future<Map<String, Object?>> _request(
    String operation, [
    Map<String, Object?> payload = const {},
  ]) async {
    void checkOpen() {
      if (_closing && operation != 'core.shutdown') {
        throw const CoreProtocolException(
          'core-closed',
          'The Rust core was closed.',
        );
      }
    }

    checkOpen();
    await _ensureStarted();
    checkOpen();
    final process = _process;
    if (process == null) {
      throw const CoreProtocolException(
        'core-unavailable',
        'The Rust core process is not running.',
      );
    }
    final id = (++_nextId).toString();
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    // A response or process exit may arrive while its write is still flushing.
    // Attach an error listener immediately; the caller still awaits the result.
    completer.future.ignore();
    final write = _writeTail.then((_) async {
      checkOpen();
      process.stdin.writeln(
        jsonEncode(<String, Object?>{
          'id': id,
          'protocolVersion': coreProtocolVersion,
          'operation': operation,
          'payload': payload,
        }),
      );
      await process.stdin.flush();
    });
    // IOSink rejects writes during flush. Serialize only writes, not replies,
    // so background catalogs can overlap history, chat, and runtime recovery.
    _writeTail = write.catchError((Object _) {});
    try {
      await write;
    } on Object {
      _pending.remove(id);
      rethrow;
    }
    // Cold discovery and connection include runtime startup, which can exceed
    // the deadline for ordinary RPCs (Hermes alone allows 45 seconds to start).
    final timeout =
        const {
          'runtime.discover',
          'runtime.connect',
          'runtime.prepare',
          'session.open',
        }.contains(operation)
        ? connectionTimeout
        : requestTimeout;
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(id);
      throw CoreProtocolException(
        'core-timeout',
        "The Rust core did not answer '$operation' within "
            '${timeout.inSeconds} seconds.',
      );
    }
  }

  Future<void> _ensureStarted() async {
    if (_process != null) return;
    if (_starting case final starting?) return starting;
    final starting = _startProcess();
    _starting = starting;
    try {
      await starting;
    } finally {
      if (identical(_starting, starting)) _starting = null;
    }
  }

  Future<void> _startProcess() async {
    final process = await Process.start(
      _resolveExecutablePath(),
      _catalogWorker ? const ['--session-catalog-worker'] : const [],
      runInShell: false,
      environment: coreRuntimeEnvironment(overrides: environment),
      includeParentEnvironment: true,
    );
    _process = process;
    _stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleLine);
    _stderrSubscription = process.stderr.transform(utf8.decoder).listen((
      chunk,
    ) {
      _stderr = '$_stderr$chunk';
      if (_stderr.length > 4000) {
        _stderr = _stderr.substring(_stderr.length - 4000);
      }
    });
    unawaited(
      process.exitCode.then((exitCode) {
        if (identical(_process, process)) _process = null;
        if (_closing) return;
        _failPending(
          CoreProtocolException(
            'core-exited',
            'The Rust core exited with code $exitCode.'
                '${_stderr.trim().isEmpty ? '' : ' ${_stderr.trim()}'}',
          ),
        );
      }),
    );
  }

  String _resolveExecutablePath() {
    return resolveCoreHostExecutable(configured: executablePath);
  }

  void _handleLine(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('Core response is not an object.');
      }
      if (decoded['protocolVersion'] != coreProtocolVersion) {
        throw const CoreProtocolException(
          'unsupported-version',
          'The Rust core response protocol does not match the Flutter client.',
        );
      }
      final event = decoded['event'];
      if (event is Map<String, Object?>) {
        _events.add(CoreEvent.fromJson(event));
        return;
      }
      final id = decoded['id']?.toString();
      final completer = id == null ? null : _pending.remove(id);
      if (completer == null) return;
      if (decoded['ok'] == true) {
        final result = decoded['result'];
        completer.complete(
          result is Map<String, Object?> ? result : <String, Object?>{},
        );
        return;
      }
      final error = decoded['error'];
      final errorMap = error is Map<String, Object?>
          ? error
          : <String, Object?>{};
      completer.completeError(
        CoreProtocolException(
          errorMap['code']?.toString() ?? 'core-failed',
          errorMap['message']?.toString() ?? 'The Rust core request failed.',
        ),
      );
    } on Object catch (error, stackTrace) {
      _failPending(error, stackTrace);
    }
  }

  void _failPending(Object error, [StackTrace? stackTrace]) {
    final pending = _pending.values.toList(growable: false);
    _pending.clear();
    for (final completer in pending) {
      completer.completeError(error, stackTrace ?? StackTrace.current);
    }
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    await Future.wait(_catalogWorkers.toList().map((worker) => worker.close()));
    try {
      await _starting;
    } on Object {
      // Startup failures are already reported to the initiating request.
    }
    final process = _process;
    if (process != null) {
      try {
        await _request('core.shutdown');
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on Object {
        process.kill();
      }
    }
    _process = null;
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _failPending(
      const CoreProtocolException('core-closed', 'The Rust core was closed.'),
    );
    if (!_events.isClosed) await _events.close();
  }
}

String resolveCoreHostExecutable({
  String? configured,
  Map<String, String>? environment,
  String? resolvedExecutable,
  String? applicationDirectory,
  String? pathSeparator,
  String? operatingSystem,
  bool Function(String path)? exists,
}) {
  if (configured?.trim().isNotEmpty == true) return configured!.trim();
  final processEnvironment = environment ?? Platform.environment;
  final environmentPath = processEnvironment['ZOMMI_CORE_HOST']?.trim();
  if (environmentPath?.isNotEmpty == true) return environmentPath!;

  final platform = operatingSystem ?? Platform.operatingSystem;
  final executableName = platform == 'windows'
      ? 'zommi-core-host.exe'
      : 'zommi-core-host';
  final separator = pathSeparator ?? Platform.pathSeparator;
  final executableDirectory =
      applicationDirectory ??
      File(resolvedExecutable ?? Platform.resolvedExecutable).parent.path;
  final candidates = <String>[
    '$executableDirectory$separator$executableName',
    '$executableDirectory${separator}lib$separator$executableName',
    if (platform == 'macos')
      '${Directory(executableDirectory).parent.path}${separator}Resources'
          '$separator$executableName',
  ];
  for (final candidate in candidates) {
    final present = exists?.call(candidate) ?? File(candidate).existsSync();
    if (present) return candidate;
  }
  return executableName;
}

Map<String, Object?> _map(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return <String, Object?>{};
}

List<Map<String, Object?>> _mapList(Object? value) =>
    (value as List<Object?>? ?? const []).map(_map).toList(growable: false);
