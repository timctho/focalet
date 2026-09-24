import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals, debugPrint;

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
import 'package:zommi_flutter/desktop/capture_permissions.dart';
import 'package:zommi_flutter/desktop/capture_shortcut.dart';
import 'package:zommi_flutter/desktop/response_notifications.dart';
import 'package:zommi_flutter/desktop/region_selection.dart';
import 'package:zommi_flutter/desktop/linux_document_renderer.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/theme/app_preferences.dart';

part 'capture_provider.dart';
part 'unix_capture_provider.dart';
part 'surface_window.dart';
part 'wayland_shortcuts.dart';

const Size compactWindowSize = Size(56, 56);
const Size normalWindowSize = Size(1120, 820);
const Size largeWindowSize = Size(1320, 900);
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

enum DesktopInvocationKind {
  open,
  openSession,
  selectContent,
  captureStarted,
  context,
  image,
  status,
  windowState,
}

final class DesktopInvocation {
  const DesktopInvocation({
    required this.kind,
    this.attachment,
    this.message,
    this.warning = false,
    this.maximized,
    this.runtimeTargetId,
    this.sessionId,
  });

  final DesktopInvocationKind kind;
  final ContextAttachment? attachment;
  final String? message;
  final bool warning;
  final bool? maximized;
  final String? runtimeTargetId;
  final String? sessionId;
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

abstract interface class CaptureThemeSettings {
  void setCaptureTheme(Map<String, int> colors);
}

abstract interface class TrayMenuAppearance {
  void setTrayMenuColors({
    required Color background,
    required Color foreground,
    required Color hover,
  });
}

abstract interface class DesktopBridge {
  Stream<DesktopInvocation> get invocations;

  Future<DesktopReadiness> initialize();

  Future<void> notifyResponseReady({
    required String runtimeTargetId,
    required String sessionId,
    required String turnId,
    required String runtimeName,
    required String sessionTitle,
  });

  Future<ContextAttachment?> captureContext({bool hidePanel = false});

  Future<List<ContextAttachment>> selectPointerContext();

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

  Future<void> closeWindow();

  Future<bool> toggleMaximized();

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
  Future<void> notifyResponseReady({
    required String runtimeTargetId,
    required String sessionId,
    required String turnId,
    required String runtimeName,
    required String sessionTitle,
  }) async {}

  @override
  Future<ContextAttachment?> captureContext({bool hidePanel = false}) async =>
      null;

  @override
  Future<List<ContextAttachment>> selectPointerContext() async => const [];

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
  Future<void> closeWindow() async {}

