import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';

void main() {
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
