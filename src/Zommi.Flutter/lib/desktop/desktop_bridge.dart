import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart'
    show WidgetsBinding, WidgetsBindingObserver;
import 'package:file_selector/file_selector.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:screen_capturer/screen_capturer.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:url_launcher/url_launcher.dart';
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

double symmetricSurfaceEase(double progress) {
  final value = progress.clamp(0.0, 1.0);
  return value < 0.5
      ? 4 * value * value * value
      : 1 - math.pow(-2 * value + 2, 3).toDouble() / 2;
}

Rect pixelAlignedSurfaceBounds(Rect bounds, double scale) => Rect.fromLTRB(
  (bounds.left * scale).round() / scale,
  (bounds.top * scale).round() / scale,
  (bounds.right * scale).round() / scale,
  (bounds.bottom * scale).round() / scale,
);

enum DesktopInvocationKind { open, captureStarted, context, image, status }

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

DesktopInvocation imageSelectionInvocation(ContextAttachment? attachment) {
  if (attachment == null) {
    return const DesktopInvocation(kind: DesktopInvocationKind.image);
  }
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

abstract interface class BrowserCaptureSettings {
  bool get supportsBrowserPageDetails;
  void setBrowserPageDetails(bool enabled);
}

abstract interface class DesktopBridge {
  Stream<DesktopInvocation> get invocations;

  Future<DesktopReadiness> initialize();

  Future<ContextAttachment?> captureContext({bool hidePanel = false});

  Future<ContextAttachment?> selectPointerContext();

  Future<ContextAttachment?> selectImageContext({
    bool includePointerContext = false,
  });

  Future<void> setSurface({
    required bool expanded,
    bool large = false,
    bool maximized = false,
    bool animate = true,
  });

  Future<bool> isPointerWithinSurface();

  Future<void> showPanel({bool focus = true});

  Future<void> hide();

  Future<void> toggleMaximized();

  Future<void> startDragging();

  Future<void> openRuntimeSignIn(RuntimeTarget target);

  Future<String?> selectRuntimeExecutable();

  Future<String?> selectWorkspaceDirectory();

  Future<void> copyText(String value);

  Future<void> copyImage(String dataUrl);

  Future<void> openExternalUrl(Uri uri);

  Future<void> close();
}

final class NoopDesktopBridge implements DesktopBridge {
  const NoopDesktopBridge();

  @override
  Stream<DesktopInvocation> get invocations => const Stream.empty();

  @override
  Future<DesktopReadiness> initialize() async => const DesktopReadiness();

  @override
  Future<ContextAttachment?> captureContext({bool hidePanel = false}) async =>
      null;

  @override
  Future<ContextAttachment?> selectPointerContext() async => null;

  @override
  Future<ContextAttachment?> selectImageContext({
    bool includePointerContext = false,
  }) async => null;

  @override
  Future<void> setSurface({
    required bool expanded,
    bool large = false,
    bool maximized = false,
    bool animate = true,
  }) async {}

  @override
  Future<bool> isPointerWithinSurface() async => false;

  @override
  Future<void> showPanel({bool focus = true}) async {}

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
  Future<String?> selectWorkspaceDirectory() async => null;

  @override
  Future<void> copyText(String value) =>
      Clipboard.setData(ClipboardData(text: value));

  @override
  Future<void> copyImage(String dataUrl) async {}

  @override
  Future<void> openExternalUrl(Uri uri) async {}

  @override
  Future<void> close() async {}
}

final class FlutterDesktopBridge
    with WindowListener, TrayListener, WidgetsBindingObserver
    implements DesktopBridge, BrowserCaptureSettings {
  FlutterDesktopBridge({
    CaptureProvider? captureProvider,
    DesktopAcceptanceRecorder? acceptanceRecorder,
    WaylandPortalShortcutClient? waylandPortalShortcutClient,
    bool? useWaylandPortals,
    bool? useNativeSurface,
  }) : _captureProvider = captureProvider ?? platformCaptureProvider(),
       _useNativeSurface = useNativeSurface ?? Platform.isWindows,
       _waylandPortalShortcutClient =
           waylandPortalShortcutClient ??
           ProcessWaylandPortalShortcutClient(resolveLinuxCaptureExecutable()),
       _useWaylandPortals =
           useWaylandPortals ??
           (Platform.isLinux && shouldUseWaylandPortals(Platform.environment)),
       _acceptanceRecorder =
           acceptanceRecorder ??
           FileDesktopAcceptanceRecorder.fromEnvironment();

  final bool _useNativeSurface;

  static Future<FlutterDesktopBridge> bootstrap() async {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: normalWindowSize,
      minimumSize: Size(640, 500),
      backgroundColor: Color(0x00000000),
      alwaysOnTop: false,
      skipTaskbar: false,
      title: 'Zommi',
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.setAsFrameless();
      if (supportsNativeWindowShadow(Platform.operatingSystem)) {
        await windowManager.setHasShadow(false);
      }
      await windowManager.setResizable(false);
      await configureNativeSurfaceWindow();
      await windowManager.setSize(normalWindowSize, animate: false);
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setSkipTaskbar(false);
    });
    return FlutterDesktopBridge();
  }

  @override
  bool get supportsBrowserPageDetails =>
      _captureProvider is BrowserCaptureSettings;

  @override
  void setBrowserPageDetails(bool enabled) {
    final provider = _captureProvider;
    if (provider case final BrowserCaptureSettings settings) {
      settings.setBrowserPageDetails(enabled);
    }
  }

  final CaptureProvider _captureProvider;
  bool _invocationPending = false;
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
  Future<void> _surfaceResizeQueue = Future<void>.value();
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
    if (_useNativeSurface) WidgetsBinding.instance.addObserver(this);
    windowManager.addListener(this);
    await windowManager.setPreventClose(false);
    await windowManager.setAlwaysOnTop(false);
    await setSurface(expanded: true, animate: false);
    await windowManager.show();
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
          onContext: () =>
              unawaited(invokeShortcut(DesktopInvocationKind.context)),
          onImage: () => unawaited(invokeShortcut(DesktopInvocationKind.image)),
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
          keyDownHandler: (_) =>
              unawaited(invokeShortcut(DesktopInvocationKind.context)),
        );
        contextRegistered = true;
        _nativeContextRegistered = true;
      } on Object catch (error) {
        _emitWarning('Alt+A could not be registered: $error');
      }
      try {
        await hotKeyManager.register(
          _imageHotKey,
          keyDownHandler: (_) =>
              unawaited(invokeShortcut(DesktopInvocationKind.image)),
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

  Future<void> invokeShortcut(DesktopInvocationKind kind) => switch (kind) {
    DesktopInvocationKind.context => _captureAndEmit(),
    DesktopInvocationKind.image => _selectImageAndEmit(),
    _ => Future.error(
      ArgumentError.value(kind, 'kind', 'Not a capture shortcut'),
    ),
  };

  Future<void> _captureAndEmit() async {
    if (_invocationPending) return;
    _invocationPending = true;
    final clock = Stopwatch()..start();
    try {
      final attachment = await _capturePointerContext(
        onReady: () {
          if (_invocations.isClosed) return;
          unawaited(
            _recordAcceptance('shortcut.context.ready', {
              'elapsedMilliseconds': clock.elapsedMilliseconds,
            }),
          );
          _invocations.add(
            const DesktopInvocation(
              kind: DesktopInvocationKind.captureStarted,
              message: 'Capturing context…',
            ),
          );
        },
      );
      await _recordAcceptance('shortcut.context', {
        'elapsedMilliseconds': clock.elapsedMilliseconds,
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
    } finally {
      _invocationPending = false;
    }
  }

  Future<void> _selectImageAndEmit() async {
    if (_invocationPending) return;
    _invocationPending = true;
    final clock = Stopwatch()..start();
    try {
      final attachment = await selectImageContext(includePointerContext: true);
      final invocation = imageSelectionInvocation(attachment);
      if (attachment == null) {
        await _recordAcceptance('shortcut.image.cancelled', const {});
        _invocations.add(invocation);
        return;
      }
      await _recordAcceptance('shortcut.image', {
        'elapsedMilliseconds': clock.elapsedMilliseconds,
        'attached': true,
        'hasImage': attachment.imageDataUrl?.isNotEmpty == true,
        'hasAlignedContext':
            _nullableMap(attachment.snapshot?['region'])?['status'] ==
            'aligned',
        'alignmentStatus': _nullableMap(
          attachment.snapshot?['region'],
        )?['status'],
        'width': attachment.bounds?['width'],
        'height': attachment.bounds?['height'],
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
    } finally {
      _invocationPending = false;
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
  Future<ContextAttachment?> captureContext({bool hidePanel = false}) async {
    if (!hidePanel) return _capturePointerContext();
    final wasVisible = await windowManager.isVisible();
    final wasMinimized = await windowManager.isMinimized();
    await windowManager.hide();
    try {
      // Let the compositor expose the application underneath Zommi before
      // resolving the window and accessibility element at the pointer.
      await Future<void>.delayed(const Duration(milliseconds: 90));
      return await _capturePointerContext();
    } finally {
      await _restorePanelAfterCapture(
        wasVisible: wasVisible,
        wasMinimized: wasMinimized,
      );
    }
  }

  @override
  Future<ContextAttachment?> selectPointerContext() async {
    final wasVisible = await windowManager.isVisible();
    final wasMinimized = await windowManager.isMinimized();
    await windowManager.hide();
    try {
      // The explicit picker owns the next click and changes the system cursor,
      // so selecting context from the composer cannot feel like an immediate,
      // invisible capture of the old pointer position.
      await Future<void>.delayed(const Duration(milliseconds: 90));
      final result = await _captureProvider.selectContext();
      if (result?.image case final image?) {
        return imageAttachmentFromSelection(image, _nextAttachmentId());
      }
      if (result?.snapshot == null) return null;
      return ContextAttachment(
        id: _nextAttachmentId(),
        token: '',
        snapshot: result!.snapshot,
        previewText: result.previewText,
      );
    } finally {
      await _restorePanelAfterCapture(
        wasVisible: wasVisible,
        wasMinimized: wasMinimized,
      );
    }
  }

  Future<ContextAttachment?> _capturePointerContext({
    void Function()? onReady,
  }) async {
    Offset? point;
    try {
      final pixelRatio = _captureProvider is WindowsCaptureProvider
          ? WidgetsBinding
                .instance
                .platformDispatcher
                .views
                .single
                .devicePixelRatio
          : 1.0;
      point = (await screenRetriever.getCursorScreenPoint()) * pixelRatio;
    } on Object {
      point = null;
    }
    final result = await _captureProvider.capture(
      point: point,
      onReady: onReady,
    );
    if (result.snapshot == null) return null;
    return ContextAttachment(
      id: _nextAttachmentId(),
      token: '',
      snapshot: result.snapshot,
      previewText: result.previewText,
    );
  }

  Future<void> _restorePanelAfterCapture({
    required bool wasVisible,
    required bool wasMinimized,
  }) async {
    if (!wasVisible && !wasMinimized) return;
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await showPanel();
  }

  @override
  Future<ContextAttachment?> selectImageContext({
    bool includePointerContext = false,
  }) async {
    final wasVisible = await windowManager.isVisible();
    final wasMinimized = await windowManager.isMinimized();
    await windowManager.hide();
    try {
      // Structural context belongs to the final image region. The pointer at
      // shortcut time may be in a different window entirely.
      final selected = await _captureProvider.selectImage();
      if (selected == null) return null;
      await showPanel();
      await _recordAcceptance('capture.image.presented', const {});
      return imageAttachmentFromSelection(selected, _nextAttachmentId());
    } finally {
      await _restorePanelAfterCapture(
        wasVisible: wasVisible,
        wasMinimized: wasMinimized,
      );
    }
  }

  @override
  Future<void> setSurface({
    required bool expanded,
    bool large = false,
    bool maximized = false,
    bool animate = true,
  }) {
    final transitionEpoch = ++_surfaceTransitionEpoch;
    final operation = _surfaceResizeQueue.catchError((Object _) {}).then<void>((
      _,
    ) async {
      if (transitionEpoch != _surfaceTransitionEpoch) return;
      return _setSurface(
        expanded: expanded,
        large: large,
        maximized: maximized,
        animate: animate,
        transitionEpoch: transitionEpoch,
      );
    });
    _surfaceResizeQueue = operation;
    return operation;
  }

  Future<void> _setSurface({
    required bool expanded,
    required bool large,
    required bool maximized,
    required bool animate,
    required int transitionEpoch,
  }) async {
    if (expanded && maximized && !animate && !_useNativeSurface) {
      await windowManager.setMinimumSize(const Size(640, 500));
      await windowManager.maximize();
      await windowManager.setAlwaysOnTop(false);
      return;
    }
    final nativeGeometry = _useNativeSurface
        ? await readNativeSurfaceGeometry(_windowAnimationChannel)
        : null;
    final wasMaximized =
        nativeGeometry?.maximized ?? await windowManager.isMaximized();
    final size = expanded
        ? (large ? largeWindowSize : normalWindowSize)
        : compactWindowSize;
    final displays = nativeGeometry == null
        ? await screenRetriever.getAllDisplays()
        : const <Display>[];
    final current = nativeGeometry?.bounds ?? await windowManager.getBounds();
    final center = current.center;
    final display = displays.cast<Display?>().firstWhere((candidate) {
      if (candidate == null) return false;
      final origin = candidate.visiblePosition ?? Offset.zero;
      final visibleSize = candidate.visibleSize ?? candidate.size;
      return (origin & visibleSize).contains(center);
    }, orElse: () => null);
    final selected = nativeGeometry == null
        ? display ?? await screenRetriever.getPrimaryDisplay()
        : null;
    final origin =
        nativeGeometry?.workArea.topLeft ??
        selected?.visiblePosition ??
        Offset.zero;
    final workArea =
        nativeGeometry?.workArea.size ??
        selected!.visibleSize ??
        selected!.size;
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
    final bounds = expanded && maximized
        ? workAreaBounds
        : anchoredSurfaceBounds(
            anchor: anchor,
            workArea: workAreaBounds,
            size: Size(width, height),
          );
    if (transitionEpoch != _surfaceTransitionEpoch) return;
    final shouldAnimate = _surfacePositionInitialized;
    _surfacePositionInitialized = true;
    // Keeping the compact minimum during the transition prevents Win32 from
    // jumping directly to 640x500 on the first animated frame.
    if (!expanded || !_useNativeSurface) {
      await windowManager.setMinimumSize(compactWindowSize);
    }
    var nativeMaximized = false;
    if (_useNativeSurface) {
      final scale = nativeGeometry!.scale;
      final targetMaximized = expanded && maximized;
      await setNativeSurfaceBounds(
        bounds: pixelAlignedSurfaceBounds(bounds, scale),
        scaleFactor: scale,
        maximized: targetMaximized,
      );
      nativeMaximized = targetMaximized;
    } else if (animate && shouldAnimate) {
      if (!(expanded && maximized)) {
        if (wasMaximized) {
          await windowManager.unmaximize();
          await windowManager.setBounds(current, animate: false);
        }
        await animateSurfaceBounds(
          from: current,
          to: bounds,
          setBounds: (value) => windowManager.setBounds(value, animate: false),
          cancelled: () => transitionEpoch != _surfaceTransitionEpoch,
        );
      }
    } else {
      if (wasMaximized) await windowManager.unmaximize();
      await windowManager.setBounds(bounds, animate: false);
    }
    if (transitionEpoch != _surfaceTransitionEpoch) return;
    await windowManager.setMinimumSize(
      expanded ? const Size(640, 500) : compactWindowSize,
    );
    if (expanded && maximized && !nativeMaximized) {
      await windowManager.maximize();
    }
    await windowManager.setAlwaysOnTop(false);
  }

  @override
  Future<void> showPanel({bool focus = true}) async {
    if (await presentNativePanel(focus: focus) == true) return;
    if (!focus) {
      await windowManager.show(inactive: true);
      return;
    }
    await presentPanelWithoutResizing(
      show: () async {
        if (await windowManager.isMinimized()) await windowManager.restore();
        await windowManager.show();
      },
      focus: windowManager.focus,
      keepOnTop: () => windowManager.setAlwaysOnTop(false),
    );
  }

  @override
  Future<void> hide() => windowManager.minimize();

  @override
  Future<void> toggleMaximized() async {
    if (_useNativeSurface) {
      ++_surfaceTransitionEpoch;
      final operation = _surfaceResizeQueue
          .catchError((Object _) {})
          .then<void>(
            (_) => _windowAnimationChannel.invokeMethod<void>(
              'toggleSurfaceMaximized',
            ),
          );
      _surfaceResizeQueue = operation;
      await operation;
      return;
    }
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
      await setSurface(expanded: true);
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Future<bool> isPointerWithinSurface() async {
    final nativeResult = await isPointerWithinNativeSurface();
    if (nativeResult != null) return nativeResult;
    try {
      final pointer = await screenRetriever.getCursorScreenPoint();
      final bounds = await windowManager.getBounds();
      return bounds.contains(pointer);
    } on Object {
      return false;
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
  Future<String?> selectWorkspaceDirectory() =>
      getDirectoryPath(confirmButtonText: 'Use this workspace');

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

  @override
  Future<void> openExternalUrl(Uri uri) async {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw StateError('The default browser could not open $uri.');
    }
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
      await trayManager.setToolTip('Zommi agent chat');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'open', label: 'Open Zommi'),
            MenuItem(key: 'capture', label: 'Capture context (Alt+A)'),
            MenuItem(key: 'image', label: 'Select image region (Alt+Shift+A)'),
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
        unawaited(invokeShortcut(DesktopInvocationKind.context));
      case 'image':
        unawaited(invokeShortcut(DesktopInvocationKind.image));
      case 'exit':
        unawaited(windowManager.destroy());
    }
  }

  @override
  void onWindowClose() {}

  @override
  void onWindowFocus() {}

  @override
  void didChangeMetrics() {
    if (!_useNativeSurface) return;
    final size =
        WidgetsBinding.instance.platformDispatcher.views.single.physicalSize;
    unawaited(
      _windowAnimationChannel
          .invokeMethod<void>('surfaceMetricsChanged', {
            'width': size.width,
            'height': size.height,
          })
          .catchError((Object error) {
            _emitWarning('Window resize feedback failed: $error');
          }),
    );
  }

  @override
  Future<void> close() async {
    WidgetsBinding.instance.removeObserver(this);
    _windowAnimationChannel.setMethodCallHandler(null);
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

Future<({Rect bounds, Rect workArea, double scale, bool maximized})>
readNativeSurfaceGeometry(MethodChannel channel) async {
  final values = await channel.invokeMapMethod<String, Object?>(
    'getSurfaceGeometry',
  );
  if (values == null) {
    throw StateError('Native window geometry is unavailable.');
  }
  Rect rectangle(String name) {
    final parts = (values[name] as List<Object?>).cast<num>();
    return Rect.fromLTWH(
      parts[0].toDouble(),
      parts[1].toDouble(),
      parts[2].toDouble(),
      parts[3].toDouble(),
    );
  }

  return (
    bounds: rectangle('bounds'),
    workArea: rectangle('workArea'),
    scale: (values['scale'] as num).toDouble(),
    maximized: values['maximized'] == true,
  );
}

Future<bool?> presentNativePanel({
  bool focus = true,
  bool? platformIsWindows,
}) async {
  if (!(platformIsWindows ?? Platform.isWindows)) return null;
  try {
    return await _windowAnimationChannel.invokeMethod<bool>('presentPanel', {
      'focus': focus,
    });
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
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

Future<void> setNativeSurfaceBounds({
  required Rect bounds,
  required double scaleFactor,
  bool maximized = false,
}) async {
  await _windowAnimationChannel.invokeMethod<bool>('setSurfaceBounds', {
    'toX': bounds.left,
    'toY': bounds.top,
    'toWidth': bounds.width,
    'toHeight': bounds.height,
    'scaleFactor': scaleFactor,
    'maximized': maximized,
  });
}

Future<bool?> isPointerWithinNativeSurface({bool? platformIsWindows}) async {
  if (!(platformIsWindows ?? Platform.isWindows)) return null;
  try {
    return await _windowAnimationChannel.invokeMethod<bool>(
      'isPointerWithinWindow',
    );
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
    final eased = symmetricSurfaceEase(linear);
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

  Future<CaptureResult> capture({Offset? point, void Function()? onReady});

  Future<CaptureResult?> selectContext();

  Future<ImageSelection?> selectImage();

  Future<void> close();
}

final class CaptureResult {
  const CaptureResult({this.snapshot, this.previewText = '', this.image});

  final ImageSelection? image;

  final Map<String, Object?>? snapshot;
  final String previewText;
}

final class ImageSelection {
  const ImageSelection({
    required this.dataUrl,
    this.bounds,
    this.snapshot,
    this.alignment,
    this.previewText,
  });

  final String dataUrl;
  final Map<String, Object?>? bounds;
  final Map<String, Object?>? snapshot;
  final Map<String, Object?>? alignment;
  final String? previewText;
}

ContextAttachment imageAttachmentFromSelection(
  ImageSelection selected,
  String id,
) {
  final capturedRegion = _nullableMap(selected.snapshot?['region']);
  bool sameBounds(Object? value) {
    final bounds = _nullableMap(value);
    return bounds != null &&
        selected.bounds != null &&
        ['x', 'y', 'width', 'height'].every(
          (key) => bounds[key] is num && bounds[key] == selected.bounds![key],
        );
  }

  final hasMapping =
      sameBounds(capturedRegion?['screenBounds']) &&
      sameBounds(selected.alignment?['screenBounds']) &&
      selected.alignment?['mapping'] is Map;
  final aligned =
      hasMapping &&
      selected.snapshot?['source'] is Map &&
      selected.alignment?['status'] == 'aligned' &&
      capturedRegion?['status'] == 'aligned';
  final imageOnlyGeometry =
      hasMapping &&
      selected.alignment?['status'] == 'image-only' &&
      capturedRegion?['status'] == 'image-only';
  final knownImageSource =
      imageOnlyGeometry && selected.snapshot?['source'] is Map;
  final reason =
      selected.alignment?['reason']?.toString() ??
      'No aligned text was exposed for this region.';
  final region = aligned || imageOnlyGeometry
      ? selected.alignment!
      : <String, Object?>{
          'status': 'image-only',
          'reason': reason,
          if (selected.bounds != null) 'screenBounds': selected.bounds,
        };
  final now = DateTime.now().toUtc();
  final metadata = imageOnlyGeometry
      ? (selected.snapshot ?? const <String, Object?>{})
      : const <String, Object?>{};
  final snapshot = aligned
      ? selected.snapshot!
      : <String, Object?>{
          'snapshotId': metadata['snapshotId'] ?? id,
          'observedAtUtc': metadata['observedAtUtc'] ?? now.toIso8601String(),
          'expiresAtUtc':
              metadata['expiresAtUtc'] ??
              now.add(const Duration(seconds: 30)).toIso8601String(),
          'surfaceKind': 'Image region',
          'application': knownImageSource
              ? (metadata['application'] ?? 'Screen')
              : 'Screen',
          'region': region,
          'limitation': reason,
          if (knownImageSource)
            for (final field in [
              'source',
              'locator',
              'windowTitle',
              'processName',
            ])
              if (selected.snapshot!.containsKey(field))
                field: selected.snapshot![field],
        };
  return ContextAttachment(
    id: id,
    token: '',
    snapshot: snapshot,
    previewText: aligned || imageOnlyGeometry
        ? selected.previewText ??
              (aligned
                  ? 'Image with text from the selected region'
                  : 'Image with screen location — $reason')
        : 'Image only — $reason',
    imageDataUrl: selected.dataUrl,
    bounds: selected.bounds,
  );
}

CaptureProvider platformCaptureProvider() => Platform.isWindows
    ? WindowsCaptureProvider()
    : Platform.isLinux
    ? LinuxCaptureProvider(
        useWaylandPortals: shouldUseWaylandPortals(Platform.environment),
      )
    : PortableCaptureProvider();

final class WindowsCaptureProvider
    implements CaptureProvider, BrowserCaptureSettings {
  bool _browserPageDetails = true;
  @override
  bool get supportsBrowserPageDetails => true;
  @override
  void setBrowserPageDetails(bool enabled) => _browserPageDetails = enabled;

  WindowsCaptureProvider({
    String? executablePath,
    NativeCaptureClient? captureClient,
    NativeCaptureClient? selectorClient,
  }) : _captureClient =
           captureClient ??
           ProcessNativeCaptureClient(executablePath ?? _nativeHostPath()),
       _selectorClient =
           selectorClient ??
           ProcessNativeCaptureClient(executablePath ?? _nativeHostPath());

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
  Future<CaptureResult> capture({
    Offset? point,
    void Function()? onReady,
  }) async {
    final response = await _captureClient.request(
      'capture',
      parameters: {
        'browserPageDetails': _browserPageDetails,
        if (point != null)
          'point': {'x': point.dx.round(), 'y': point.dy.round()},
      },
      onReady: onReady,
    );
    return CaptureResult(
      snapshot: _nullableMap(response['snapshot']),
      previewText: response['previewText']?.toString() ?? '',
    );
  }

  @override
  Future<CaptureResult?> selectContext() async {
    final response = await _selectorClient.request(
      'selectContent',
      parameters: {
        'returnProcessId': pid,
        'browserPageDetails': _browserPageDetails,
      },
    );
    if (response['errorMessage'] case final String message
        when message.isNotEmpty) {
      throw StateError(message);
    }
    if (response['cancelled'] == true) return null;
    final dataUrl = response['dataUrl']?.toString() ?? '';
    return CaptureResult(
      snapshot: _nullableMap(response['snapshot']),
      previewText: response['previewText']?.toString() ?? '',
      image: dataUrl.isNotEmpty
          ? ImageSelection(
              dataUrl: dataUrl,
              bounds: _nullableMap(response['bounds']),
              snapshot: _nullableMap(response['snapshot']),
              alignment: _nullableMap(response['alignment']),
              previewText: response['previewText']?.toString(),
            )
          : null,
    );
  }

  @override
  Future<ImageSelection?> selectImage() async {
    final response = await _selectorClient.request(
      'selectImage',
      parameters: {
        'returnProcessId': pid,
        'browserPageDetails': _browserPageDetails,
      },
    );
    if (response['cancelled'] == true) return null;
    final dataUrl = response['dataUrl']?.toString() ?? '';
    if (dataUrl.isEmpty) return null;
    return ImageSelection(
      dataUrl: dataUrl,
      bounds: _nullableMap(response['bounds']),
      snapshot: _nullableMap(response['snapshot']),
      alignment: _nullableMap(response['alignment']),
      previewText: response['previewText']?.toString(),
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
  Future<CaptureResult> capture({
    Offset? point,
    void Function()? onReady,
  }) async {
    final response = await _request([
      _useWaylandPortals ? 'portal-context' : 'context',
    ], const Duration(seconds: 5));
    return _portableResultFromLinuxResponse(response);
  }

  CaptureResult _portableResultFromLinuxResponse(
    Map<String, Object?> response,
  ) => portableCaptureResult(
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

  @override
  Future<CaptureResult?> selectContext() async {
    if (_useWaylandPortals) {
      // Wayland does not expose an unrestricted global pointer grab. Preserve
      // the portal's explicit foreground-context authority on that platform.
      return capture();
    }
    final response = await _request([
      'point-context',
    ], const Duration(minutes: 5));
    if (response['cancelled'] == true) return null;
    return _portableResultFromLinuxResponse(response);
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
  Future<CaptureResult> capture({
    Offset? point,
    void Function()? onReady,
  }) async {
    return _captureMac();
  }

  @override
  Future<CaptureResult?> selectContext() => capture();

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
    String method, {
    Map<String, Object?> parameters = const {},
    void Function()? onReady,
  });

  Future<void> close();
}

final class ProcessNativeCaptureClient implements NativeCaptureClient {
  ProcessNativeCaptureClient(
    this.executablePath, {
    this.captureTimeout = const Duration(seconds: 30),
    this.selectionTimeout = const Duration(minutes: 5),
  });

  final String executablePath;
  final Duration captureTimeout;
  final Duration selectionTimeout;
  final Map<String, Completer<Map<String, Object?>>> _pending = {};
  final Map<String, void Function()> _ready = {};
  Future<void>? _starting;
  Future<void> _writes = Future.value();
  Process? _process;
  StreamSubscription<String>? _stdout;
  StreamSubscription<String>? _stderr;
  int _nextId = 0;
  String _recentError = '';

  @override
  Future<Map<String, Object?>> request(
    String method, {
    Map<String, Object?> parameters = const {},
    void Function()? onReady,
  }) async {
    await _ensureStarted();
    final process = _process;
    if (process == null) {
      throw StateError('Windows capture host is unavailable.');
    }
    final id = (++_nextId).toString();
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    if (onReady != null) _ready[id] = onReady;
    final response = completer.future.timeout(
      method == 'selectContent' ||
              method == 'selectContext' ||
              method == 'selectImage'
          ? selectionTimeout
          : captureTimeout,
      onTimeout: () {
        _pending.remove(id);
        _ready.remove(id);
        // A timed-out modal selector must not remain above the user's apps.
        if (identical(_process, process)) process.kill();
        throw TimeoutException(
          'Windows capture host timed out during $method.',
        );
      },
    );
    _writes = _writes
        .then((_) async {
          if (!identical(_process, process)) {
            throw StateError('Windows capture host stopped before $method.');
          }
          process.stdin.writeln(
            jsonEncode({
              'id': id,
              'method': method,
              'params': {
                ...parameters,
                if (onReady != null) 'reportReady': true,
              },
            }),
          );
          await process.stdin.flush();
        })
        .catchError((Object error, StackTrace stackTrace) {
          _ready.remove(id);
          _pending.remove(id)?.completeError(error, stackTrace);
        });
    return response;
  }

  Future<void> _ensureStarted() {
    if (_process != null) return Future.value();
    return _starting ??= _startProcess().whenComplete(() => _starting = null);
  }

  Future<void> _startProcess() async {
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
        _ready.clear();
      }),
    );
  }

  void _handleLine(String line) {
    try {
      final value = jsonDecode(line);
      if (value is! Map) return;
      final json = value.map((key, value) => MapEntry(key.toString(), value));
      final id = json['id']?.toString();
      if (json['type'] == 'captureReady') {
        _ready.remove(id)?.call();
        return;
      }
      _ready.remove(id);
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
