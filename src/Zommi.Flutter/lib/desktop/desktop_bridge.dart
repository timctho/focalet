import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:screen_capturer/screen_capturer.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/state/zommi_models.dart';

const Size compactWindowSize = Size(56, 56);
const Size normalWindowSize = Size(720, 620);
const Size largeWindowSize = Size(920, 760);
const double windowBottomInset = 18;
const Duration surfaceTransitionDuration = Duration(milliseconds: 280);
const int surfaceTransitionFrameCount = 16;
const MethodChannel _windowAnimationChannel = MethodChannel(
  'zommi/window_animation',
);

enum DesktopInvocationKind { open, context, image, status }

final class DesktopInvocation {
  const DesktopInvocation({
    required this.kind,
    this.attachment,
    this.message,
    this.warning = false,
  });

  final DesktopInvocationKind kind;
  final ContextAttachment? attachment;
  final String? message;
  final bool warning;
}

DesktopInvocation? imageSelectionInvocation(ContextAttachment? attachment) {
  if (attachment == null) return null;
  return DesktopInvocation(
    kind: DesktopInvocationKind.image,
    attachment: attachment,
    message: 'Image context attached',
  );
}

final class DesktopReadiness {
  const DesktopReadiness({
    this.contextShortcut = false,
    this.imageShortcut = false,
  });

  final bool contextShortcut;
  final bool imageShortcut;
}

abstract interface class DesktopAcceptanceRecorder {
  Future<void> record(String event, Map<String, Object?> details);
}

final class FileDesktopAcceptanceRecorder implements DesktopAcceptanceRecorder {
  FileDesktopAcceptanceRecorder(this.path);

  static FileDesktopAcceptanceRecorder? fromEnvironment() {
    final path = Platform.environment['ZOMMI_ACCEPTANCE_LOG']?.trim();
    return path == null || path.isEmpty
        ? null
        : FileDesktopAcceptanceRecorder(path);
  }

  final String path;

  @override
  Future<void> record(String event, Map<String, Object?> details) async {
    final line = jsonEncode({
      'event': event,
      'observedAtUtc': DateTime.now().toUtc().toIso8601String(),
      ...details,
    });
    await File(path)
        .writeAsString('$line\n', mode: FileMode.append, flush: true);
  }
}

abstract interface class DesktopBridge {
  Stream<DesktopInvocation> get invocations;

  Future<DesktopReadiness> initialize();

  Future<ContextAttachment?> captureContext();

  Future<ContextAttachment?> selectImageContext({
    bool includePointerContext = false,
  });

  Future<void> setSurface({
    required bool expanded,
    bool large = false,
    bool animate = true,
  });

  Future<void> showPanel();

  Future<void> hide();

  Future<void> toggleMaximized();

  Future<void> startDragging();

  Future<void> openRuntimeSignIn(RuntimeTarget target);

  Future<String?> selectRuntimeExecutable();

  Future<void> copyText(String value);

  Future<void> copyImage(String dataUrl);

  Future<void> close();
}

final class NoopDesktopBridge implements DesktopBridge {
  const NoopDesktopBridge();

  @override
  Stream<DesktopInvocation> get invocations => const Stream.empty();

  @override
  Future<DesktopReadiness> initialize() async => const DesktopReadiness();

  @override
  Future<ContextAttachment?> captureContext() async => null;

  @override
  Future<ContextAttachment?> selectImageContext({
    bool includePointerContext = false,
  }) async => null;

  @override
  Future<void> setSurface({
    required bool expanded,
    bool large = false,
    bool animate = true,
  }) async {}

  @override
  Future<void> showPanel() async {}

  @override
  Future<void> hide() async {}

  @override
  Future<void> toggleMaximized() async {}

  @override
  Future<void> startDragging() async {}

  @override
  Future<void> openRuntimeSignIn(RuntimeTarget target) async {}

  @override
  Future<String?> selectRuntimeExecutable() async => null;

  @override
  Future<void> copyText(String value) =>
      Clipboard.setData(ClipboardData(text: value));

  @override
  Future<void> copyImage(String dataUrl) async {}

  @override
  Future<void> close() async {}
}

