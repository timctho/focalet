import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/state/zommi_models.dart';

void main() {
  for (final cancelled in [false, true]) {
    testWidgets(
      'image selection preserves restored Maximize (cancelled: $cancelled)',
      (tester) async {
        const channel = MethodChannel('window_manager');
        var minimized = true;
        var maximized = true;
        var restores = 0;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            switch (call.method) {
              case 'isVisible':
                return true;
              case 'isMinimized':
                return minimized;
              case 'restore':
                restores++;
                if (!minimized) maximized = false;
                minimized = false;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        final bridge = FlutterDesktopBridge(
          captureProvider: WindowsCaptureProvider(
            captureClient: _FakeNativeCaptureClient(onRequest: (_) async => {}),
            selectorClient: _FakeNativeCaptureClient(
              onRequest: (_) async => cancelled
                  ? {'cancelled': true}
                  : {
                      'dataUrl': 'data:image/png;base64,aGVsbG8=',
                      'bounds': {'width': 40, 'height': 30},
                    },
            ),
          ),
        );
        final attachment = await bridge.selectImageContext();
        expect(attachment == null, cancelled);
        expect(minimized, isFalse);
        expect(maximized, isTrue);
        expect(restores, 1);
      },
    );
  }

  testWidgets(
    'rapid shortcuts coalesce without queueing another native capture',
    (tester) async {
      _mockCursor(tester);
      final captured = Completer<Map<String, Object?>>();
      final captureClient = _FakeNativeCaptureClient(
        onRequest: (_) => captured.future,
      );
      final selectorClient = _FakeNativeCaptureClient(
        onRequest: (_) async => {},
      );
      final bridge = FlutterDesktopBridge(
        captureProvider: WindowsCaptureProvider(
          captureClient: captureClient,
          selectorClient: selectorClient,
        ),
      );
      final events = <DesktopInvocation>[];
      final subscription = bridge.invocations.listen(events.add);
      addTearDown(subscription.cancel);
      final first = bridge.invokeShortcut(DesktopInvocationKind.context);
      await tester.pump();
      await bridge.invokeShortcut(DesktopInvocationKind.context);
      await bridge.invokeShortcut(DesktopInvocationKind.image);
      expect(captureClient.requests, ['capture']);
      expect(selectorClient.requests, isEmpty);
      expect(events.single.kind, DesktopInvocationKind.captureStarted);
      captured.complete({
        'snapshot': {'application': 'Source'},
      });
      await tester.pump();
      await first;
      await tester.pump();
      expect(events.last.attachment?.snapshot?['application'], 'Source');
    },
  );

  testWidgets(
    'image selector starts after target latch and focuses before slow enrichment',
    (tester) async {
      _mockCursor(tester);
      const channel = MethodChannel('window_manager');
      final windowCalls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        windowCalls.add(call.method);
        return switch (call.method) {
          'isVisible' => true,
          'isMinimized' => false,
          _ => null,
        };
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final captured = Completer<Map<String, Object?>>();
      final captureClient = _FakeNativeCaptureClient(
        onRequest: (_) => captured.future,
      );
      final selectorClient = _FakeNativeCaptureClient(
        onRequest: (_) async => {
          'dataUrl': 'data:image/png;base64,aGVsbG8=',
          'bounds': {'width': 40, 'height': 30},
        },
      );
      final bridge = FlutterDesktopBridge(
        captureProvider: WindowsCaptureProvider(
          captureClient: captureClient,
          selectorClient: selectorClient,
        ),
      );
      var completed = false;
      final selection = bridge
          .selectImageContext(includePointerContext: true)
          .then((value) {
            completed = true;
            return value;
          });
      await tester.pump();
      expect(selectorClient.requests, ['selectImage']);
      expect(windowCalls, containsAllInOrder(['hide', 'show', 'focus']));
      expect(completed, isFalse);
      captured.complete({
        'snapshot': {'application': 'Original window'},
      });
      await tester.pump();
      final attachment = await selection;
      expect(attachment?.hasImage, isTrue);
      expect(attachment?.snapshot?['application'], 'Original window');
    },
  );

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

  test('cancelled image selection emits a panel-opening invocation', () {
    final cancelled = imageSelectionInvocation(null);
    expect(cancelled.kind, DesktopInvocationKind.image);
    expect(cancelled.attachment, isNull);
    expect(cancelled.message, isNull);

    final attachment = ContextAttachment(
      id: 'image-1',
      token: '',
      imageDataUrl: 'data:image/png;base64,aGVsbG8=',
      bounds: {'width': 1, 'height': 1},
    );
    final invocation = imageSelectionInvocation(attachment);
    expect(invocation.kind, DesktopInvocationKind.image);
    expect(invocation.attachment, same(attachment));
    expect(invocation.message, 'Image context attached');
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

  testWidgets('Windows pointer containment uses the native root window', (
    tester,
  ) async {
    const channel = MethodChannel('zommi/window_animation');
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          methods.add(call.method);
          return true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    expect(await isPointerWithinNativeSurface(platformIsWindows: true), isTrue);
    expect(methods, ['isPointerWithinWindow']);
  });

  test('surface bounds preserve one bottom-center anchor across morphs', () {
    const workArea = Rect.fromLTWH(100, 50, 1200, 800);
    final initial = anchoredSurfaceBounds(
      anchor: Offset(workArea.center.dx, workArea.bottom - windowBottomInset),
      workArea: workArea,
      size: compactWindowSize,
    );
    expect(initial.center.dx, workArea.center.dx);
    expect(initial.bottom, workArea.bottom - windowBottomInset);

    const anchor = Offset(650, 800);
    final expanded = anchoredSurfaceBounds(
      anchor: anchor,
      workArea: workArea,
      size: normalWindowSize,
    );
    final collapsed = anchoredSurfaceBounds(
      anchor: anchor,
      workArea: workArea,
      size: compactWindowSize,
    );
    expect(expanded.center.dx, anchor.dx);
    expect(collapsed.center.dx, anchor.dx);
    expect(expanded.bottom, anchor.dy);
    expect(collapsed.bottom, anchor.dy);

    final clamped = anchoredSurfaceBounds(
      anchor: const Offset(138, 88),
      workArea: workArea,
      size: normalWindowSize,
    );
    expect(clamped.left, workArea.left);
    expect(clamped.top, workArea.top);
    expect(workArea.contains(clamped.topLeft), isTrue);
    expect(workArea.contains(clamped.bottomRight), isTrue);

    final restoredOrb = anchoredSurfaceBounds(
      anchor: const Offset(108, 88),
      workArea: workArea,
      size: compactWindowSize,
    );
    expect(restoredOrb.left, workArea.left);
    expect(restoredOrb.top, workArea.top);
  });

  test(
    'surface transition frames are symmetric and preserve one anchor',
    () async {
      const compact = Rect.fromLTWH(332, 564, 56, 56);
      const expanded = Rect.fromLTWH(0, 0, 720, 620);

      Future<List<Rect>> sample(Rect from, Rect to) async {
        final values = <Rect>[from];
        await animateSurfaceBounds(
          from: from,
          to: to,
          duration: const Duration(microseconds: 8),
          frames: 8,
          setBounds: (value) async => values.add(value),
          cancelled: () => false,
        );
        return values;
      }

      final forward = await sample(compact, expanded);
      final reverse = await sample(expanded, compact);
      expect(forward, hasLength(9));
      expect(reverse, hasLength(9));
      expect(
        symmetricSurfaceEase(0.25),
        closeTo(1 - symmetricSurfaceEase(0.75), 0.0000001),
      );
      for (var index = 0; index < forward.length; index++) {
        final matchingReverse = reverse[reverse.length - index - 1];
        expect(forward[index].left, closeTo(matchingReverse.left, 0.001));
        expect(forward[index].top, closeTo(matchingReverse.top, 0.001));
        expect(forward[index].width, closeTo(matchingReverse.width, 0.001));
        expect(forward[index].height, closeTo(matchingReverse.height, 0.001));
        expect(forward[index].center.dx, closeTo(360, 0.001));
        expect(forward[index].bottom, closeTo(620, 0.001));
      }
      expect(forward.last, expanded);
      expect(reverse.last, compact);
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
        onRequest: (method) async => switch (method) {
          'selectContext' => <String, Object?>{
            'cancelled': false,
            'snapshot': <String, Object?>{'application': 'clicked-window'},
            'previewText': 'Clicked window context',
          },
          'selectImage' => <String, Object?>{
            'cancelled': false,
            'dataUrl': 'data:image/png;base64,aGVsbG8=',
            'bounds': <String, Object?>{
              'x': 1,
              'y': 2,
              'width': 3,
              'height': 4,
            },
          },
          _ => <String, Object?>{},
        },
      );
      final provider = WindowsCaptureProvider(
        captureClient: captureClient,
        selectorClient: selectorClient,
      );

      final pendingCapture = provider.capture();
      await Future<void>.delayed(Duration.zero);
      expect(captureClient.requests, ['capture']);

      final selectedContext = await provider.selectContext().timeout(
        const Duration(milliseconds: 100),
      );
      expect(selectorClient.requests, ['selectContext']);
      expect(selectedContext?.snapshot?['application'], 'clicked-window');

      final image = await provider.selectImage().timeout(
        const Duration(milliseconds: 100),
      );
      expect(selectorClient.requests, ['selectContext', 'selectImage']);
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
          if (arguments.first == 'context' ||
              arguments.first == 'point-context') {
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

      final selectedContext = await provider.selectContext();
      expect(selectedContext?.snapshot?['application'], 'fixture-app');

      final image = await provider.selectImage();
      expect(image?.dataUrl, 'data:image/png;base64,AQID');
      expect(image?.bounds?['width'], 40);
      expect(calls, [
        ['context'],
        ['point-context'],
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

void _mockCursor(WidgetTester tester) {
  const channel = MethodChannel('dev.leanflutter.plugins/screen_retriever');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    channel,
    (_) async => {'dx': 300.0, 'dy': 200.0},
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    ),
  );
}

final class _FakeNativeCaptureClient implements NativeCaptureClient {
  _FakeNativeCaptureClient({required this.onRequest});

  final Future<Map<String, Object?>> Function(String method) onRequest;
  final List<String> requests = [];
  bool closed = false;

  @override
  Future<Map<String, Object?>> request(
    String method, {
    Map<String, Object?> parameters = const {},
    void Function()? onReady,
  }) {
    requests.add(method);
    onReady?.call();
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
