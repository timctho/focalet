import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/desktop/capture_permissions.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';

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
          return ProcessResult(2, 0, 'https://example.com/zommi\n', '');
        },
      );
      final capture = await provider.capture();
      expect(calls, 2);
      expect(capture.snapshot?['application'], app);
      expect(capture.snapshot?['windowTitle'], 'Test page');
      expect(capture.previewText, contains('https://example.com/zommi'));
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
      selectRegion: () async {
        events.add('selector');
        return image;
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

  test('Zommi never labels its own window as the external context', () async {
    final provider = PortableCaptureProvider(
      runCommand: (_, _, _) async => ProcessResult(1, 0, 'Zommi\nZommi\n', ''),
      screenAccessAllowed: () async => true,
      selectRegion: () async =>
          const ImageSelection(dataUrl: 'data:image/png;base64,iVBORw0KGgo='),
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

  test('Screen Recording denial is actionable and never treated as selection cancellation', () async {
    var requests = 0;
    var selections = 0;
    final provider = PortableCaptureProvider(
      screenAccessAllowed: () async => false,
      requestScreenAccess: () async {
        requests++;
      },
      selectRegion: () async {
        selections++;
        return null;
      },
    );
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
    expect(requests, 1);
    expect(selections, 0);
  });

  test('granting permission permits capture, preserves payload, and still supports cancel', () async {
    var allowed = false;
    const selection = ImageSelection(
      dataUrl: 'data:image/png;base64,iVBORw0KGgo=',
    );
    ImageSelection? next = selection;
    var requests = 0;
    final provider = PortableCaptureProvider(
      screenAccessAllowed: () async => allowed,
      requestScreenAccess: () async {
        requests++;
        allowed = true;
      },
      selectRegion: () async => next,
    );
    expect(await provider.selectImage(), same(selection));
    next = null;
    expect(await provider.selectImage(), isNull);
    expect(requests, 1);
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
}
