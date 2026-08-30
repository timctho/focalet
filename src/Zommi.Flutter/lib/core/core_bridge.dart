import 'dart:async';
import 'dart:convert';
import 'dart:io';

const int coreProtocolVersion = 1;

abstract interface class CoreBridge {
  Future<CoreStatus> initialize();

  Future<String> buildContextHandoff({
    required String message,
    List<Map<String, Object?>> snapshots = const [],
    int imageCount = 0,
  });

  Future<void> close();
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
    this.requestTimeout = const Duration(seconds: 10),
  });

  final String? executablePath;
  final Duration requestTimeout;
  final Map<String, Completer<Map<String, Object?>>> _pending = {};
  Process? _process;
  Future<void>? _starting;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  int _nextId = 0;
  String _stderr = '';
  bool _closing = false;

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
    process.stdin.writeln(
      jsonEncode(<String, Object?>{
        'id': id,
        'protocolVersion': coreProtocolVersion,
        'operation': operation,
        'payload': payload,
      }),
    );
    await process.stdin.flush();
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
    final process = _process;
    if (process == null) return;
    _closing = true;
    try {
      await _request('core.shutdown');
      await process.exitCode.timeout(const Duration(seconds: 2));
    } on Object {
      process.kill();
    } finally {
      _process = null;
      await _stdoutSubscription?.cancel();
      await _stderrSubscription?.cancel();
      _failPending(
        const CoreProtocolException('core-closed', 'The Rust core was closed.'),
      );
    }
  }
}