final class FlutterDesktopBridge
    with WindowListener, TrayListener
    implements DesktopBridge {
  FlutterDesktopBridge({
    CaptureProvider? captureProvider,
    DesktopAcceptanceRecorder? acceptanceRecorder,
    WaylandPortalShortcutClient? waylandPortalShortcutClient,
    bool? useWaylandPortals,
  }) : _captureProvider = captureProvider ?? platformCaptureProvider(),
       _waylandPortalShortcutClient =
           waylandPortalShortcutClient ??
           ProcessWaylandPortalShortcutClient(resolveLinuxCaptureExecutable()),
       _useWaylandPortals =
           useWaylandPortals ??
           (Platform.isLinux && shouldUseWaylandPortals(Platform.environment)),
       _acceptanceRecorder =
           acceptanceRecorder ??
           FileDesktopAcceptanceRecorder.fromEnvironment();

  static Future<FlutterDesktopBridge> bootstrap() async {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: compactWindowSize,
      minimumSize: compactWindowSize,
      backgroundColor: Color(0x00000000),
      alwaysOnTop: true,
      skipTaskbar: true,
      title: 'Zommi — floating agent chat',
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    unawaited(
      windowManager.waitUntilReadyToShow(options, () async {
        await windowManager.setAsFrameless();
        if (supportsNativeWindowShadow(Platform.operatingSystem)) {
          await windowManager.setHasShadow(false);
        }
        // Zommi owns its surface sizes. Changing the native resize style on
        // every orb morph forces a Win32 frame recalculation and produces a
        // visible one-frame wobble even though the window is frameless.
        await windowManager.setResizable(false);
        await configureNativeSurfaceWindow();
        await windowManager.setAlwaysOnTop(true);
        await windowManager.setSkipTaskbar(true);
        await windowManager.show();
      }),
    );
    return FlutterDesktopBridge();
  }

  final CaptureProvider _captureProvider;
  final WaylandPortalShortcutClient _waylandPortalShortcutClient;
  final bool _useWaylandPortals;
  final DesktopAcceptanceRecorder? _acceptanceRecorder;
  final StreamController<DesktopInvocation> _invocations =
      StreamController<DesktopInvocation>.broadcast(sync: true);
  final HotKey _contextHotKey = HotKey(
    key: PhysicalKeyboardKey.keyA,
    modifiers: const [HotKeyModifier.alt],
    scope: HotKeyScope.system,
  );
  final HotKey _imageHotKey = HotKey(
    key: PhysicalKeyboardKey.keyA,
    modifiers: const [HotKeyModifier.alt, HotKeyModifier.shift],
    scope: HotKeyScope.system,
  );
  bool _initialized = false;
  bool _surfacePositionInitialized = false;
  int _surfaceTransitionEpoch = 0;
  Offset? _surfaceAnchor;
  bool _nativeContextRegistered = false;
  bool _nativeImageRegistered = false;
  DesktopReadiness _readiness = const DesktopReadiness();
  StreamSubscription<String>? _portalShortcutSubscription;
  String? _trayIconPath;

  @override
  Stream<DesktopInvocation> get invocations => _invocations.stream;

  @override
  Future<DesktopReadiness> initialize() async {
    if (_initialized) {
      return _readiness;
    }
    _initialized = true;
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
    await windowManager.setAlwaysOnTop(true);
    await setSurface(expanded: false);
    try {
      await _captureProvider.initialize();
    } on Object catch (error) {
      _emitWarning('Capture provider is unavailable: $error');
    }

    var contextRegistered = false;
    var imageRegistered = false;
    if (_useWaylandPortals) {
      try {
        final registration = await registerWaylandPortalShortcuts(
          _waylandPortalShortcutClient,
          onContext: () => unawaited(_captureAndEmit()),
          onImage: () => unawaited(_selectImageAndEmit()),
          onError: (error) =>
              _emitWarning('Wayland global shortcuts stopped: $error'),
        );
        _portalShortcutSubscription = registration.subscription;
        contextRegistered = registration.readiness.contextShortcut;
        imageRegistered = registration.readiness.imageShortcut;
      } on Object catch (error) {
        _emitWarning('Wayland global shortcuts are unavailable: $error');
      }
    } else {
      try {
        await hotKeyManager.register(
          _contextHotKey,
          keyDownHandler: (_) => unawaited(_captureAndEmit()),
        );
        contextRegistered = true;
        _nativeContextRegistered = true;
      } on Object catch (error) {
        _emitWarning('Alt+A could not be registered: $error');
      }
      try {
        await hotKeyManager.register(
          _imageHotKey,
          keyDownHandler: (_) => unawaited(_selectImageAndEmit()),
        );
        imageRegistered = true;
        _nativeImageRegistered = true;
      } on Object catch (error) {
        _emitWarning('Alt+Shift+A could not be registered: $error');
      }
    }
    await _configureTray();
    await _recordAcceptance('desktop.ready', {
      'contextShortcut': contextRegistered,
      'imageShortcut': imageRegistered,
    });
    _readiness = DesktopReadiness(
      contextShortcut: contextRegistered,
      imageShortcut: imageRegistered,
    );
    return _readiness;
  }

  Future<void> _captureAndEmit() async {
    try {
      // Capture completes before Flutter is shown or focused. This ordering is
      // the Invocation Context boundary and must not be reversed.
      final attachment = await captureContext();
      await _recordAcceptance('shortcut.context', {
        'attached': attachment != null,
        'application': attachment?.snapshot?['application'],
        'windowTitle': attachment?.snapshot?['windowTitle'],
      });
      _invocations.add(
        DesktopInvocation(
          kind: DesktopInvocationKind.context,
          attachment: attachment,
          message: attachment == null
              ? 'No accessible context was exposed under the pointer'
              : 'Context attached',
          warning: attachment == null,
        ),
      );
    } on Object catch (error) {
      await _recordAcceptance('shortcut.context.failed', {
        'error': error.toString(),
      });
      _invocations.add(
        DesktopInvocation(
          kind: DesktopInvocationKind.context,
          message: 'Context capture failed: $error',
          warning: true,
        ),
      );
    }
  }

  Future<void> _selectImageAndEmit() async {
    try {
      final attachment = await selectImageContext(includePointerContext: true);
      final invocation = imageSelectionInvocation(attachment);
      if (invocation == null) {
        await _recordAcceptance('shortcut.image.cancelled', const {});
        return;
      }
      await _recordAcceptance('shortcut.image', {
        'attached': true,
        'hasImage': attachment?.imageDataUrl?.isNotEmpty == true,
        'hasPointerContext': attachment?.snapshot != null,
        'width': attachment?.bounds?['width'],
        'height': attachment?.bounds?['height'],
      });
      _invocations.add(invocation);
    } on Object catch (error) {
      await _recordAcceptance('shortcut.image.failed', {
        'error': error.toString(),
      });
      _invocations.add(
        DesktopInvocation(
          kind: DesktopInvocationKind.image,
          message: 'Image selection failed: $error',
          warning: true,
        ),
      );
    }
  }

  void _emitWarning(String message) {
    if (!_invocations.isClosed) {
      _invocations.add(
        DesktopInvocation(
          kind: DesktopInvocationKind.status,
          message: message,
          warning: true,
        ),
      );
    }
  }

  Future<void> _recordAcceptance(
    String event,
    Map<String, Object?> details,
  ) async {
    try {
      await _acceptanceRecorder?.record(event, details);
    } on Object {
      // Acceptance tracing is explicitly opt-in and must never affect UX.
    }
  }

  @override
  Future<ContextAttachment?> captureContext() async {
    Offset? point;
    try {
      point = await screenRetriever.getCursorScreenPoint();
    } on Object {
      point = null;
    }
    final result = await _captureProvider.capture(point: point);
    if (result.snapshot == null) return null;
    return ContextAttachment(
      id: _nextAttachmentId(),
      token: '',
      snapshot: result.snapshot,
      previewText: result.previewText,
    );
  }

  @override
  Future<ContextAttachment?> selectImageContext({
    bool includePointerContext = false,
  }) async {
    final wasVisible = await windowManager.isVisible();
    await windowManager.hide();
    try {
      final contextFuture = includePointerContext
          ? captureContext().timeout(
              const Duration(seconds: 4),
              onTimeout: () => null,
            )
          : Future<ContextAttachment?>.value();
      final selected = await _captureProvider.selectImage();
      if (selected == null) return null;
      final context = await contextFuture;
      return ContextAttachment(
        id: _nextAttachmentId(),
        token: '',
        snapshot: context?.snapshot,
        previewText: context?.previewText ?? 'User-selected screen region',
        imageDataUrl: selected.dataUrl,
        bounds: selected.bounds,
      );
    } finally {
      if (wasVisible) await windowManager.show();
    }
  }

  @override
  Future<void> setSurface({
    required bool expanded,
    bool large = false,
    bool animate = true,
  }) async {
    final size = expanded
        ? (large ? largeWindowSize : normalWindowSize)
        : compactWindowSize;
    final displays = await screenRetriever.getAllDisplays();
    final current = await windowManager.getBounds();
    final center = current.center;
    final display = displays.cast<Display?>().firstWhere((candidate) {
      if (candidate == null) return false;
      final origin = candidate.visiblePosition ?? Offset.zero;
      final visibleSize = candidate.visibleSize ?? candidate.size;
      return (origin & visibleSize).contains(center);
    }, orElse: () => null);
    final selected = display ?? await screenRetriever.getPrimaryDisplay();
    final origin = selected.visiblePosition ?? Offset.zero;
    final workArea = selected.visibleSize ?? selected.size;
    final width = size.width.clamp(compactWindowSize.width, workArea.width);
    final height = size.height.clamp(compactWindowSize.height, workArea.height);
    final workAreaBounds = origin & workArea;
    final anchor =
        _surfaceAnchor ??
        (_surfacePositionInitialized
            ? Offset(current.center.dx, current.bottom)
            : Offset(
                workAreaBounds.center.dx,
                workAreaBounds.bottom - windowBottomInset,
              ));
    _surfaceAnchor = anchor;
    final bounds = anchoredSurfaceBounds(
      anchor: anchor,
      workArea: workAreaBounds,
      size: Size(width, height),
    );
    final shouldAnimate = _surfacePositionInitialized;
    _surfacePositionInitialized = true;
    final transitionEpoch = ++_surfaceTransitionEpoch;
    // Keeping the compact minimum during the transition prevents Win32 from
    // jumping directly to 640x500 on the first animated frame.
    await windowManager.setMinimumSize(compactWindowSize);
    if (animate && shouldAnimate) {
      final nativeResult = await animateNativeSurfaceBounds(
        from: current,
        to: bounds,
        scaleFactor: selected.scaleFactor?.toDouble() ?? 1,
      );
      if (nativeResult == null) {
        await animateSurfaceBounds(
          from: current,
          to: bounds,
          setBounds: (value) => windowManager.setBounds(value, animate: false),
          cancelled: () => transitionEpoch != _surfaceTransitionEpoch,
        );
      }
    } else {
      await windowManager.setBounds(bounds, animate: false);
    }
    if (transitionEpoch != _surfaceTransitionEpoch) return;
    await windowManager.setMinimumSize(
      expanded ? const Size(640, 500) : compactWindowSize,
    );
    await windowManager.setAlwaysOnTop(true);
  }

  @override
  Future<void> showPanel() async {
    await presentPanelWithoutResizing(
      show: windowManager.show,
      focus: windowManager.focus,
      keepOnTop: () => windowManager.setAlwaysOnTop(true),
    );
  }

  @override
  Future<void> hide() => windowManager.hide();

  @override
  Future<void> toggleMaximized() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
      await setSurface(expanded: true);
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Future<void> startDragging() async {
    await windowManager.startDragging();
    final bounds = await windowManager.getBounds();
    _surfaceAnchor = Offset(bounds.center.dx, bounds.bottom);
  }

  @override
  Future<void> openRuntimeSignIn(RuntimeTarget target) async {
    final signInArgs = switch (target.adapterId) {
      'codex-app-server' => const ['login'],
      'pi-rpc' => const ['onboard'],
      'hermes-acp' => const ['acp', '--setup'],
      'openclaw-acp' => const ['onboard'],
      _ => const <String>[],
    };
    if (target.executablePath.isEmpty || signInArgs.isEmpty) {
      throw StateError(
        '${target.displayName} has no separate sign-in command.',
      );
    }
    final host = target.executionHost;
    if (Platform.isWindows) {
      final command = host['kind'] == 'wsl' ? 'wsl.exe' : target.executablePath;
      final arguments = host['kind'] == 'wsl'
          ? [
              '-d',
              host['name']?.toString() ?? '',
              '-e',
              target.executablePath,
              ...signInArgs,
            ]
          : signInArgs;
      final process = await Process.start('wt.exe', [
        '-w',
        'new',
        command,
        ...arguments,
      ], mode: ProcessStartMode.detached);
      unawaited(process.exitCode);
      return;
    }
    if (Platform.isMacOS) {
      final command = [
        target.executablePath,
        ...signInArgs,
      ].map(_shellQuote).join(' ');
      final process = await Process.start('osascript', [
        '-e',
        'tell application "Terminal" to do script ${jsonEncode(command)}',
      ], mode: ProcessStartMode.detached);
      unawaited(process.exitCode);
      return;
    }
    final terminal = Platform.environment['TERMINAL']?.trim();
    final process = await Process.start(
      terminal?.isNotEmpty == true ? terminal! : 'x-terminal-emulator',
      ['-e', target.executablePath, ...signInArgs],
      mode: ProcessStartMode.detached,
    );
    unawaited(process.exitCode);
  }

  @override
  Future<String?> selectRuntimeExecutable() async {
    final selected = await openFile(confirmButtonText: 'Use this CLI');
    return selected?.path;
  }

  @override
  Future<void> copyText(String value) async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) {
      await Clipboard.setData(ClipboardData(text: value));
      return;
    }
    final item = DataWriterItem()..add(Formats.plainText(value));
    await clipboard.write([item]);
  }

  @override
  Future<void> copyImage(String dataUrl) async {
    final bytes = _decodeImageDataUrl(dataUrl);
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) {
      throw StateError('Image clipboard is unavailable on this desktop.');
    }
    final item = DataWriterItem(suggestedName: 'Zommi image.png')
      ..add(Formats.png(bytes));
    await clipboard.write([item]);
  }

  Future<void> _configureTray() async {
    try {
      final asset = Platform.isWindows
          ? 'windows/runner/resources/app_icon.ico'
          : 'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_32.png';
      final bytes = await rootBundle.load(asset);
      final extension = Platform.isWindows ? 'ico' : 'png';
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'zommi-tray-${pid.hashCode}.$extension',
      );
      await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      _trayIconPath = file.path;
      await trayManager.setIcon(file.path, isTemplate: Platform.isMacOS);
      await trayManager.setToolTip('Zommi floating agent chat');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'open', label: 'Open floating chat'),
            MenuItem(key: 'capture', label: 'Capture context (Alt+A)'),
            MenuItem(
              key: 'image',
              label: 'Select image + pointer context (Alt+Shift+A)',
            ),
            MenuItem.separator(),
            MenuItem(key: 'exit', label: 'Exit Zommi'),
          ],
        ),
      );
      trayManager.addListener(this);
    } on Object catch (error) {
      _emitWarning('Tray integration is unavailable: $error');
    }
  }

  @override
  void onTrayIconMouseDown() {
    _invocations.add(const DesktopInvocation(kind: DesktopInvocationKind.open));
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(
      showExplicitTrayContextMenu(
        operatingSystem: Platform.operatingSystem,
        show: () => trayManager.popUpContextMenu(),
      ),
    );
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open':
        onTrayIconMouseDown();
      case 'capture':
        unawaited(_captureAndEmit());
      case 'image':
        unawaited(_selectImageAndEmit());
      case 'exit':
        unawaited(windowManager.destroy());
    }
  }

  @override
  void onWindowClose() {
    unawaited(windowManager.hide());
  }

  @override
  void onWindowFocus() {
    unawaited(windowManager.setAlwaysOnTop(true));
  }

  @override
  Future<void> close() async {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    await _portalShortcutSubscription?.cancel();
    await _waylandPortalShortcutClient.close();
    if (_nativeContextRegistered) {
      await hotKeyManager.unregister(_contextHotKey);
    }
    if (_nativeImageRegistered) {
      await hotKeyManager.unregister(_imageHotKey);
    }
    await trayManager.destroy();
    await _captureProvider.close();
    if (_trayIconPath case final path?) {
      try {
        await File(path).delete();
      } on Object {
        // The OS may retain the tray file until process exit.
      }
    }
    if (!_invocations.isClosed) await _invocations.close();
  }
}

