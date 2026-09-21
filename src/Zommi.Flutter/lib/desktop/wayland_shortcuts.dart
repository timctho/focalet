part of 'desktop_bridge.dart';

bool shouldUseWaylandPortals(Map<String, String> environment) {
  final sessionType = environment['XDG_SESSION_TYPE']?.trim().toLowerCase();
  final waylandDisplay = environment['WAYLAND_DISPLAY']?.trim();
  final x11Display = environment['DISPLAY']?.trim();
  return sessionType == 'wayland' ||
      (waylandDisplay?.isNotEmpty == true && x11Display?.isNotEmpty != true);
}

abstract interface class WaylandPortalShortcutClient {
  Stream<String> get activations;

  Future<DesktopReadiness> initialize();

  Future<void> close();
}

final class WaylandPortalShortcutRegistration {
  const WaylandPortalShortcutRegistration({
    required this.readiness,
    required this.subscription,
  });

  final DesktopReadiness readiness;
  final StreamSubscription<String> subscription;
}

Future<WaylandPortalShortcutRegistration> registerWaylandPortalShortcuts(
  WaylandPortalShortcutClient client, {
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
    return WaylandPortalShortcutRegistration(
      readiness: readiness,
      subscription: subscription,
    );
  } on Object {
    await subscription.cancel();
    rethrow;
  }
}

final class ProcessWaylandPortalShortcutClient
    implements WaylandPortalShortcutClient {
  ProcessWaylandPortalShortcutClient(
    this.executablePath, {
    this.argumentsBeforeCommand = const [],
  });

  final String executablePath;
  final List<String> argumentsBeforeCommand;
  final StreamController<String> _activations =
      StreamController<String>.broadcast(sync: true);
  final StringBuffer _stderr = StringBuffer();
  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  bool _closing = false;

  @override
  Stream<String> get activations => _activations.stream;

  @override
  Future<DesktopReadiness> initialize() async {
    if (_process != null) {
      throw StateError('The Wayland shortcut helper is already running.');
    }
    final ready = Completer<DesktopReadiness>();
    final process = await Process.start(executablePath, [
      ...argumentsBeforeCommand,
      'portal-shortcuts',
    ]);
    _process = process;
    _stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          try {
            final value = jsonDecode(line);
            final message = _nullableMap(value);
            if (message?['event'] == 'ready' && !ready.isCompleted) {
              ready.complete(
                DesktopReadiness(
                  contextShortcut: message?['contextShortcut'] == true,
                  imageShortcut: message?['imageShortcut'] == true,
                ),
              );
            } else if (message?['event'] == 'activated') {
              final shortcut = message?['shortcutId']?.toString();
              if (shortcut == 'context') {
                _activations.add(shortcut!);
              }
            }
          } on FormatException {
            // Native diagnostics may be written around the JSONL protocol.
          }
        });
    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .listen(_stderr.write);
    unawaited(
      process.exitCode.then((exitCode) async {
        final message =
            'Wayland shortcut helper exited $exitCode: ${_stderr.toString().trim()}';
        if (!ready.isCompleted) ready.completeError(StateError(message));
        if (!_closing && !_activations.isClosed) {
          _activations.addError(StateError(message));
          await _activations.close();
        }
      }),
    );
    return ready.future.timeout(
      const Duration(minutes: 2),
      onTimeout: () {
        process.kill();
        throw TimeoutException(
          'Timed out waiting for Wayland portal shortcut authorization.',
        );
      },
    );
  }

  @override
  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    final process = _process;
    if (process != null && process.kill()) {
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      }
    }
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    if (!_activations.isClosed) await _activations.close();
  }
}
