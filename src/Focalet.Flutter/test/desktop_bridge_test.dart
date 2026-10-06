import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:focalet_flutter/core/core_bridge.dart';
import 'package:focalet_flutter/desktop/desktop_bridge.dart';
import 'package:focalet_flutter/desktop/browser_connections.dart';
import 'package:focalet_flutter/state/focalet_models.dart';
import 'package:focalet_flutter/theme/app_preferences.dart';

void main() {
  RuntimeTarget geminiTarget(String path, String hostKind) => RuntimeTarget(
    id: 'runtime-gemini',
    runtimeId: 'gemini',
    adapterId: 'gemini-acp',
    displayName: 'Gemini CLI',
    protocolName: 'ACP',
    executablePath: path,
    executionHost: {'kind': hostKind, 'name': 'Ubuntu'},
  );

  test(
    'Windows sign-in starts an npm launcher with spaces and shell characters',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        "focalet sign-in & quote'-",
      );
      addTearDown(() => directory.delete(recursive: true));
      final launcher = File('${directory.path}/gemini.cmd');
      await launcher.writeAsString('@echo off\r\necho Gemini login\r\n');
      final command = windowsRuntimeSignInCommand(
        geminiTarget(launcher.path, 'native'),
        [],
      );
      final result = await Process.run(
        command.first,
        command.skip(1).where((argument) => argument != '-NoExit').toList(),
      );
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(result.stdout.toString().trim(), 'Gemini login');
    },
    skip: !Platform.isWindows,
  );

  test(
    'WSL sign-in preserves executable paths and literal arguments',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        "focalet sign-in & quote'-",
      );
      addTearDown(() => directory.delete(recursive: true));
      final launcher = File('${directory.path}/gemini');
      await launcher.writeAsString('#!/bin/sh\nprintf \'%s\' "\$1"\n');
      expect((await Process.run('chmod', ['+x', launcher.path])).exitCode, 0);
      const argument = r"literal & $(ignored) ' quoted";
      final command = windowsRuntimeSignInCommand(
        geminiTarget(launcher.path, 'wsl'),
        [argument],
      );
      final result = await Process.run('bash', [
        '--noprofile',
        '--norc',
        '-c',
        command.last,
      ]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(result.stdout, argument);
    },
    skip: Platform.isWindows,
  );

  setUp(() {
    // These unit tests have no Windows runner. A missing native response can
    // otherwise wait on the widget test's fake event loop; individual native
    // surface tests replace this fallback with their explicit channel contract.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('focalet/window_animation'),
          (_) async => null,
        );
    // macOS hides through its native capture channel instead of window_manager.
    // Mock both paths so these provider tests never wait on the host OS.
    const capture = MethodChannel('focalet/capture_permissions');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(capture, (call) async {
          expectSync(call.method, 'hideForCapture');
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('focalet/window_animation'),
          null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('focalet/capture_permissions'),
          null,
        );
  });

  testWidgets(
    'startup centers and fits the saved window size before showing it',
    (tester) async {
      const window = MethodChannel('window_manager');
      const screen = MethodChannel('dev.leanflutter.plugins/screen_retriever');
      var bounds = const Rect.fromLTWH(10, 10, 900, 760);
      var workArea = const Rect.fromLTWH(-1600, 40, 1600, 1000);
      var shown = false;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(window, (call) async {
        if (call.method == 'getBounds') {
          return {
            'x': bounds.left,
            'y': bounds.top,
            'width': bounds.width,
            'height': bounds.height,
          };
        }
        if (call.method == 'setBounds') {
          final args = call.arguments as Map;
          bounds = Rect.fromLTWH(
            args['x'] as double? ?? bounds.left,
            args['y'] as double? ?? bounds.top,
            args['width'] as double? ?? bounds.width,
            args['height'] as double? ?? bounds.height,
          );
        }
        if (call.method == 'show') shown = true;
        return false;
      });
      messenger.setMockMethodCallHandler(screen, (call) async {
        if (call.method == 'getCursorScreenPoint') {
          return {'dx': workArea.center.dx, 'dy': workArea.center.dy};
        }
        final display = {
          'id': 'test-screen',
          'size': {'width': workArea.width, 'height': workArea.height},
          'visiblePosition': {'dx': workArea.left, 'dy': workArea.top},
          'visibleSize': {'width': workArea.width, 'height': workArea.height},
        };
        return call.method == 'getAllDisplays'
            ? {
                'displays': [display],
              }
            : display;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(window, null);
        messenger.setMockMethodCallHandler(screen, null);
      });
      for (final setting in [
        WindowSizeSetting.standard,
        WindowSizeSetting.wide,
      ]) {
        await FlutterDesktopBridge.bootstrap(windowSize: setting);
        expect(bounds.center, workArea.center);
        expect(
          bounds.size,
          setting == WindowSizeSetting.wide
              ? largeWindowSize
              : normalWindowSize,
        );
        expect(shown, isFalse);
      }
      workArea = const Rect.fromLTWH(0, 0, 1024, 700);
      await FlutterDesktopBridge.bootstrap();
      expect(bounds, workArea);
      expect(shown, isFalse);
    },
    skip: !Platform.isLinux,
  );

  testWidgets(
    'desktop registers only Alt+A and removes that registration on close',
    (tester) async {
      await tester.runAsync(() async {
        const hotkey = MethodChannel('dev.leanflutter.plugins/hotkey_manager');
        const hotkeyEvents = MethodChannel(
          'dev.leanflutter.plugins/hotkey_manager_event',
        );
        const window = MethodChannel('window_manager');
        const native = MethodChannel('focalet/window_animation');
        const tray = MethodChannel('tray_manager');
        final calls = <MethodCall>[];
        final windowCalls = <MethodCall>[];
        final messenger = tester.binding.defaultBinaryMessenger;
        for (final channel in [hotkeyEvents, window, tray]) {
          messenger.setMockMethodCallHandler(channel, (call) async {
            if (channel == window) windowCalls.add(call);
            return call.method == 'isMinimized' ? false : null;
          });
        }
        messenger.setMockMethodCallHandler(hotkey, (call) async {
          calls.add(call);
          return null;
        });
        messenger.setMockMethodCallHandler(native, (call) async {
          if (call.method == 'setSelectionShortcut') calls.add(call);
          return call.method == 'getSurfaceGeometry'
              ? {
                  'bounds': [0, 0, 720, 620],
                  'workArea': [0, 0, 1920, 1080],
                  'scale': 1.0,
                  'maximized': false,
                }
              : true;
        });
        addTearDown(() {
          for (final channel in [hotkey, hotkeyEvents, window, native, tray]) {
            messenger.setMockMethodCallHandler(channel, null);
          }
        });
        final client = _FakeNativeCaptureClient(onRequest: (_) async => {});
        final bridge = FlutterDesktopBridge(
          presentGnome: () async {},
          useNativeSurface: true,
          useGnomeIntegration: false,
          captureProvider: WindowsCaptureProvider(
            captureClient: client,
            selectorClient: client,
          ),
        );
        final ready = await bridge.initialize().timeout(
          const Duration(seconds: 15),
        );
        expect(ready.contextShortcut, isTrue);
        expect(ready.imageShortcut, isFalse);
        expect(
          windowCalls
              .where((call) => call.method == 'setPreventClose')
              .single
              .arguments,
          {'isPreventClose': true},
        );
        if (Platform.isWindows) {
          expect(calls.single.arguments, {'key': 65, 'modifiers': 1});
          await bridge.close();
          expect(calls.last.method, 'setSelectionShortcut');
          expect(calls.last.arguments, isNull);
          return;
        }
        final registration = calls
            .where((call) => call.method == 'register')
            .single;
        final parameters = registration.arguments as Map;
        expect(parameters['modifiers'], ['alt']);
        expect(
          (parameters['key'] as Map)['usageCode'],
          PhysicalKeyboardKey.keyA.usbHidUsage,
        );
        await bridge.close();
        expect(
          calls.where((call) => call.method == 'unregister').single.arguments,
          parameters,
        );
      });
    },
  );

  testWidgets('closing hides the window, tray reopens it, and Quit exits', (
    tester,
  ) async {
    const window = MethodChannel('window_manager');
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(window, (
      call,
    ) async {
      calls.add(call.method);
      return false;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        window,
        null,
      ),
    );
    final bridge = FlutterDesktopBridge();
    final invocations = <DesktopInvocation>[];
    final subscription = bridge.invocations.listen(invocations.add);
    addTearDown(subscription.cancel);

    // The custom X and native close requests (such as Alt+F4) both hide.
    await bridge.closeWindow();
    bridge.onWindowClose();
    await tester.pump();
    expect(calls, ['hide', 'hide']);

    bridge.onTrayIconMouseDown();
    bridge.onTrayMenuItemClick(MenuItem(key: 'open'));
    await tester.pump();
    expect(invocations.map((event) => event.kind), [
      DesktopInvocationKind.open,
      DesktopInvocationKind.open,
    ]);
    expect(calls, ['hide', 'hide']);

    bridge.onTrayMenuItemClick(MenuItem(key: 'exit'));
    await tester.pump();
    expect(calls, ['hide', 'hide', 'destroy']);
  });

  test(
    'Windows selection batches preserve each image and its own coordinates',
    () async {
      final client = _FakeNativeCaptureClient(
        onRequest: (_) async => {
          'cancelled': false,
          'selections': [
            for (final index in [1, 2])
              {
                'dataUrl': 'data:image/png;base64,$index',
                'bounds': {'x': index * 100},
                'snapshot': {'windowTitle': 'Window $index'},
                'alignment': {'status': 'image-only'},
              },
          ],
        },
      );
      final provider = WindowsCaptureProvider(
        captureClient: client,
        selectorClient: client,
      );
      final results = await provider.selectContext();
      expect(results.map((item) => item.image?.dataUrl), [
        'data:image/png;base64,1',
        'data:image/png;base64,2',
      ]);
      expect(results.map((item) => item.image?.bounds?['x']), [100, 200]);
      expect(results.map((item) => item.snapshot?['windowTitle']), [
        'Window 1',
        'Window 2',
      ]);
    },
  );
  test('browser connection controls use the shared capture helper and preserve the chosen browser', () async {
    final client = _FakeNativeCaptureClient(
      onRequest: (method) async => method == 'browserConnections'
          ? {
              'browsers': [
                {
                  'browser': 'edge',
                  'state': 'setup-required',
                  'message': 'Enable access.',
                },
                {
                  'browser': 'chrome',
                  'state': 'connected',
                  'message': 'Connected.',
                },
              ],
            }
          : {'browser': 'edge', 'state': 'connected', 'message': 'Connected.'},
    );
    for (final provider in <BrowserConnectionSettings>[
      WindowsCaptureProvider(captureClient: client),
      UnixCaptureProvider(browser: client),
    ]) {
      final statuses = await provider.browserConnections();
      expect(statuses.map((status) => status.browser), CaptureBrowser.values);
      final edge = await provider.reconnectBrowser(CaptureBrowser.edge);
      expect(edge.state, 'connected');
      expect(client.requests.last, 'reconnectBrowser');
      expect(client.requestParameters.last, {
        'browser': 'edge',
        'browserPageDetails': true,
      });
      (provider as BrowserCaptureSettings).setBrowserPageDetails(false);
      await provider.browserConnections();
      expect(client.requestParameters.last['browserPageDetails'], isFalse);
    }
  });
  test('disabling webpage details reaches both native helpers for every capture gesture', () async {
    final ordinary = _FakeNativeCaptureClient(onRequest: (_) async => {});
    final selector = _FakeNativeCaptureClient(
      onRequest: (_) async => {'cancelled': true},
    );
    final provider = WindowsCaptureProvider(
      captureClient: ordinary,
      selectorClient: selector,
    );
    provider.setBrowserPageDetails(false);
    await provider.capture();
    await provider.selectContext();
    await provider.selectImage();
    for (final parameters in [
      ...ordinary.requestParameters,
      ...selector.requestParameters,
    ]) {
      expect(parameters['browserPageDetails'], isFalse);
    }
    provider.setBrowserPageDetails(true);
    await provider.capture();
    expect(ordinary.requestParameters.last['browserPageDetails'], isTrue);
    await provider.close();
  });
  test(
    'capture theme follows preference changes for both selection entry points',
    () async {
      final client = _FakeNativeCaptureClient(
        onRequest: (_) async => {'cancelled': true},
      );
      final provider = WindowsCaptureProvider(captureClient: client);
      provider.setCaptureTheme({'accent': 0xff387da8, 'surface': 0xff282828});
      await provider.selectContext();
      expect(client.requestParameters.last['theme'], {
        'accent': 0xff387da8,
        'surface': 0xff282828,
      });
      provider.setCaptureTheme({'accent': 0xffc5ecd4, 'surface': 0xffffffff});
      await provider.selectImage();
      expect(client.requestParameters.last['theme'], {
        'accent': 0xffc5ecd4,
        'surface': 0xffffffff,
      });
      await provider.close();
    },
  );
  testWidgets('native resize feedback reports the actual physical viewport', (
    tester,
  ) async {
    const channel = MethodChannel('focalet/window_animation');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return null;
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    tester.view.physicalSize = const Size(1380, 1140);
    tester.view.devicePixelRatio = 1.5;
    FlutterDesktopBridge(useNativeSurface: true).didChangeMetrics();
    await tester.idle();
    expect(calls, hasLength(1));
    expect(calls.single.method, 'surfaceMetricsChanged');
    expect(calls.single.arguments, {'width': 1380.0, 'height': 1140.0});
    FlutterDesktopBridge(useNativeSurface: false).didChangeMetrics();
    await tester.idle();
    expect(calls, hasLength(1));
  });

  testWidgets('a newer native size choice supersedes a pending geometry read', (
    tester,
  ) async {
    const nativeChannel = MethodChannel('focalet/window_animation');
    const windowChannel = MethodChannel('window_manager');
    final pending = Completer<Map<String, Object?>>();
    final geometry = <String, Object?>{
      'bounds': [440, 360, 720, 620],
      'workArea': [0, 0, 1600, 1000],
      'scale': 1.5,
      'maximized': false,
    };
    var reads = 0;
    final operations = <MethodCall>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      if (call.method == 'getSurfaceGeometry') {
        return ++reads == 1 ? pending.future : geometry;
      }
      operations.add(call);
      return true;
    });
    messenger.setMockMethodCallHandler(windowChannel, (_) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(nativeChannel, null);
      messenger.setMockMethodCallHandler(windowChannel, null);
    });
    final bridge = FlutterDesktopBridge(useNativeSurface: true);
    final wide = bridge.setSurface(expanded: true, large: true);
    await tester.idle();
    expect(reads, 1);
    final standard = bridge.setSurface(expanded: true);
    final max = bridge.setSurface(expanded: true, maximized: true);
    pending.complete(geometry);
    await Future.wait([wide, standard, max]);
    expect(reads, 2);
    expect(operations, hasLength(1));
    expect(operations.single.method, 'setSurfaceBounds');
    expect(operations.single.arguments['maximized'], isTrue);
  });

  testWidgets('Windows size choices send one native endpoint without a tween', (
    tester,
  ) async {
    const nativeChannel = MethodChannel('focalet/window_animation');
    const windowChannel = MethodChannel('window_manager');
    var bounds = const Rect.fromLTWH(440, 360, 720, 620);
    var maximized = false;
    final operations = <Map<String, Object?>>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      if (call.method == 'getSurfaceGeometry') {
        return {
          'bounds': [bounds.left, bounds.top, bounds.width, bounds.height],
          'workArea': [0, 0, 1600, 1000],
          'scale': 1.5,
          'maximized': maximized,
        };
      }
      expect(call.method, 'setSurfaceBounds');
      final arguments = Map<String, Object?>.from(call.arguments as Map);
      operations.add(arguments);
      bounds = Rect.fromLTWH(
        arguments['toX']! as double,
        arguments['toY']! as double,
        arguments['toWidth']! as double,
        arguments['toHeight']! as double,
      );
      maximized = arguments['maximized'] == true;
      return true;
    });
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      expect(
        call.method,
        isIn(['setResizable', 'setMinimumSize', 'setAlwaysOnTop']),
      );
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(nativeChannel, null);
      messenger.setMockMethodCallHandler(windowChannel, null);
    });
    final bridge = FlutterDesktopBridge(useNativeSurface: true);
    for (final setting in [
      WindowSizeSetting.standard,
      WindowSizeSetting.wide,
      WindowSizeSetting.standard,
      WindowSizeSetting.maximized,
      WindowSizeSetting.wide,
      WindowSizeSetting.maximized,
      WindowSizeSetting.standard,
    ]) {
      operations.clear();
      await bridge.setSurface(
        expanded: true,
        large: setting == WindowSizeSetting.wide,
        maximized: setting == WindowSizeSetting.maximized,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(operations, hasLength(1));
      expect(maximized, setting == WindowSizeSetting.maximized);
      expect(bounds.size, switch (setting) {
        WindowSizeSetting.standard => normalWindowSize,
        WindowSizeSetting.wide => largeWindowSize,
        WindowSizeSetting.maximized => const Size(1600, 1000),
      });
      if (!maximized) {
        expect(bounds.center.dx, 800);
        expect(bounds.bottom, 500 + normalWindowSize.height / 2);
      }
    }
  });

  testWidgets('native handoff completes before the latest size is applied', (
    tester,
  ) async {
    const nativeChannel = MethodChannel('focalet/window_animation');
    const windowChannel = MethodChannel('window_manager');
    final pending = Completer<bool>();
    final operations = <MethodCall>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      if (call.method == 'getSurfaceGeometry') {
        return {
          'bounds': [440, 360, 720, 620],
          'workArea': [0, 0, 1600, 1000],
          'scale': 1.5,
          'maximized': false,
        };
      }
      operations.add(call);
      return operations.length == 1 ? pending.future : true;
    });
    messenger.setMockMethodCallHandler(windowChannel, (_) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(nativeChannel, null);
      messenger.setMockMethodCallHandler(windowChannel, null);
      nativeChannel.setMethodCallHandler(null);
    });
    final bridge = FlutterDesktopBridge(useNativeSurface: true);
    final wide = bridge.setSurface(expanded: true, large: true);
    await tester.idle();
    final standard = bridge.setSurface(expanded: true);
    final max = bridge.setSurface(expanded: true, maximized: true);
    await tester.idle();
    expect(operations, hasLength(1));
    pending.complete(true);
    await Future.wait([wide, standard, max]);
    expect(operations, hasLength(2));
    expect(operations.last.arguments['maximized'], isTrue);
  });

  testWidgets('a failed native handoff releases the queue for Max and Restore', (
    tester,
  ) async {
    const nativeChannel = MethodChannel('focalet/window_animation');
    const windowChannel = MethodChannel('window_manager');
    final pending = Completer<bool>();
    final operations = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      if (call.method == 'getSurfaceGeometry') {
        return {
          'bounds': [0, 0, 1600, 1000],
          'workArea': [0, 0, 1600, 1000],
          'scale': 1.0,
          'maximized': true,
        };
      }
      operations.add(call.method);
      return operations.length == 1 ? pending.future : true;
    });
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      fail(
        'Native Max/Restore must not bypass the protected path: ${call.method}',
      );
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(nativeChannel, null);
      messenger.setMockMethodCallHandler(windowChannel, null);
      nativeChannel.setMethodCallHandler(null);
    });
    final bridge = FlutterDesktopBridge(useNativeSurface: true);
    final first = bridge.toggleMaximized();
    final failure = expectLater(first, throwsA(isA<PlatformException>()));
    await tester.idle();
    final second = bridge.toggleMaximized();
    await tester.idle();
    expect(operations, ['toggleSurfaceMaximized']);
    pending.completeError(PlatformException(code: 'surface_handoff_failed'));
    await failure;
    expect(await second, isTrue);
    expect(operations, ['toggleSurfaceMaximized', 'toggleSurfaceMaximized']);
  });

  testWidgets('native resize sends one bounds operation with Max state', (
    tester,
  ) async {
    const channel = MethodChannel('focalet/window_animation');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return true;
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
    await setNativeSurfaceBounds(
      bounds: const Rect.fromLTWH(-1200, 0, 1200, 800),
      scaleFactor: 1.5,
      maximized: true,
    );
    expect(calls, hasLength(1));
    expect(calls.single.method, 'setSurfaceBounds');
    expect(calls.single.arguments, {
      'toX': -1200.0,
      'toY': 0.0,
      'toWidth': 1200.0,
      'toHeight': 800.0,
      'scaleFactor': 1.5,
      'maximized': true,
    });
  });

  test('native window bounds align to physical pixels at fractional DPI', () {
    final from = pixelAlignedSurfaceBounds(
      Rect.fromLTWH(660 / 1.5, 571 / 1.5, 1080 / 1.5, 930 / 1.5),
      1.5,
    );
    final to = pixelAlignedSurfaceBounds(
      Rect.fromLTWH(510 / 1.5, 1501 / 1.5 - 760, 920, 760),
      1.5,
    );
    expect(from.expandToInclude(to), to);
    expect(to.expandToInclude(from), to);
    expect(
      pixelAlignedSurfaceBounds(const Rect.fromLTWH(-5.1, 0.1, 3.2, 4), 1.5),
      Rect.fromLTRB(-8 / 1.5, 0, -3 / 1.5, 6 / 1.5),
    );
  });

  testWidgets('native geometry arrives in one consistent monitor snapshot', (
    tester,
  ) async {
    const channel = MethodChannel('test/surface-geometry');
    var requests = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      requests++;
      expect(call.method, 'getSurfaceGeometry');
      return {
        'bounds': [-1200, 120, 720, 620],
        'workArea': [-1600, 0, 1600, 1000],
        'scale': 1.5,
        'maximized': true,
      };
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
    final geometry = await readNativeSurfaceGeometry(channel);
    expect(geometry.bounds, const Rect.fromLTWH(-1200, 120, 720, 620));
    expect(geometry.workArea, const Rect.fromLTWH(-1600, 0, 1600, 1000));
    expect(geometry.scale, 1.5);
    expect(geometry.maximized, isTrue);
    expect(requests, 1);
  });

  testWidgets(
    'non-Windows surface fallback animates Standard and Wide in both directions',
    (tester) async {
      const windowChannel = MethodChannel('window_manager');
      const displayChannel = MethodChannel(
        'dev.leanflutter.plugins/screen_retriever',
      );
      var bounds = const Rect.fromLTWH(440, 360, 720, 620);
      final frames = <Rect>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(windowChannel, (call) async {
        if (call.method == 'isMaximized') return false;
        if (call.method == 'getBounds') {
          return {
            'x': bounds.left,
            'y': bounds.top,
            'width': bounds.width,
            'height': bounds.height,
          };
        }
        if (call.method == 'setBounds') {
          final arguments = Map<String, Object?>.from(call.arguments as Map);
          bounds = Rect.fromLTWH(
            arguments['x']! as double,
            arguments['y']! as double,
            arguments['width']! as double,
            arguments['height']! as double,
          );
          frames.add(bounds);
        }
        return null;
      });
      messenger.setMockMethodCallHandler(
        displayChannel,
        (call) async => {
          'displays': [
            {
              'id': 'display',
              'size': {'width': 1600.0, 'height': 1040.0},
              'visibleSize': {'width': 1600.0, 'height': 1000.0},
              'visiblePosition': {'dx': 0.0, 'dy': 0.0},
              'scaleFactor': 1.5,
            },
          ],
        },
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(windowChannel, null);
        messenger.setMockMethodCallHandler(displayChannel, null);
      });
      final bridge = FlutterDesktopBridge();
      await bridge.setSurface(expanded: true, animate: false);
      final anchor = Offset(bounds.center.dx, bounds.bottom);
      for (final large in [true, false]) {
        frames.clear();
        await tester.runAsync(
          () => bridge.setSurface(expanded: true, large: large),
        );
        expect(frames.toSet().length, greaterThan(4));
        expect(frames.last.size, large ? largeWindowSize : normalWindowSize);
        for (final frame in frames) {
          expect(frame.center.dx, closeTo(anchor.dx, 1));
          expect(frame.bottom, closeTo(anchor.dy, 1));
        }
      }
    },
    // Windows uses the separately tested native surface transition.
    skip: Platform.isWindows,
  );

  for (final pixelRatio in [1.0, 1.25, 1.5, 2.0]) {
    for (final kind in [
      DesktopInvocationKind.context,
      DesktopInvocationKind.image,
    ]) {
      testWidgets(
        'Windows $kind capture API uses the intended coordinates at $pixelRatio DPI',
        (tester) async {
          tester.view.devicePixelRatio = pixelRatio;
          addTearDown(tester.view.resetDevicePixelRatio);
          _mockCursor(tester, point: const Offset(-320, 200));
          const windowChannel = MethodChannel('window_manager');
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            windowChannel,
            (call) async => switch (call.method) {
              'isVisible' => true,
              'isMinimized' => false,
              _ => null,
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(windowChannel, null),
          );
          final capture = _FakeNativeCaptureClient(
            onRequest: (_) async => {
              'snapshot': {'application': 'Fixture'},
            },
          );
          final selector = _FakeNativeCaptureClient(
            onRequest: (_) async => {'cancelled': true},
          );
          final bridge = FlutterDesktopBridge(
            presentGnome: () async {},
            captureProvider: WindowsCaptureProvider(
              captureClient: capture,
              selectorClient: selector,
            ),
          );
          if (kind == DesktopInvocationKind.context) {
            await bridge.captureContext();
          } else {
            await bridge.selectImageContext();
          }
          if (kind == DesktopInvocationKind.context) {
            expect(capture.requestParameters.single['point'], {
              'x': (-320 * pixelRatio).round(),
              'y': (200 * pixelRatio).round(),
            });
          } else {
            expect(capture.requests, isEmpty);
            expect(selector.requests, ['selectImage']);
            expect(
              selector.requestParameters.single.containsKey('point'),
              isFalse,
            );
          }
        },
      );
    }
  }

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
          presentGnome: () async {},
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

  test(
    'Alt+A requests the same content selection used by the composer',
    () async {
      final captureClient = _FakeNativeCaptureClient(
        onRequest: (_) async => {},
      );
      final bridge = FlutterDesktopBridge(
        presentGnome: () async {},
        captureProvider: WindowsCaptureProvider(
          captureClient: captureClient,
          selectorClient: captureClient,
        ),
      );
      final events = <DesktopInvocation>[];
      final subscription = bridge.invocations.listen(events.add);
      addTearDown(subscription.cancel);
      await bridge.invokeContentSelection();
      expect(events.single.kind, DesktopInvocationKind.selectContent);
      expect(captureClient.requests, isEmpty);
    },
  );

  testWidgets(
    'image selector never waits for or attaches unrelated pointer context',
    (tester) async {
      _mockCursor(tester);
      const channel = MethodChannel('window_manager');
      final windowCalls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('focalet/capture_permissions'),
        (call) async {
          expectSync(call.method, 'hideForCapture');
          windowCalls.add('hide');
          return null;
        },
      );
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
        presentGnome: () async {},
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
      expect(completed, isTrue);
      expect(captureClient.requests, isEmpty);
      captured.complete({
        'snapshot': {'application': 'Original window'},
      });
      await tester.pump();
      final attachment = await selection;
      expect(attachment?.hasImage, isTrue);
      expect(attachment?.snapshot?['application'], 'Screen');
      expect(
        attachment?.snapshot?['region'],
        containsPair('status', 'image-only'),
      );
      expect(attachment?.previewText, startsWith('Image only'));
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
    const channel = MethodChannel('focalet/window_animation');
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
    const workArea = Rect.fromLTWH(100, 50, 1600, 1000);
    final initial = anchoredSurfaceBounds(
      anchor: initialSurfaceAnchor(workArea, normalWindowSize),
      workArea: workArea,
      size: normalWindowSize,
    );
    expect(initial.center.dx, workArea.center.dx);
    expect(initial.center, workArea.center);

    const anchor = Offset(800, 950);
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

  test('Windows text and selection share one host without waiting for text completion', () async {
    final pending = Completer<Map<String, Object?>>();
    final shared = _FakeNativeCaptureClient(
      onRequest: (method) => method == 'capture'
          ? pending.future
          : Future.value(<String, Object?>{'cancelled': true}),
    );
    final provider = WindowsCaptureProvider(captureClient: shared);
    await provider.initialize();
    expect(shared.requests, ['ping']);
    final capture = provider.capture();
    expect(
      await provider.selectContext().timeout(const Duration(milliseconds: 100)),
      isEmpty,
    );
    expect(
      await provider.selectImage().timeout(const Duration(milliseconds: 100)),
      isNull,
    );
    expect(shared.requests, [
      'ping',
      'capture',
      'selectContent',
      'selectImage',
    ]);
    pending.complete(<String, Object?>{});
    await capture;
    await provider.close();
    expect(shared.closed, isTrue);
  });

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
          'selectContent' => <String, Object?>{
            'cancelled': false,
            'snapshot': <String, Object?>{'application': 'clicked-window'},
            'previewText': 'Clicked window context',
            'dataUrl': 'data:image/png;base64,YQ==',
            'bounds': <String, Object?>{
              'x': -200,
              'y': 120,
              'width': 350,
              'height': 40,
            },
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
      expect(selectorClient.requests, ['selectContent']);
      expect(selectedContext.single.snapshot?['application'], 'clicked-window');
      expect(
        selectedContext.single.image?.dataUrl,
        'data:image/png;base64,YQ==',
      );
      expect(selectedContext.single.image?.bounds?['x'], -200);

      final image = await provider.selectImage().timeout(
        const Duration(milliseconds: 100),
      );
      expect(selectorClient.requests, ['selectContent', 'selectImage']);
      expect(image?.bounds?['width'], 3);

      captureResult.complete(<String, Object?>{'snapshot': null});
      await pendingCapture;
      await provider.close();
      expect(captureClient.closed, isTrue);
      expect(selectorClient.closed, isTrue);
    },
  );

  test(
    'GNOME integration only activates the content selection shortcut',
    () async {
      final client = _FakeGnomeShortcutClient();
      var contextInvocations = 0;
      final errors = <Object>[];
      final registration = await registerGnomeShortcuts(
        client,
        onContext: () => contextInvocations += 1,
        onError: errors.add,
      );
      expect(registration.readiness.contextShortcut, isTrue);
      expect(registration.readiness.imageShortcut, isFalse);

      client.emit('context');
      client.emit('image');
      client.emit('unknown');
      expect(contextInvocations, 1);
      expect(errors, isEmpty);

      await registration.subscription.cancel();
      await client.close();
    },
  );

  test(
    'GNOME integration process client parses readiness and activations',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'focalet-wayland-shortcut-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final script = File('${directory.path}/portal_fixture.py');
      await script.writeAsString('''
import sys
print('{"event":"ready","contextShortcut":true,"imageShortcut":false}', flush=True)
print('{"event":"activated","shortcutId":"context"}', flush=True)
print('{"event":"activated","shortcutId":"image"}', flush=True)
sys.stdin.read()
''');
      final client = ProcessGnomeShortcutClient(
        Platform.isWindows ? 'python' : 'python3',
        argumentsBeforeCommand: [script.path],
      );
      addTearDown(client.close);
      final activations = client.activations.take(1).toList();

      final readiness = await client.initialize();
      expect(readiness.contextShortcut, isTrue);
      expect(readiness.imageShortcut, isFalse);
      expect(await activations, ['context']);
    },
  );

  test('Linux capture helper resolves beside the packaged Flutter binary', () {
    expect(
      resolveLinuxCaptureExecutable(
        applicationDirectory: '/opt/focalet',
        pathSeparator: '/',
        environment: const {},
        exists: (path) => path == '/opt/focalet/focalet-linux-capture',
      ),
      '/opt/focalet/focalet-linux-capture',
    );
    expect(
      resolveLinuxCaptureExecutable(
        environment: const {'FOCALET_LINUX_CAPTURE_HOST': '/custom/capture'},
        exists: (_) => false,
      ),
      '/custom/capture',
    );
  });
}

void _mockCursor(WidgetTester tester, {Offset point = const Offset(300, 200)}) {
  const channel = MethodChannel('dev.leanflutter.plugins/screen_retriever');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    channel,
    (_) async => {'dx': point.dx, 'dy': point.dy},
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
  final List<Map<String, Object?>> requestParameters = [];
  bool closed = false;

  @override
  Future<Map<String, Object?>> request(
    String method, {
    Map<String, Object?> parameters = const {},
    void Function()? onReady,
  }) {
    requests.add(method);
    requestParameters.add(parameters);
    onReady?.call();
    return onRequest(method);
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

final class _FakeGnomeShortcutClient implements GnomeShortcutClient {
  final StreamController<String> _controller =
      StreamController<String>.broadcast(sync: true);

  void emit(String shortcut) => _controller.add(shortcut);

  @override
  Stream<String> get activations => _controller.stream;

  @override
  Future<DesktopReadiness> initialize() async =>
      const DesktopReadiness(contextShortcut: true);

  @override
  Future<void> close() => _controller.close();
}
