import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/state/zommi_models.dart';

void main() {
  test('Linux skips the unsupported native window shadow method', () {
    expect(supportsNativeWindowShadow('linux'), isFalse);
    expect(supportsNativeWindowShadow('windows'), isTrue);
    expect(supportsNativeWindowShadow('macos'), isTrue);
  });

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
