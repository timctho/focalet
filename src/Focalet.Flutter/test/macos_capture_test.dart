import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focalet_flutter/desktop/capture_permissions.dart';
import 'package:focalet_flutter/desktop/desktop_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Mac context keeps app, title and the supported browser URL', () async {
    for (final app in [
      'Safari',
      'Google Chrome',
      'Microsoft Edge',
      'Brave Browser',
    ]) {
      var calls = 0;
      final provider = PortableCaptureProvider(
        runCommand: (executable, arguments, timeout) async {
          expect(executable, 'osascript');
          calls++;
          if (calls == 1) return ProcessResult(1, 0, '$app\nTest page\n', '');
          expect(arguments.last, contains('tell application "$app"'));
          return ProcessResult(2, 0, 'https://example.com/focalet\n', '');
        },
      );
      final capture = await provider.capture();
      expect(calls, 2);
      expect(capture.snapshot?['application'], app);
      expect(capture.snapshot?['windowTitle'], 'Test page');
      expect(capture.previewText, contains('https://example.com/focalet'));
    }
  });

  test('region attachment retains foreground context; missing context and cancel preserve image semantics', () async {
    var denied = false;
    ImageSelection? image = const ImageSelection(
      dataUrl: 'data:image/png;base64,iVBORw0KGgo=',
    );
    final events = <String>[];
    final provider = PortableCaptureProvider(
      runCommand: (_, _, _) async {
        events.add('context');
        return ProcessResult(1, denied ? 1 : 0, 'TextEdit\nFixture\n', '');
      },
      screenAccessAllowed: () async => true,
      selectRegions: () async {
        events.add('selector');
        return [?image];
      },
    );
    var selected = await provider.selectContext();
    expect(events, ['context', 'selector']);
    expect(selected.single.image?.dataUrl, image.dataUrl);
    expect(selected.single.image?.snapshot?['application'], 'TextEdit');
    denied = true;
    selected = await provider.selectContext();
    expect(selected.single.image?.dataUrl, image.dataUrl);
    expect(selected.single.image?.snapshot, isNull);
    image = null;
    expect(await provider.selectContext(), isEmpty);
  });

  test('Focalet never labels its own window as the external context', () async {
    final provider = PortableCaptureProvider(
      runCommand: (_, _, _) async =>
          ProcessResult(1, 0, 'Focalet\nFocalet\n', ''),
      screenAccessAllowed: () async => true,
      selectRegions: () async => const [
        ImageSelection(dataUrl: 'data:image/png;base64,iVBORw0KGgo='),
      ],
    );
    await expectLater(provider.capture(), throwsStateError);
    final selected = await provider.selectContext();
    expect(selected.single.image, isNotNull);
    expect(selected.single.image?.snapshot, isNull);
  });

  test(
    'browser Automation denial or timeout preserves available app context',
    () async {
      for (final timeout in [false, true]) {
        var calls = 0;
        final provider = PortableCaptureProvider(
          runCommand: (_, arguments, _) async {
            if (++calls == 1) {
              return ProcessResult(1, 0, 'Safari\nTest page\n', '');
            }
            if (timeout) throw TimeoutException('Automation timed out');
            return ProcessResult(
              2,
              1,
              '',
              'Not authorized to send Apple events',
            );
          },
        );
        final capture = await provider.capture();
        expect(capture.snapshot?['application'], 'Safari');
        expect(capture.snapshot?['windowTitle'], 'Test page');
        expect(capture.snapshot?['surfaceKind'], 'Window');
      }
    },
  );

  test(
    'non-browser app needs only foreground lookup; denial explains permission',
    () async {
      var calls = 0;
      var denied = false;
      final provider = PortableCaptureProvider(
        runCommand: (_, _, _) async {
          calls++;
          return ProcessResult(
            1,
            denied ? 1 : 0,
            'TextEdit\nCapture fixture\n',
            denied ? 'not allowed' : '',
          );
        },
      );
      expect((await provider.capture()).snapshot?['application'], 'TextEdit');
      expect(calls, 1);
      denied = true;
      await expectLater(
        provider.capture(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Accessibility and Automation'),
          ),
        ),
      );
    },
  );

  test(
    'repeated denied captures only check status and never request permission',
    () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MacCapturePermissions.channel, (
            call,
          ) async {
            calls.add(call.method);
            return {'accessibility': false, 'screenRecording': false};
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(MacCapturePermissions.channel, null),
      );
      var selections = 0;
      final provider = PortableCaptureProvider(
        selectRegion: () async {
          selections++;
          return null;
        },
      );
      for (var attempt = 0; attempt < 3; attempt++) {
        await expectLater(
          provider.selectImage(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('Screen Recording'),
            ),
          ),
        );
      }
      expect(calls, ['status', 'status', 'status']);
      expect(selections, 0);
    },
  );

  test('granting permission permits capture, preserves payload, and still supports cancel', () async {
    var allowed = false;
    const selection = ImageSelection(
      dataUrl: 'data:image/png;base64,iVBORw0KGgo=',
    );
    ImageSelection? next = selection;
    final provider = PortableCaptureProvider(
      screenAccessAllowed: () async => allowed,
      selectRegion: () async => next,
    );
    await expectLater(provider.selectImage(), throwsStateError);
    allowed = true;
    expect(await provider.selectImage(), same(selection));
    next = null;
    expect(await provider.selectImage(), isNull);
  });

  test(
    'permission status is read only; requests name the explicit permission',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MacCapturePermissions.channel, (
            call,
          ) async {
            calls.add(call);
            return {'accessibility': true, 'screenRecording': false};
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(MacCapturePermissions.channel, null),
      );
      final bridge = MacCapturePermissions(supported: true);
      final status = await bridge.capturePermissions();
      expect(status.accessibility, isTrue);
      expect(status.screenRecording, isFalse);
      expect(calls.single.method, 'status');
      await bridge.requestCapturePermission(CapturePermission.screenRecording);
      expect(calls.last.method, 'request');
      expect(calls.last.arguments, {'permission': 'screenRecording'});
    },
  );

  test('native Mac selector preserves a batch in order and cancellation returns nothing', () async {
    var cancelled = false;
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MacCapturePermissions.channel, (call) async {
          calls.add(call.method);
          if (cancelled) return <Object?>[];
          return [
            for (final x in [20, 200])
              {
                'dataUrl': png,
                'bounds': {'x': x, 'y': 30, 'width': 1, 'height': 1},
                'alignment': {
                  'status': 'image-only',
                  'screenBounds': {'x': x, 'y': 30, 'width': 1, 'height': 1},
                  'mapping': {
                    'imageBounds': {'x': 0, 'y': 0, 'width': 1, 'height': 1},
                  },
                },
              },
          ];
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MacCapturePermissions.channel, null),
    );
    final provider = PortableCaptureProvider(
      runCommand: (_, _, _) async => ProcessResult(1, 1, '', 'Context denied'),
      screenAccessAllowed: () async => true,
      selectRegion: () async =>
          throw StateError('Single-region selector must not be used'),
    );
    final selected = await provider.selectContext();
    expect(calls, ['selectRegions']);
    expect(selected.map((result) => result.image?.bounds?['x']), [20, 200]);
    expect(selected.map((result) => result.image?.dataUrl), [png, png]);
    expect(selected.first.image?.alignment?['status'], 'image-only');
    cancelled = true;
    expect(await provider.selectContext(), isEmpty);
  });

  test(
    'denied screen access never starts multi-selection or foreground lookup',
    () async {
      final provider = PortableCaptureProvider(
        screenAccessAllowed: () async => false,
        runCommand: (_, _, _) async =>
            throw StateError('Must not look up context'),
        selectRegions: () async => throw StateError('Must not open selector'),
      );
      await expectLater(
        provider.selectContext(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Screen Recording'),
          ),
        ),
      );
    },
  );
}
