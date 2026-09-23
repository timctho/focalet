import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/desktop/document_thumbnail.dart';
import 'package:zommi_flutter/desktop/linux_document_renderer.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/widgets/linux_document_surface.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      LinuxDocumentRenderer.channel,
      (call) async {
        calls.add(call);
        return call.method == 'evaluate' ? '{"ready":true}' : null;
      },
    );
  });
  tearDown(
    () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
      LinuxDocumentRenderer.channel,
      null,
    ),
  );

  Future<void> event(int id, String name) async {
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      LinuxDocumentRenderer.channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('event', {'id': id, 'event': name}),
      ),
      (_) {},
    );
  }

  testWidgets(
    'native floating surface aligns, resizes, evaluates and closes with its widget',
    (tester) async {
      var loaded = 0;
      var dismissed = 0;
      Future<Object?> Function(String)? evaluate;
      final width = ValueNotifier<double>(400);
      addTearDown(width.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<double>(
            valueListenable: width,
            child: LinuxDocumentSurface(
              uri: Uri.parse('http://127.0.0.1:8000/token/deck.html#slide-12'),
              onLoaded: (value) {
                loaded++;
                evaluate = value;
              },
              onError: (error) => fail(error),
              onDismiss: () => dismissed++,
            ),
            // Keep the surface widget unchanged while its parent's layout changes.
            builder: (context, value, child) => Center(
              child: SizedBox(width: value, height: 280, child: child),
            ),
          ),
        ),
      );
      await tester.pump();
      final open = calls.singleWhere((call) => call.method == 'open');
      final id = open.arguments['id'] as int;
      expect(open.arguments['width'], 400);
      expect(open.arguments['height'], 280);
      expect(open.arguments['x'], 200);
      await event(id, 'ready');
      expect(loaded, 1);
      expect(await evaluate!('document.readyState'), {'ready': true});
      width.value = 500;
      await tester.pump();
      expect(
        calls.lastWhere((call) => call.method == 'bounds').arguments['width'],
        500,
      );
      await event(id, 'dismiss');
      expect(dismissed, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(calls.where((call) => call.method == 'close'), hasLength(1));
      await event(id, 'ready');
      expect(loaded, 1);
    },
  );

  test('Ubuntu thumbnail uses intact document origin and recovers after native renderer failure', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = overrides);
    var attempts = 0;
    final origins = <Uri>[];
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      LinuxDocumentRenderer.channel,
      (call) async {
        expect(call.method, 'thumbnail');
        final uri = Uri.parse(call.arguments['uri'] as String);
        origins.add(uri);
        final client = HttpClient();
        try {
          final response = await (await client.getUrl(uri)).close();
          final html = await utf8.decoder.bind(response).join();
          expect(html, contains('grid-template-columns:1fr 2fr'));
          expect(html, contains('window.ready=true'));
        } finally {
          client.close(force: true);
        }
        if (++attempts == 1) throw PlatformException(code: 'renderer-stopped');
        return bytes;
      },
    );
    const artifact = ArtifactPreview(
      id: 'fixture',
      kind: 'html',
      title: 'Fixture',
      html: '<style>.grid{display:grid;grid-template-columns:1fr 2fr}</style><script>window.ready=true</script><div class="grid">Ocean</div>',
    );
    await expectLater(
      DocumentThumbnailRequest(artifact).render(),
      throwsA(isA<PlatformException>()),
    );
    expect(await DocumentThumbnailRequest(artifact).render(), bytes);
    expect(attempts, 2);
    final client = HttpClient();
    try {
      await expectLater(
        client.getUrl(origins.last),
        throwsA(isA<SocketException>()),
      );
    } finally {
      client.close(force: true);
    }
  }, skip: !Platform.isLinux);
}
