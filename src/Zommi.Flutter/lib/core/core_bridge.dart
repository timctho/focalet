import 'dart:async';
import 'dart:convert';
import 'dart:io';

const int coreProtocolVersion = 1;

abstract interface class CoreBridge {
  Stream<CoreEvent> get events;

  Future<CoreStatus> initialize();

  Future<RuntimeDiscovery> discoverRuntimeTargets({
    String? lastSelectedTargetId,
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
  });

  Future<RuntimeConnection> openSession({
    required String runtimeTargetId,
    required String sessionId,
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
  });

  Future<void> interruptTurn({
    required String runtimeTargetId,
    required String sessionId,
    required String turnId,
  });

  Future<String> buildContextHandoff({
    required String message,
    List<Map<String, Object?>> snapshots = const [],
    int imageCount = 0,
  });

  Future<void> close();
}

final class RuntimeTarget {
  const RuntimeTarget({
    required this.id,
    required this.runtimeId,
    required this.displayName,
    required this.protocolName,
    required this.executablePath,
    required this.executionHost,
  });

  factory RuntimeTarget.fromJson(Map<String, Object?> json) => RuntimeTarget(
    id: json['id']?.toString() ?? '',
    runtimeId: json['runtimeId']?.toString() ?? '',
    displayName: json['displayName']?.toString() ?? '',
    protocolName: json['protocolName']?.toString() ?? '',
    executablePath: json['executablePath']?.toString() ?? '',
    executionHost: _map(json['executionHost']),
  );

  final String id;
  final String runtimeId;
  final String displayName;
  final String protocolName;
  final String executablePath;
  final Map<String, Object?> executionHost;
}

final class RuntimeDiscovery {
  const RuntimeDiscovery({required this.targets, this.selectedTargetId});

  final List<RuntimeTarget> targets;
  final String? selectedTargetId;
}

final class RuntimeConnection {
  const RuntimeConnection({
    required this.runtimeTargetId,
    required this.sessionId,
    required this.protocolVersion,
    required this.models,
    required this.sessions,
    this.runtimeVersion,
  });

  factory RuntimeConnection.fromJson(Map<String, Object?> json) =>
      RuntimeConnection(
        runtimeTargetId: json['runtimeTargetId']?.toString() ?? '',
        sessionId: json['sessionId']?.toString() ?? '',
        protocolVersion: json['protocolVersion'] as int? ?? 0,
        runtimeVersion: json['runtimeVersion']?.toString(),
        models: _mapList(json['models']),
        sessions: _mapList(json['sessions']),
      );

  final String runtimeTargetId;
  final String sessionId;
  final int protocolVersion;
  final String? runtimeVersion;
  final List<Map<String, Object?>> models;
  final List<Map<String, Object?>> sessions;
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

final class ProcessCoreBridge implements CoreBridge {
  ProcessCoreBridge({
    this.executablePath,
    this.requestTimeout = const Duration(seconds: 30),
    this.environment = const {},
  });

  final String? executablePath;
  final Duration requestTimeout;
  final Map<String, String> environment;
  final Map<String, Completer<Map<String, Object?>>> _pending = {};
  final StreamController<CoreEvent> _events =
      StreamController<CoreEvent>.broadcast(sync: true);
  Process? _process;
  Future<void>? _starting;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  int _nextId = 0;
  String _stderr = '';
  bool _closing = false;

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
  }) async {
    final result = await _request('runtime.discover', <String, Object?>{
      'lastSelectedTargetId': ?lastSelectedTargetId,
    });
    final targets = (result['targets'] as List<Object?>? ?? const [])
        .map(_map)
        .map(RuntimeTarget.fromJson)
        .toList(growable: false);
    return RuntimeDiscovery(
      targets: targets,
      selectedTargetId: result['selectedTargetId']?.toString(),
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
  Future<RuntimeConnection> createSession({
    required String runtimeTargetId,
    String? model,
    String? effort,
  }) async {
    final result = await _request('session.create', <String, Object?>{
      'runtimeTargetId': runtimeTargetId,
      'model': ?model,
      'effort': ?effort,
    });
    return RuntimeConnection.fromJson(result);
  }

  @override
  Future<RuntimeConnection> openSession({
    required String runtimeTargetId,
    required String sessionId,
  }) async {
    final result = await _request('session.open', <String, Object?>{
      'runtimeTargetId': runtimeTargetId,
      'sessionId': sessionId,
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
    final result = await _request('turn.start', <String, Object?>{
      'runtimeTargetId': runtimeTargetId,
      'sessionId': sessionId,
      'message': message,
      'snapshots': snapshots,
      'images': images,
      'clientOperationId': ?clientOperationId,
      'model': ?model,
      'effort': ?effort,
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
    await _ensureStarted();
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
    try {
      process.stdin.writeln(
        jsonEncode(<String, Object?>{
          'id': id,
          'protocolVersion': coreProtocolVersion,
          'operation': operation,
          'payload': payload,
        }),
      );
      await process.stdin.flush();
    } on Object {
      _pending.remove(id);
      rethrow;
    }
    try {
      return await completer.future.timeout(requestTimeout);
    } on TimeoutException {
      _pending.remove(id);
      throw CoreProtocolException(
        'core-timeout',
        "The Rust core did not answer '$operation' within "
            '${requestTimeout.inSeconds} seconds.',
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
      const [],
      runInShell: false,
      environment: environment,
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
    if (executablePath case final configured?) return configured;
    if (Platform.environment['ZOMMI_CORE_HOST'] case final configured?) {
      return configured;
    }
    return Platform.isWindows ? 'zommi-core-host.exe' : 'zommi-core-host';
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
  Future<void> close() async {
    _closing = true;
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

Map<String, Object?> _map(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return <String, Object?>{};
}

List<Map<String, Object?>> _mapList(Object? value) =>
    (value as List<Object?>? ?? const []).map(_map).toList(growable: false);