Future<void> presentPanelWithoutResizing({
  required Future<void> Function() show,
  required Future<void> Function() focus,
  required Future<void> Function() keepOnTop,
}) async {
  await show();
  await focus();
  await keepOnTop();
}

Rect anchoredSurfaceBounds({
  required Offset anchor,
  required Rect workArea,
  required Size size,
}) {
  final maxLeft = math.max(workArea.left, workArea.right - size.width);
  final maxTop = math.max(workArea.top, workArea.bottom - size.height);
  final left = (anchor.dx - size.width / 2).clamp(workArea.left, maxLeft);
  final top = (anchor.dy - size.height).clamp(workArea.top, maxTop);
  return Rect.fromLTWH(left, top, size.width, size.height);
}

Future<bool?> animateNativeSurfaceBounds({
  required Rect from,
  required Rect to,
  required double scaleFactor,
  Duration duration = surfaceTransitionDuration,
}) async {
  if (!Platform.isWindows) return null;
  try {
    return await _windowAnimationChannel.invokeMethod<bool>('animateBounds', {
      'fromX': from.left,
      'fromY': from.top,
      'fromWidth': from.width,
      'fromHeight': from.height,
      'toX': to.left,
      'toY': to.top,
      'toWidth': to.width,
      'toHeight': to.height,
      'scaleFactor': scaleFactor,
      'durationMs': duration.inMilliseconds,
    });
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

Future<void> configureNativeSurfaceWindow() async {
  if (!Platform.isWindows) return;
  try {
    await _windowAnimationChannel.invokeMethod<void>('configureSurfaceWindow');
  } on MissingPluginException {
    // Non-Windows and test runners do not install the custom Win32 host.
  } on PlatformException {
    // The app still remains usable; packaged acceptance verifies the exact
    // frameless endpoint so release builds cannot silently keep this fallback.
  }
}

Future<void> animateSurfaceBounds({
  required Rect from,
  required Rect to,
  required Future<void> Function(Rect value) setBounds,
  required bool Function() cancelled,
  Duration duration = surfaceTransitionDuration,
  int frames = surfaceTransitionFrameCount,
}) async {
  if (from == to || duration == Duration.zero || frames <= 1) {
    if (!cancelled()) await setBounds(to);
    return;
  }
  final stopwatch = Stopwatch()..start();
  for (var frame = 1; frame <= frames; frame++) {
    if (cancelled()) return;
    final deadline = duration * (frame / frames);
    final remaining = deadline - stopwatch.elapsed;
    if (remaining > Duration.zero) await Future<void>.delayed(remaining);
    if (cancelled()) return;
    final linear = frame / frames;
    final eased = 1 - math.pow(1 - linear, 3).toDouble();
    await setBounds(Rect.lerp(from, to, eased)!);
  }
}

bool supportsNativeWindowShadow(String operatingSystem) =>
    operatingSystem == 'windows' || operatingSystem == 'macos';

bool supportsExplicitTrayContextMenu(String operatingSystem) =>
    operatingSystem == 'windows' || operatingSystem == 'linux';

Future<void> showExplicitTrayContextMenu({
  required String operatingSystem,
  required Future<void> Function() show,
}) async {
  if (supportsExplicitTrayContextMenu(operatingSystem)) await show();
}

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
  required void Function() onImage,
  required void Function(Object error) onError,
}) async {
  final subscription = client.activations.listen((shortcut) {
    switch (shortcut) {
      case 'context':
        onContext();
      case 'image':
        onImage();
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
              if (shortcut == 'context' || shortcut == 'image') {
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

abstract interface class CaptureProvider {
  Future<void> initialize();

  Future<CaptureResult> capture({Offset? point});

  Future<ImageSelection?> selectImage();

  Future<void> close();
}

final class CaptureResult {
  const CaptureResult({this.snapshot, this.previewText = ''});

  final Map<String, Object?>? snapshot;
  final String previewText;
}

final class ImageSelection {
  const ImageSelection({required this.dataUrl, this.bounds});

  final String dataUrl;
  final Map<String, Object?>? bounds;
}

CaptureProvider platformCaptureProvider() => Platform.isWindows
    ? WindowsCaptureProvider()
    : Platform.isLinux
    ? LinuxCaptureProvider(
        useWaylandPortals: shouldUseWaylandPortals(Platform.environment),
      )
    : PortableCaptureProvider();

final class WindowsCaptureProvider implements CaptureProvider {
  WindowsCaptureProvider({
    String? executablePath,
    NativeCaptureClient? captureClient,
    NativeCaptureClient? selectorClient,
  }) : _captureClient =
           captureClient ??
           _NativeCaptureHost(executablePath ?? _nativeHostPath()),
       _selectorClient =
           selectorClient ??
           _NativeCaptureHost(executablePath ?? _nativeHostPath());

  final NativeCaptureClient _captureClient;
  final NativeCaptureClient _selectorClient;

  @override
  Future<void> initialize() async {
    // The native host handles requests synchronously. Keep image selection on
    // a separate prewarmed process so slow UIA capture cannot delay the region
    // selector that the user is already trying to drag.
    await Future.wait([
      _captureClient.request('ping'),
      _selectorClient.request('ping'),
    ]);
  }

  @override
  Future<CaptureResult> capture({Offset? point}) async {
    final response = await _captureClient.request('capture', {
      if (point != null)
        'point': {'x': point.dx.round(), 'y': point.dy.round()},
    });
    return CaptureResult(
      snapshot: _nullableMap(response['snapshot']),
      previewText: response['previewText']?.toString() ?? '',
    );
  }

  @override
  Future<ImageSelection?> selectImage() async {
    final response = await _selectorClient.request('selectImage');
    if (response['cancelled'] == true) return null;
    final dataUrl = response['dataUrl']?.toString() ?? '';
    if (dataUrl.isEmpty) return null;
    return ImageSelection(
      dataUrl: dataUrl,
      bounds: _nullableMap(response['bounds']),
    );
  }

  @override
  Future<void> close() async {
    await Future.wait([_captureClient.close(), _selectorClient.close()]);
  }
}

typedef CaptureCommandRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
  Duration timeout,
);

final class LinuxCaptureProvider implements CaptureProvider {
  LinuxCaptureProvider({
    String? executablePath,
    CaptureCommandRunner? runCommand,
    bool? useWaylandPortals,
  }) : _executablePath = executablePath ?? resolveLinuxCaptureExecutable(),
       _runCommand = runCommand ?? _runProcess,
       _useWaylandPortals =
           useWaylandPortals ?? shouldUseWaylandPortals(Platform.environment);

  final String _executablePath;
  final CaptureCommandRunner _runCommand;
  final bool _useWaylandPortals;

  @override
  Future<void> initialize() async {}

  @override
  Future<CaptureResult> capture({Offset? point}) async {
    final response = await _request([
      _useWaylandPortals ? 'portal-context' : 'context',
    ], const Duration(seconds: 5));
    return portableCaptureResult(
      application:
          response['application']?.toString() ??
          (_useWaylandPortals ? 'Linux desktop' : 'X11 application'),
      processName: response['processName']?.toString(),
      windowTitle: response['windowTitle']?.toString() ?? '',
      url: '',
      limitation:
          response['limitation']?.toString() ??
          'X11 semantic enrichment depends on AT-SPI.',
    );
  }

  @override
  Future<ImageSelection?> selectImage() async {
    final temporary = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'zommi-region-${DateTime.now().microsecondsSinceEpoch}.png',
    );
    try {
      final response = await _request([
        _useWaylandPortals ? 'portal-region' : 'region',
        '--output',
        temporary.path,
      ], const Duration(minutes: 5));
      if (response['cancelled'] == true) return null;
      if (!await temporary.exists()) {
        throw StateError('The Linux selector did not produce an image.');
      }
      final bytes = await temporary.readAsBytes();
      if (bytes.isEmpty) {
        throw StateError('The Linux selector produced an empty image.');
      }
      return ImageSelection(
        dataUrl: 'data:image/png;base64,${base64Encode(bytes)}',
        bounds: _nullableMap(response['bounds']),
      );
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<Map<String, Object?>> _request(
    List<String> arguments,
    Duration timeout,
  ) async {
    final result = await _runCommand(_executablePath, arguments, timeout);
    if (result.exitCode != 0) {
      throw StateError(
        'Linux capture failed: ${result.stderr.toString().trim()}',
      );
    }
    for (final line in result.stdout.toString().split('\n').reversed) {
      if (line.trim().isEmpty) continue;
      try {
        final value = jsonDecode(line);
        final mapped = _nullableMap(value);
        if (mapped != null) return mapped;
      } on FormatException {
        continue;
      }
    }
    throw StateError('Linux capture returned no JSON result.');
  }

  static Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments,
    Duration timeout,
  ) => Process.run(executable, arguments).timeout(timeout);

  @override
  Future<void> close() async {}
}

final class PortableCaptureProvider implements CaptureProvider {
  @override
  Future<void> initialize() async {}

  @override
  Future<CaptureResult> capture({Offset? point}) async {
    return _captureMac();
  }

  Future<CaptureResult> _captureMac() async {
    const script = '''
tell application "System Events"
  set frontProcess to first application process whose frontmost is true
  set appName to name of frontProcess
  set windowTitle to ""
  try
    set windowTitle to name of front window of frontProcess
  end try
end tell
set pageUrl to ""
if appName is "Safari" then
  tell application "Safari" to set pageUrl to URL of front document
else if appName is "Google Chrome" or appName is "Microsoft Edge" or appName is "Brave Browser" then
  tell application appName to set pageUrl to URL of active tab of front window
end if
return appName & linefeed & windowTitle & linefeed & pageUrl
''';
    final result = await Process.run('osascript', const [
      '-e',
      script,
    ]).timeout(const Duration(seconds: 5));
    if (result.exitCode != 0) {
      throw StateError('macOS foreground capture failed: ${result.stderr}');
    }
    final fields = result.stdout.toString().trimRight().split('\n');
    return portableCaptureResult(
      application: fields.isEmpty ? 'macOS application' : fields[0],
      windowTitle: fields.length > 1 ? fields[1] : '',
      url: fields.length > 2 ? fields[2] : '',
      limitation: 'macOS captures the front application, title, and supported browser URL. Accessibility enrichment depends on permission.',
    );
  }

  @override
  Future<ImageSelection?> selectImage() async {
    final temporary = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'zommi-region-${DateTime.now().microsecondsSinceEpoch}.png',
    );
    try {
      final captured = await screenCapturer.capture(
        mode: CaptureMode.region,
        imagePath: temporary.path,
        copyToClipboard: false,
        silent: true,
      );
      final imageBytes = captured?.imageBytes;
      if (captured == null || imageBytes == null || imageBytes.isEmpty) {
        return null;
      }
      return ImageSelection(
        dataUrl: 'data:image/png;base64,${base64Encode(imageBytes)}',
        bounds: {
          'x': 0,
          'y': 0,
          'width': captured.imageWidth,
          'height': captured.imageHeight,
        },
      );
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  @override
  Future<void> close() async {}
}

CaptureResult portableCaptureResult({
  required String application,
  String? processName,
  required String windowTitle,
  required String url,
  required String limitation,
}) {
  final now = DateTime.now().toUtc();
  final snapshot = <String, Object?>{
    'snapshotId': _nextAttachmentId(),
    'observedAtUtc': now.toIso8601String(),
    'expiresAtUtc': now.add(const Duration(seconds: 30)).toIso8601String(),
    'surfaceKind': url.isEmpty ? 'Window' : 'Browser',
    'application': application,
    'processName':
        processName ?? application.toLowerCase().replaceAll(' ', '-'),
    'windowTitle': windowTitle.isEmpty ? null : windowTitle,
    'locator': url.isEmpty ? null : {'kind': 'URL', 'value': url},
    'selection': <Object?>[],
    'visibleText': <Object?>[],
    'accessibilityTree': null,
    'indicatedTarget': null,
    'confidence': url.isNotEmpty || windowTitle.isNotEmpty
        ? 'medium'
        : 'limited',
    'limitation': limitation,
  };
  final preview = [
    'Surface: ${snapshot['surfaceKind']} in $application',
    if (windowTitle.isNotEmpty) 'Window: $windowTitle',
    if (url.isNotEmpty) 'URL: $url',
    'Limitation: $limitation',
  ].join('\n');
  return CaptureResult(snapshot: snapshot, previewText: preview);
}

String resolveLinuxCaptureExecutable({
  String? configured,
  Map<String, String>? environment,
  String? resolvedExecutable,
  String? applicationDirectory,
  String? pathSeparator,
  bool Function(String path)? exists,
}) {
  if (configured?.trim().isNotEmpty == true) return configured!.trim();
  final processEnvironment = environment ?? Platform.environment;
  final environmentPath = processEnvironment['ZOMMI_X11_CAPTURE_HOST']?.trim();
  if (environmentPath?.isNotEmpty == true) return environmentPath!;
  final separator = pathSeparator ?? Platform.pathSeparator;
  final executableDirectory =
      applicationDirectory ??
      File(resolvedExecutable ?? Platform.resolvedExecutable).parent.path;
  final candidate = '$executableDirectory${separator}zommi-x11-capture';
  if (exists?.call(candidate) ?? File(candidate).existsSync()) return candidate;
  return 'zommi-x11-capture';
}

abstract interface class NativeCaptureClient {
  Future<Map<String, Object?>> request(
    String method, [
    Map<String, Object?> parameters = const {},
  ]);

  Future<void> close();
}

final class _NativeCaptureHost implements NativeCaptureClient {
  _NativeCaptureHost(this.executablePath);

  final String executablePath;
  final Map<String, Completer<Map<String, Object?>>> _pending = {};
  Process? _process;
  StreamSubscription<String>? _stdout;
  StreamSubscription<String>? _stderr;
  int _nextId = 0;
  String _recentError = '';

  @override
  Future<Map<String, Object?>> request(
    String method, [
    Map<String, Object?> parameters = const {},
  ]) async {
    await _ensureStarted();
    final process = _process;
    if (process == null) {
      throw StateError('Windows capture host is unavailable.');
    }
    final id = (++_nextId).toString();
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    process.stdin.writeln(
      jsonEncode({'id': id, 'method': method, 'params': parameters}),
    );
    await process.stdin.flush();
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException(
          'Windows capture host timed out during $method.',
        );
      },
    );
  }

  Future<void> _ensureStarted() async {
    if (_process != null) return;
    if (!await File(executablePath).exists()) {
      throw StateError(
        'Windows capture host was not found at $executablePath.',
      );
    }
    final process = await Process.start(executablePath, const [
      '--capture-host',
    ], runInShell: false);
    _process = process;
    _stdout = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleLine);
    _stderr = process.stderr.transform(utf8.decoder).listen((chunk) {
      _recentError = '$_recentError$chunk';
      if (_recentError.length > 2000) {
        _recentError = _recentError.substring(_recentError.length - 2000);
      }
    });
    unawaited(
      process.exitCode.then((code) {
        if (identical(_process, process)) _process = null;
        final error = StateError(
          'Windows capture host exited with code $code.'
          '${_recentError.trim().isEmpty ? '' : ' ${_recentError.trim()}'}',
        );
        for (final pending in _pending.values) {
          pending.completeError(error);
        }
        _pending.clear();
      }),
    );
  }

  void _handleLine(String line) {
    try {
      final value = jsonDecode(line);
      if (value is! Map) return;
      final json = value.map((key, value) => MapEntry(key.toString(), value));
      final id = json['id']?.toString();
      final completer = id == null ? null : _pending.remove(id);
      if (completer == null) return;
      if (json['ok'] == true) {
        completer.complete(_nullableMap(json['result']) ?? <String, Object?>{});
      } else {
        completer.completeError(
          StateError(json['error']?.toString() ?? 'Capture request failed.'),
        );
      }
    } on Object catch (error, stackTrace) {
      for (final pending in _pending.values) {
        pending.completeError(error, stackTrace);
      }
      _pending.clear();
    }
  }

  @override
  Future<void> close() async {
    final process = _process;
    if (process != null) {
      try {
        await request('shutdown').timeout(const Duration(seconds: 2));
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on Object {
        process.kill();
      }
    }
    await _stdout?.cancel();
    await _stderr?.cancel();
    _process = null;
  }
}

String _nativeHostPath() {
  final configured = Platform.environment['ZOMMI_NATIVE_HOST_PATH'];
  if (configured != null && configured.trim().isNotEmpty) return configured;
  final root = File(Platform.resolvedExecutable).parent.path;
  final candidates = [
    '$root${Platform.pathSeparator}native'
        '${Platform.pathSeparator}Zommi.Capture.exe',
  ];
  return candidates.firstWhere(
    (candidate) => File(candidate).existsSync(),
    orElse: () => candidates.first,
  );
}

Map<String, Object?>? _nullableMap(Object? value) {
  if (value == null) return null;
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return null;
}

Uint8List _decodeImageDataUrl(String value) {
  final separator = value.indexOf(',');
  if (!value.startsWith('data:image/') || separator < 0) {
    throw const FormatException('Only inline image data can be copied.');
  }
  return base64Decode(
    value.substring(separator + 1).replaceAll(RegExp(r'\s'), ''),
  );
}

int _attachmentSequence = 0;

String _nextAttachmentId() =>
    'capture-${DateTime.now().microsecondsSinceEpoch}-${++_attachmentSequence}';

String _shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";
