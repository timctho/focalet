import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/state/zommi_models.dart';

void main() {
  test('Linux skips the unsupported native window shadow method', () {
    expect(supportsNativeWindowShadow('linux'), isFalse);
    expect(supportsNativeWindowShadow('windows'), isTrue);
    expect(supportsNativeWindowShadow('macos'), isTrue);
  });

  test(
    'tray right-click explicitly opens the menu on supported desktops',
    () async {
      expect(supportsExplicitTrayContextMenu('windows'), isTrue);
      expect(supportsExplicitTrayContextMenu('linux'), isTrue);
      expect(supportsExplicitTrayContextMenu('macos'), isFalse);

      var menuOpenCount = 0;
      Future<void> show() async => menuOpenCount += 1;
      await showExplicitTrayContextMenu(operatingSystem: 'windows', show: show);
      await showExplicitTrayContextMenu(operatingSystem: 'macos', show: show);
      expect(menuOpenCount, 1);
    },
  );

  test('cancelled image selection emits no panel-opening invocation', () {
    expect(imageSelectionInvocation(null), isNull);

    final attachment = ContextAttachment(
      id: 'image-1',
      token: '',
      imageDataUrl: 'data:image/png;base64,aGVsbG8=',
      bounds: {'width': 1, 'height': 1},
    );
    final invocation = imageSelectionInvocation(attachment);
    expect(invocation?.kind, DesktopInvocationKind.image);
    expect(invocation?.attachment, same(attachment));
    expect(invocation?.message, 'Image context attached');
  });

  test(
    'showing a panel focuses it without applying a second surface size',
    () async {
      final calls = <String>[];
      await presentPanelWithoutResizing(
        show: () async => calls.add('show'),
        focus: () async => calls.add('focus'),
        keepOnTop: () async => calls.add('topmost'),
      );

      expect(calls, ['show', 'focus', 'topmost']);
      expect(calls, isNot(contains('resize')));
    },
  );

  test('surface bounds preserve a dragged bottom-center anchor', () {
    const workArea = Rect.fromLTWH(100, 50, 1200, 800);
    final initial = anchoredSurfaceBounds(
      current: const Rect.fromLTWH(10, 10, 900, 760),
      workArea: workArea,
      size: compactWindowSize,
      preserveCurrentAnchor: false,
    );
    expect(initial.center.dx, workArea.center.dx);
    expect(initial.bottom, workArea.bottom - windowBottomInset);

    const dragged = Rect.fromLTWH(622, 724, 56, 56);
    final expanded = anchoredSurfaceBounds(
      current: dragged,
      workArea: workArea,
      size: normalWindowSize,
      preserveCurrentAnchor: true,
    );
    expect(expanded.center.dx, dragged.center.dx);
    expect(expanded.bottom, dragged.bottom);

    final clamped = anchoredSurfaceBounds(
      current: const Rect.fromLTWH(110, 60, 56, 56),
      workArea: workArea,
      size: normalWindowSize,
      preserveCurrentAnchor: true,
    );
    expect(clamped.left, workArea.left);
    expect(clamped.top, workArea.top);
    expect(workArea.contains(clamped.topLeft), isTrue);
    expect(workArea.contains(clamped.bottomRight), isTrue);
  });

  test(
    'surface transition advances through eased frames to exact bounds',
    () async {
      const from = Rect.fromLTWH(100, 500, 56, 56);
      const to = Rect.fromLTWH(20, 40, 720, 620);
      final frames = <Rect>[];
      await animateSurfaceBounds(
        from: from,
        to: to,
        duration: const Duration(microseconds: 4),
        frames: 4,
        setBounds: (value) async => frames.add(value),
        cancelled: () => false,
      );
      expect(frames, hasLength(4));
      expect(frames.first.width, greaterThan(from.width));
      expect(frames.last, to);
    },
  );

  test(
    'Windows region selection is not queued behind slow UIA capture',
    () async {
      final captureResult = Completer<Map<String, Object?>>();
      final captureClient = _FakeNativeCaptureClient(
        onRequest: (method) => method == 'capture'
            ? captureResult.future
            : Future.value(<String, Object?>{}),
      );
      final selectorClient = _FakeNativeCaptureClient(
        onRequest: (method) async => method == 'selectImage'
            ? <String, Object?>{
                'cancelled': false,
                'dataUrl': 'data:image/png;base64,aGVsbG8=',
                'bounds': <String, Object?>{
                  'x': 1,
                  'y': 2,
                  'width': 3,
                  'height': 4,
                },
              }
            : <String, Object?>{},
      );
      final provider = WindowsCaptureProvider(
        captureClient: captureClient,
        selectorClient: selectorClient,
      );

      final pendingCapture = provider.capture();
      await Future<void>.delayed(Duration.zero);
      expect(captureClient.requests, ['capture']);

      final image = await provider.selectImage().timeout(
        const Duration(milliseconds: 100),
      );
      expect(selectorClient.requests, ['selectImage']);
      expect(image?.bounds?['width'], 3);

      captureResult.complete(<String, Object?>{'snapshot': null});
      await pendingCapture;
      await provider.close();
      expect(captureClient.closed, isTrue);
      expect(selectorClient.closed, isTrue);
    },
  );

  test(
    'Linux capture uses the adjacent Rust helper for metadata and pixels',
    () async {
      final calls = <List<String>>[];
      final provider = LinuxCaptureProvider(
        executablePath: '/opt/zommi/zommi-x11-capture',
        runCommand: (executable, arguments, timeout) async {
          expect(executable, '/opt/zommi/zommi-x11-capture');
          calls.add(arguments);
          if (arguments.first == 'context') {
            return ProcessResult(
              10,
              0,
              jsonEncode({
                'application': 'fixture-app',
                'processName': 'fixture-process',
                'windowTitle': 'Fixture window',
                'limitation': 'X11 metadata only',
              }),
              '',
            );
          }
          final output = File(arguments.last);
          await output.writeAsBytes([1, 2, 3]);
          return ProcessResult(
            11,
            0,
            jsonEncode({
              'cancelled': false,
              'bounds': {'x': 20, 'y': 30, 'width': 40, 'height': 50},
            }),
            '',
          );
        },
      );

      final context = await provider.capture();
      expect(context.snapshot?['application'], 'fixture-app');
      expect(context.snapshot?['processName'], 'fixture-process');
      expect(context.snapshot?['windowTitle'], 'Fixture window');

      final image = await provider.selectImage();
      expect(image?.dataUrl, 'data:image/png;base64,AQID');
      expect(image?.bounds?['width'], 40);
      expect(calls, [
        ['context'],
        ['region', '--output', isA<String>()],
      ]);
      expect(await File(calls.last.last).exists(), isFalse);
    },
  );

  test('Linux Rust region cancellation adds no image', () async {
    final provider = LinuxCaptureProvider(
      executablePath: '/opt/zommi/zommi-x11-capture',
      runCommand: (_, _, _) async =>
          ProcessResult(12, 0, '{"cancelled":true}', ''),
    );
    expect(await provider.selectImage(), isNull);
  });

  test(
    'Wayland capture uses portal commands and preserves degraded context',
    () async {
      final calls = <List<String>>[];
      final provider = LinuxCaptureProvider(
        executablePath: '/opt/zommi/zommi-x11-capture',
        useWaylandPortals: true,
        runCommand: (_, arguments, _) async {
          calls.add(arguments);
          if (arguments.first == 'portal-context') {
            return ProcessResult(
              20,
              0,
              jsonEncode({
                'application': 'Linux desktop',
                'processName': 'wayland-session',
                'windowTitle': '',
                'degraded': true,
                'limitation': 'Wayland active-window metadata is unavailable',
              }),
              '',
            );
          }
          await File(arguments.last).writeAsBytes([4, 5, 6]);
          return ProcessResult(
            21,
            0,
            jsonEncode({
              'cancelled': false,
              'provider': 'wayland-portal',
              'bounds': {'width': 80, 'height': 60},
            }),
            '',
          );
        },
      );

      final context = await provider.capture();
      expect(context.snapshot?['application'], 'Linux desktop');
      expect(context.snapshot?['confidence'], 'limited');
      expect(
        context.previewText,
        contains('active-window metadata is unavailable'),
      );
      final image = await provider.selectImage();
      expect(image?.dataUrl, 'data:image/png;base64,BAUG');
      expect(image?.bounds?['width'], 80);
      expect(calls, [
        ['portal-context'],
        ['portal-region', '--output', isA<String>()],
      ]);
    },
  );

  test('Wayland screenshot portal cancellation adds no image', () async {
    final provider = LinuxCaptureProvider(
      executablePath: '/opt/zommi/zommi-x11-capture',
      useWaylandPortals: true,
      runCommand: (_, arguments, _) async {
        expect(arguments.first, 'portal-region');
        return ProcessResult(22, 0, '{"cancelled":true}', '');
      },
    );
    expect(await provider.selectImage(), isNull);
  });

  test(
    'Wayland portal shortcut activations keep exact gesture identity',
    () async {
      final client = _FakeWaylandPortalShortcutClient();
      var contextInvocations = 0;
      var imageInvocations = 0;
      final errors = <Object>[];
      final registration = await registerWaylandPortalShortcuts(
        client,
        onContext: () => contextInvocations += 1,
        onImage: () => imageInvocations += 1,
        onError: errors.add,
      );
      expect(registration.readiness.contextShortcut, isTrue);
      expect(registration.readiness.imageShortcut, isTrue);

      client.emit('context');
      client.emit('image');
      client.emit('unknown');
      expect(contextInvocations, 1);
      expect(imageInvocations, 1);
      expect(errors, isEmpty);

      await registration.subscription.cancel();
      await client.close();
    },
  );

  test(
    'Wayland portal process client parses readiness and activations',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'zommi-wayland-shortcut-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final script = File('${directory.path}/portal-fixture.sh');
      await script.writeAsString('''
printf '%s\n' '{"event":"ready","contextShortcut":true,"imageShortcut":true}'
printf '%s\n' '{"event":"activated","shortcutId":"context"}'
printf '%s\n' '{"event":"activated","shortcutId":"image"}'
while read -r line; do :; done
''');
      final client = ProcessWaylandPortalShortcutClient(
        '/bin/sh',
        argumentsBeforeCommand: [script.path],
      );
      final activations = client.activations.take(2).toList();

      final readiness = await client.initialize();
      expect(readiness.contextShortcut, isTrue);
      expect(readiness.imageShortcut, isTrue);
      expect(await activations, ['context', 'image']);
      await client.close();
    },
  );

  test('Wayland portal selection follows the desktop session authority', () {
    expect(
      shouldUseWaylandPortals(const {
        'XDG_SESSION_TYPE': 'wayland',
        'DISPLAY': ':1',
        'WAYLAND_DISPLAY': 'wayland-0',
      }),
      isTrue,
    );
    expect(
      shouldUseWaylandPortals(const {
        'DISPLAY': ':0',
        'WAYLAND_DISPLAY': 'wayland-0',
      }),
      isFalse,
    );
    expect(
      shouldUseWaylandPortals(const {'WAYLAND_DISPLAY': 'wayland-0'}),
      isTrue,
    );
  });

  test('Linux capture helper resolves beside the packaged Flutter binary', () {
    expect(
      resolveLinuxCaptureExecutable(
        applicationDirectory: '/opt/zommi',
        pathSeparator: '/',
        environment: const {},
        exists: (path) => path == '/opt/zommi/zommi-x11-capture',
      ),
      '/opt/zommi/zommi-x11-capture',
    );
    expect(
      resolveLinuxCaptureExecutable(
        environment: const {'ZOMMI_X11_CAPTURE_HOST': '/custom/capture'},
        exists: (_) => false,
      ),
      '/custom/capture',
    );
  });
}

final class _FakeNativeCaptureClient implements NativeCaptureClient {
  _FakeNativeCaptureClient({required this.onRequest});

  final Future<Map<String, Object?>> Function(String method) onRequest;
  final List<String> requests = [];
  bool closed = false;

  @override
  Future<Map<String, Object?>> request(
    String method, [
    Map<String, Object?> parameters = const {},
  ]) {
    requests.add(method);
    return onRequest(method);
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

final class _FakeWaylandPortalShortcutClient
    implements WaylandPortalShortcutClient {
  final StreamController<String> _controller =
      StreamController<String>.broadcast(sync: true);

  void emit(String shortcut) => _controller.add(shortcut);

  @override
  Stream<String> get activations => _controller.stream;

  @override
  Future<DesktopReadiness> initialize() async =>
      const DesktopReadiness(contextShortcut: true, imageShortcut: true);

  @override
  Future<void> close() => _controller.close();
}
