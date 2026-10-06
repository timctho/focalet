import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:focalet_flutter/desktop/document_thumbnail.dart';
import 'package:focalet_flutter/state/focalet_controller.dart';
import 'package:focalet_flutter/state/focalet_models.dart';
import 'package:focalet_flutter/widgets/content_views.dart';
import 'package:focalet_flutter/widgets/transcript_view.dart';

import 'test_support.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
);
const _document = ArtifactPreview(
  id: 'deck',
  kind: 'html',
  title: 'Slide deck',
  html:
      '<style>.grid{display:grid;grid-template-columns:1fr 2fr}</style>'
      '<script>document.title="Ready"</script><div class="grid">Styled</div>',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _BrowserPlatform platform;
  InAppWebViewPlatform? previous;
  HttpOverrides? overrides;
  setUp(() {
    previous = InAppWebViewPlatform.instance;
    overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    platform = _BrowserPlatform();
    InAppWebViewPlatform.instance = platform;
  });
  tearDown(() {
    if (previous != null) InAppWebViewPlatform.instance = previous;
    HttpOverrides.global = overrides;
  });

  testWidgets(
    'message card uses a browser thumbnail and keeps the floating preview action',
    (tester) async {
      final controller = FocaletController(
        core: RichFakeCore(),
        desktop: FakeDesktopBridge(),
      );
      addTearDown(controller.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 500,
              child: ArtifactCard(artifact: _document, controller: controller),
            ),
          ),
        ),
      );
      await tester.pump();
      for (
        var frame = 0;
        frame < 80 && find.byType(Image).evaluate().isEmpty;
        frame++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(SafeHtmlView), findsNothing);
      expect(find.byType(Image), findsOneWidget);
      expect(platform.pages.single.html, _document.html);
      expect(platform.pages.single.params.initialSize, const Size(1280, 720));
      expect(platform.pages.single.disposed, isTrue);
      expect(
        platform.pages.single.params.initialSettings?.javaScriptBridgeEnabled,
        isFalse,
      );
      await tester.tap(find.text('Preview'));
      await tester.pump();
      expect(controller.previewArtifact?.html, _document.html);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('thumbnail queue survives failure and skips cancelled cards', () async {
    platform.failNext = true;
    final first = DocumentThumbnailRequest(_document).render();
    final skipped = DocumentThumbnailRequest(_document)..cancel();
    final cancelled = skipped.render();
    final recovered = DocumentThumbnailRequest(_document).render();
    await Future.wait([
      expectLater(first, throwsStateError),
      expectLater(cancelled, throwsStateError),
      expectLater(recovered, completion(_png)),
    ]);
    expect(platform.pages.length, 2);
    expect(platform.maximumActive, 1);
    expect(platform.pages.every((page) => page.disposed), isTrue);
    final client = HttpClient();
    try {
      for (final page in platform.pages) {
        await expectLater(
          client.getUrl(page.uri),
          throwsA(isA<SocketException>()),
        );
      }
    } finally {
      client.close(force: true);
    }
  });
}

class _BrowserPlatform extends InAppWebViewPlatform {
  final pages = <_Headless>[];
  final rendered = Completer<void>();
  bool failNext = false;
  int active = 0;
  int maximumActive = 0;

  @override
  PlatformHeadlessInAppWebView createPlatformHeadlessInAppWebView(
    PlatformHeadlessInAppWebViewCreationParams params,
  ) {
    final page = _Headless(params, this, failNext);
    failNext = false;
    pages.add(page);
    return page;
  }
}

class _Headless extends PlatformHeadlessInAppWebView {
  _Headless(super.params, this.owner, this.fail) : super.implementation();
  final _BrowserPlatform owner;
  final bool fail;
  bool disposed = false;
  String? html;
  Uri get uri => Uri.parse(params.initialUrlRequest!.url.toString());

  @override
  Future<void> run() async {
    owner.active++;
    if (owner.active > owner.maximumActive) owner.maximumActive = owner.active;
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(uri)).close();
      html = await utf8.decoder.bind(response).join();
    } finally {
      client.close(force: true);
    }
    if (fail) throw StateError('Renderer startup failed');
    final controller = _Controller();
    params.onLoadStop?.call(
      params.controllerFromPlatform!(controller),
      WebUri(uri.toString()),
    );
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    owner.active--;
    if (!owner.rendered.isCompleted) owner.rendered.complete();
  }
}

class _Controller extends PlatformInAppWebViewController {
  _Controller()
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 'thumbnail'),
      );
  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async => true;
  @override
  Future<Uint8List?> takeScreenshot({
    ScreenshotConfiguration? screenshotConfiguration,
  }) async => _png;
}
