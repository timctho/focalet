part of 'desktop_bridge.dart';

Future<void> presentGnomeWindow() async {
  final process = await Process.start(resolveLinuxCaptureExecutable(), [
    'present',
    '$pid',
  ]);
  final output = process.stdout.drain<void>();
  final error = process.stderr.drain<void>();
  try {
    await process.exitCode.timeout(const Duration(seconds: 3));
    await Future.wait([output, error]);
  } finally {
    process.kill();
  }
}

abstract interface class GnomeShortcutClient {
  Stream<String> get activations;

  Future<DesktopReadiness> initialize();

  Future<void> close();
}

final class GnomeShortcutRegistration {
  const GnomeShortcutRegistration({
    required this.readiness,
    required this.subscription,
  });

  final DesktopReadiness readiness;
  final StreamSubscription<String> subscription;
}

Future<GnomeShortcutRegistration> registerGnomeShortcuts(
  GnomeShortcutClient client, {
  required void Function() onContext,
  required void Function(Object error) onError,
}) async {
  final subscription = client.activations.listen((shortcut) {
    switch (shortcut) {
      case 'context':
        onContext();
    }
  }, onError: onError);
  try {
    final readiness = await client.initialize();
    return GnomeShortcutRegistration(
      readiness: readiness,
      subscription: subscription,
    );
  } on Object {
    await subscription.cancel();
    rethrow;
  }
}

final class ProcessGnomeShortcutClient implements GnomeShortcutClient {
  ProcessGnomeShortcutClient(
    this.executablePath, {
    this.argumentsBeforeCommand = const [],
    this.retryDelay = const Duration(seconds: 2),
  });
  final String executablePath;
  final List<String> argumentsBeforeCommand;
  final Duration retryDelay;
  final _activations = StreamController<String>.broadcast(sync: true);
  final _ready = Completer<DesktopReadiness>();
  Process? _process;
  Timer? _retry;
  bool _started = false;
  bool _closing = false;
  bool _reportedFailure = false;

  @override
  Stream<String> get activations => _activations.stream;

  @override
  Future<DesktopReadiness> initialize() {
    if (_started) {
      throw StateError('GNOME shortcut registration already started.');
    }
    _started = true;
    unawaited(_launch());
    return _ready.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _process?.kill();
        return const DesktopReadiness(
          contextShortcut: false,
          imageShortcut: false,
        );
      },
    );
  }

  Future<void> _launch() async {
    if (_closing) return;
    StreamSubscription<String>? output;
    StreamSubscription<String>? errors;
    var diagnostic = '';
    try {
      final process = await Process.start(executablePath, [
        ...argumentsBeforeCommand,
        'shortcuts',
      ]);
      _process = process;
      if (_closing) {
        process.kill();
        return;
      }
      output = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            try {
              final message = _nullableMap(jsonDecode(line));
              if (message?['event'] == 'ready') {
                final active = message?['contextShortcut'] == true;
                if (!_ready.isCompleted) {
                  _ready.complete(
                    DesktopReadiness(
                      contextShortcut: active,
                      imageShortcut: false,
                    ),
                  );
                }
                if (active) _reportedFailure = false;
              } else if (message?['event'] == 'activated' &&
                  message?['shortcutId'] == 'context' &&
                  !_closing) {
                _activations.add('context');
              }
            } on FormatException {
              // Ignore non-protocol diagnostics.
            }
          });
      errors = process.stderr.transform(utf8.decoder).listen((text) {
        diagnostic += text;
        if (diagnostic.length > 2048) {
          diagnostic = diagnostic.substring(diagnostic.length - 2048);
        }
      });
      final code = await process.exitCode;
      if (!_closing) {
        throw StateError(
          'GNOME shortcut connection exited $code. Reconnecting. ${diagnostic.trim()}',
        );
      }
    } on Object catch (error) {
      if (!_ready.isCompleted) {
        _ready.complete(
          const DesktopReadiness(contextShortcut: false, imageShortcut: false),
        );
      }
      if (!_closing && !_reportedFailure) {
        _reportedFailure = true;
        _activations.addError(error);
      }
    } finally {
      await output?.cancel();
      await errors?.cancel();
      _process = null;
      if (!_closing) _retry = Timer(retryDelay, () => unawaited(_launch()));
    }
  }

  @override
  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    _retry?.cancel();
    final process = _process;
    if (process != null && process.kill()) {
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      }
    }
    if (!_activations.isClosed) await _activations.close();
  }
}