  @override
  Future<bool> toggleMaximized() async => false;

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
    implements
        DesktopBridge,
        BrowserCaptureSettings,
        CaptureThemeSettings,
        CapturePermissionBridge,
        CaptureShortcutSettings,
        TrayMenuAppearance {
  FlutterDesktopBridge({
    CaptureProvider? captureProvider,
    DesktopAcceptanceRecorder? acceptanceRecorder,
    WaylandPortalShortcutClient? waylandPortalShortcutClient,
    bool? useWaylandPortals,
    bool? useNativeSurface,
    CaptureShortcut? selectionShortcut,
  }) : _selectionShortcut = selectionShortcut ?? CaptureShortcut.standard,
       _captureProvider = captureProvider ?? platformCaptureProvider(),
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
  late final ResponseNotifications _notifications = ResponseNotifications(
    isForeground: () async =>
        await windowManager.isVisible() &&
        !await windowManager.isMinimized() &&
        await windowManager.isFocused(),
    onOpen: (runtime, session) {
      if (!_invocations.isClosed) {
        _invocations.add(
          DesktopInvocation(
            kind: DesktopInvocationKind.openSession,
            runtimeTargetId: runtime,
            sessionId: session,
          ),
        );
      }
    },
    record: _recordAcceptance,
  );

  @override
  Future<void> notifyResponseReady({
    required String runtimeTargetId,
    required String sessionId,
    required String turnId,
    required String runtimeName,
    required String sessionTitle,
  }) async {
    try {
      await _notifications.show(
        runtimeTargetId: runtimeTargetId,
        sessionId: sessionId,
        turnId: turnId,
        runtimeName: runtimeName,
        sessionTitle: sessionTitle,
      );
    } on Object {
      await _recordAcceptance('notification.failed', {
        'runtimeTargetId': runtimeTargetId,
        'sessionId': sessionId,
      });
    }
  }

  final MacCapturePermissions _capturePermissions = MacCapturePermissions();

  @override
  bool get supportsCapturePermissions =>
      _capturePermissions.supportsCapturePermissions;

  @override
  Future<CapturePermissionStatus> capturePermissions() =>
      _capturePermissions.capturePermissions();

  @override
  Future<CapturePermissionStatus> requestCapturePermission(
    CapturePermission permission,
  ) => _capturePermissions.requestCapturePermission(permission);

  static Future<FlutterDesktopBridge> bootstrap({
    CaptureShortcut selectionShortcut = CaptureShortcut.standard,
    WindowSizeSetting windowSize = WindowSizeSetting.standard,
  }) async {
    await windowManager.ensureInitialized();
    final size = windowSize == WindowSizeSetting.wide
        ? largeWindowSize
        : normalWindowSize;
    final options = WindowOptions(
      size: size,
      center: true,
      minimumSize: const Size(640, 500),
      backgroundColor: const Color(0x00000000),
      alwaysOnTop: false,
      skipTaskbar: false,
      title: 'Zommi',
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    await windowManager.waitUntilReadyToShow(options);
    // The hidden macOS title bar already provides a full-size content view.
    // setAsFrameless marks NSWindow opaque, turning our clear corners black.
    if (!Platform.isMacOS) await windowManager.setAsFrameless();
    if (supportsNativeWindowShadow(Platform.operatingSystem)) {
      await windowManager.setHasShadow(false);
    }
    await windowManager.setResizable(true);
    await configureNativeSurfaceWindow();
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setSkipTaskbar(false);
    final desktop = FlutterDesktopBridge(selectionShortcut: selectionShortcut);
    // Size and position the first visible frame within the monitor work area.
    await desktop.setSurface(
      expanded: true,
      large: windowSize == WindowSizeSetting.wide,
      maximized: windowSize == WindowSizeSetting.maximized,
      animate: false,
    );
    return desktop;
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
  @override
  void setCaptureTheme(Map<String, int> colors) {
    if (_captureProvider case final CaptureThemeSettings settings) {
      settings.setCaptureTheme(colors);
    }
  }

  final WaylandPortalShortcutClient _waylandPortalShortcutClient;
  final bool _useWaylandPortals;
  final DesktopAcceptanceRecorder? _acceptanceRecorder;
  final StreamController<DesktopInvocation> _invocations =
      StreamController<DesktopInvocation>.broadcast(sync: true);
  CaptureShortcut _selectionShortcut;
  HotKey? _contextHotKey;
  bool _shortcutSuspended = false;
  Future<void> _shortcutQueue = Future<void>.value();

  @override
  bool get canCustomizeSelectionShortcut => !_useWaylandPortals;

  Future<void> _queueShortcut(Future<void> Function() action) {
    final next = _shortcutQueue.then((_) => action());
    _shortcutQueue = next.catchError((Object _) {});
    return next;
  }

  Future<void> _registerSelectionShortcut(CaptureShortcut shortcut) async {
    if (Platform.isWindows) {
      await _windowAnimationChannel.invokeMethod<void>('setSelectionShortcut', {
        'key': shortcut.virtualKey,
        'modifiers': shortcut.modifiers,
      });
    } else {
      final previous = _contextHotKey;
      if (_nativeContextRegistered && shortcut == _selectionShortcut) return;
      final next = shortcut.toHotKey();
      await hotKeyManager.register(
        next,
        keyDownHandler: (_) => unawaited(invokeContentSelection()),
      );
      if (previous != null && _nativeContextRegistered) {
        try {
          await hotKeyManager.unregister(previous);
        } on Object {
          await hotKeyManager.unregister(next);
          rethrow;
        }
      }
      _contextHotKey = next;
    }
    _nativeContextRegistered = true;
    _shortcutSuspended = false;
    _selectionShortcut = shortcut;
  }

  @override
  Future<void> configureSelectionShortcut(CaptureShortcut shortcut) =>
      _queueShortcut(() async {
        if (!shortcut.valid) throw ArgumentError('Invalid selection shortcut');
        if (!_initialized) {
          _selectionShortcut = shortcut;
        } else if (canCustomizeSelectionShortcut) {
          await _registerSelectionShortcut(shortcut);
        }
      });

  @override
  Future<void> suspendSelectionShortcut() => _queueShortcut(() async {
    _shortcutSuspended = true;
    if (!_nativeContextRegistered) return;
    if (Platform.isWindows) {
      await _windowAnimationChannel.invokeMethod<void>('setSelectionShortcut');
    } else {
      await hotKeyManager.unregister(_contextHotKey!);
    }
    _nativeContextRegistered = false;
  });

  @override
  Future<void> resumeSelectionShortcut() => _queueShortcut(() async {
    if (_shortcutSuspended) {
      await _registerSelectionShortcut(_selectionShortcut);
    }
  });
  bool _initialized = false;
  bool _surfacePositionInitialized = false;
  int _surfaceTransitionEpoch = 0;
  Future<void> _surfaceResizeQueue = Future<void>.value();
  Offset? _surfaceAnchor;
  bool _nativeContextRegistered = false;
  DesktopReadiness _readiness = const DesktopReadiness();
  StreamSubscription<String>? _portalShortcutSubscription;
  String? _trayIconPath;
  Map<String, Object?> _trayColors = const {};

  @override
  void setTrayMenuColors({
    required Color background,
    required Color foreground,
    required Color hover,
  }) {
    _trayColors = {
      'background': background.toARGB32(),
      'foreground': foreground.toARGB32(),
      'hover': hover.toARGB32(),
    };
  }

  @override
  Stream<DesktopInvocation> get invocations => _invocations.stream;

  @override
  Future<DesktopReadiness> initialize() async {
    if (_initialized) {
      return _readiness;
    }
    _initialized = true;
    unawaited(_notifications.initialize());
    if (Platform.isWindows) {
      _windowAnimationChannel.setMethodCallHandler((call) async {
        if (call.method == 'selectContent') await invokeContentSelection();
      });
    }
    if (_useNativeSurface) WidgetsBinding.instance.addObserver(this);
    windowManager.addListener(this);
    // Keep sessions and shortcuts alive when the OS closes the window. Quit
    // explicitly destroys it and bypasses this close interception.
    await windowManager.setPreventClose(true);
    await windowManager.setAlwaysOnTop(false);
    await setSurface(expanded: true, animate: false);
    await windowManager.show();
    try {
      await _captureProvider.initialize();
    } on Object catch (error) {
      _emitWarning('Capture provider is unavailable: $error');
    }

    var contextRegistered = false;
    if (_useWaylandPortals) {
      try {
        final registration = await registerWaylandPortalShortcuts(
          _waylandPortalShortcutClient,
          onContext: () => unawaited(invokeContentSelection()),
          onError: (error) =>
              _emitWarning('Wayland global shortcuts stopped: $error'),
        );
        _portalShortcutSubscription = registration.subscription;
        contextRegistered = registration.readiness.contextShortcut;
      } on Object catch (error) {
        _emitWarning('Wayland global shortcuts are unavailable: $error');
      }
    } else {
      try {
        await _queueShortcut(() async {
          if (!_shortcutSuspended) {
            await _registerSelectionShortcut(_selectionShortcut);
          }
        });
        contextRegistered = _nativeContextRegistered;
      } on Object catch (error) {
        _emitWarning(
          '${_selectionShortcut.label} could not be registered: $error',
        );
      }
    }
    await _configureTray();
    await _recordAcceptance('desktop.ready', {
      'contextShortcut': contextRegistered,
      'imageShortcut': false,
    });
    _readiness = DesktopReadiness(contextShortcut: contextRegistered);
    return _readiness;
  }

  Future<void> invokeContentSelection() async {
    if (_invocations.isClosed) return;
    // The controller shares selection, cancellation and single-flight handling
    // with the composer button, including ordered multi-selection batches.
    _invocations.add(
      const DesktopInvocation(kind: DesktopInvocationKind.selectContent),
    );
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
    await hideDesktopForCapture();
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
  Future<List<ContextAttachment>> selectPointerContext() async {
    final wasVisible = await windowManager.isVisible();
    final wasMinimized = await windowManager.isMinimized();
    await hideDesktopForCapture();
    try {
      // The explicit picker owns the next click and changes the system cursor,
      // so selecting context from the composer cannot feel like an immediate,
      // invisible capture of the old pointer position.
      await Future<void>.delayed(const Duration(milliseconds: 90));
      final selected = await _captureProvider.selectContext();
      final attachments = <ContextAttachment>[
        for (final result in selected)
          if (result.image case final image?)
            imageAttachmentFromSelection(image, _nextAttachmentId())
          else if (result.snapshot != null)
            ContextAttachment(
              id: _nextAttachmentId(),
              token: '',
              snapshot: result.snapshot,
              previewText: result.previewText,
            ),
      ];
      await _recordAcceptance('selection.content', {
        'count': attachments.length,
        'items': [
          for (final attachment in attachments)
            {
              'bounds': attachment.bounds,
              'hasImage': attachment.hasImage,
              'windowTitle': attachment.snapshot?['windowTitle'],
              'application': attachment.snapshot?['application'],
              'alignmentStatus': mapValue(
                attachment.snapshot?['region'],
              )['status'],
              'annotationCount':
                  mapValue(
                    attachment.snapshot?['imageAnnotations'],
                  )['strokeCount'] ??
                  0,
              'elementCount':
                  (mapValue(attachment.snapshot?['regionContext'])['elements']
                          as List?)
                      ?.length ??
                  0,
            },
        ],
      });
      return attachments;
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
    await hideDesktopForCapture();
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
    await windowManager.setResizable(expanded);
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
            : initialSurfaceAnchor(workAreaBounds, Size(width, height)));
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
  Future<void> closeWindow() => windowManager.hide();

  @override
  Future<bool> toggleMaximized() async {
    if (_useNativeSurface) {
      ++_surfaceTransitionEpoch;
      final operation = _surfaceResizeQueue
          .catchError((Object _) {})
          .then<bool>((_) async {
            await _windowAnimationChannel.invokeMethod<void>(
              'toggleSurfaceMaximized',
            );
            return (await readNativeSurfaceGeometry(_windowAnimationChannel))
                .maximized;
          });
      _surfaceResizeQueue = operation.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
      return operation;
    }
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
    return windowManager.isMaximized();
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
      'opencode-acp' => const ['auth', 'login'],
      // Gemini's interactive CLI owns sign-in; it has no login subcommand.
      'gemini-acp' => const <String>[],
      'openclaw-acp' => const ['onboard'],
      _ => null,
    };
    if (target.executablePath.isEmpty || signInArgs == null) {
      throw StateError(
        '${target.displayName} has no separate sign-in command.',
      );
    }
    if (Platform.isWindows) {
      final process = await Process.start('wt.exe', [
        '-w',
        'new',
        ...windowsRuntimeSignInCommand(target, signInArgs),
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
          : Platform.isMacOS
          ? 'assets/branding/tray-template.png'
          : 'assets/branding/app-icon.png';
      final bytes = await rootBundle.load(asset);
      final extension = Platform.isWindows ? 'ico' : 'png';
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'zommi-tray-${pid.hashCode}.$extension',
      );
      await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      _trayIconPath = file.path;
      await trayManager.setIcon(file.path, isTemplate: Platform.isMacOS);
      if (!Platform.isLinux) await trayManager.setToolTip('Zommi agent chat');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'open', label: 'Open Zommi'),
            MenuItem(key: 'exit', label: 'Quit'),
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
    if (Platform.isWindows) {
      unawaited(_showWindowsTrayMenu());
      return;
    }
    unawaited(
      showExplicitTrayContextMenu(
        operatingSystem: Platform.operatingSystem,
        show: () => trayManager.popUpContextMenu(),
      ),
    );
  }

  Future<void> _showWindowsTrayMenu() async {
    try {
      final action = await _windowAnimationChannel.invokeMethod<String>(
        'showTrayMenu',
        _trayColors,
      );
      if (!_invocations.isClosed && action == 'open') onTrayIconMouseDown();
      if (action == 'exit') await windowManager.destroy();
    } on Object catch (error) {
      _emitWarning('Could not open tray menu: $error');
    }
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open':
        onTrayIconMouseDown();
      case 'exit':
        unawaited(windowManager.destroy());
    }
  }

  @override
  void onWindowClose() {
    final selection = activeRegionSelection.value;
    if (selection != null) {
      selection.finish(cancel: true);
    } else {
      unawaited(closeWindow());
    }
  }

  @override
  void onWindowFocus() {}

  @override
  void onWindowMaximize() => _reportWindowState(true);

  @override
  void onWindowUnmaximize() => _reportWindowState(false);

  void _reportWindowState(bool maximized) {
    if (_invocations.isClosed || activeRegionSelection.value != null) return;
    _invocations.add(
      DesktopInvocation(
        kind: DesktopInvocationKind.windowState,
        maximized: maximized,
      ),
    );
  }

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
    _notifications.close();
    _windowAnimationChannel.setMethodCallHandler(null);
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    await _portalShortcutSubscription?.cancel();
    await _waylandPortalShortcutClient.close();
    await suspendSelectionShortcut();
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

/// Windows Terminal needs a shell for npm .cmd launchers. WSL login shells
/// also restore the Node PATH used by CLIs installed through tools such as nvm.
List<String> windowsRuntimeSignInCommand(
  RuntimeTarget target,
  List<String> arguments,
) {
  final command = [target.executablePath, ...arguments];
  if (target.executionHost['kind'] == 'wsl') {
    return [
      'wsl.exe',
      '-d',
      target.executionHost['name']?.toString() ?? '',
      '-e',
      'bash',
      '-ilc',
      'exec ${command.map(_shellQuote).join(' ')}',
    ];
  }
  final script = command
      .map((value) => "'${value.replaceAll("'", "''")}'")
      .join(' ');
  return ['powershell.exe', '-NoProfile', '-NoExit', '-Command', '& $script'];
}
