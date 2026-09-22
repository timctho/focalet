import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/desktop/artifact_loader.dart';
import 'package:zommi_flutter/desktop/artifact_paths.dart';
import 'package:zommi_flutter/desktop/document_server.dart';
import 'package:zommi_flutter/desktop/notification_icon.dart';
import 'package:zommi_flutter/state/history_mapper.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';

import 'test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('file links retain WSL authority, spaces and slide fragments', () {
    const link =
        'file://wsl.localhost/Ubuntu/home/example/My%20Files/deck.html#slide-12';
    final windows = resolveArtifactFileUri(
      link,
      cwd: '/home/example',
      windows: true,
      runtimeDistribution: 'Ubuntu',
    );
    expect(windows.host, 'wsl.localhost');
    expect(
      Uri.decodeComponent(windows.path),
      '/Ubuntu/home/example/My Files/deck.html',
    );
    expect(windows.fragment, 'slide-12');
    final linux = resolveArtifactFileUri(
      link,
      cwd: '/home/example',
      windows: false,
      localDistribution: 'Ubuntu',
    );
    expect(
      linux.replace(fragment: '').toFilePath(),
      '/home/example/My Files/deck.html',
    );
    expect(linux.fragment, 'slide-12');
    expect(
      () => resolveArtifactFileUri(
        link,
        cwd: '/',
        windows: false,
        localDistribution: 'AnotherDistribution',
      ),
      throwsFormatException,
    );
    final relative = resolveArtifactFileUri(
      'docs/guide.md#next-steps',
      cwd: '/home/example/project',
      windows: true,
      runtimeDistribution: 'Ubuntu',
    );
    expect(relative.path, '/Ubuntu/home/example/project/docs/guide.md');
    expect(relative.fragment, 'next-steps');
  });

  test(
    'bare and Markdown document links include anchors without duplicates',
    () {
      const link =
          'file://wsl.localhost/Ubuntu/home/example/deck.html#slide-12';
      final artifacts = artifactsFromText(
        '$link\n[slides]($link)\n[guide](./guide.md#table)',
      );
      expect(artifacts.map((a) => a.path), [link, './guide.md#table']);
      expect(artifacts.map((a) => a.kind), ['html', 'markdown']);
    },
  );

  test(
    'HTML is loaded intact and local links open in the document window',
    () async {
      final root = await Directory.systemTemp.createTemp('zommi-doc-test-');
      addTearDown(() => root.delete(recursive: true));
      const html =
          '<style>.grid{display:grid}</style><script>window.ready=true</script>'
          '<section id="slide-12" class="grid">Content</section>';
      final file = await File('${root.path}/deck.html').writeAsString(html);
      final link = file.uri.replace(fragment: 'slide-12').toString();
      final loaded = await const LocalArtifactLoader().load(
        ArtifactPreview(id: 'deck', kind: 'html', title: 'Deck', path: link),
      );
      expect(loaded.html, html);
      expect(loaded.fileUri?.fragment, 'slide-12');
      final desktop = FakeDesktopBridge();
      final controller = ZommiController(
        core: RichFakeCore(),
        desktop: desktop,
      );
      addTearDown(controller.close);
      await controller.openExternalLink(link);
      expect(desktop.calls, contains('document:$link'));
      expect(controller.previewArtifact, isNull);
      expect(desktop.openedUrl, isNull);
    },
  );

  test('browser origin preserves CSS/JS and relative assets but bounds file access', () async {
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = overrides);
    final root = await Directory.systemTemp.createTemp('zommi-origin-test-');
    addTearDown(() => root.delete(recursive: true));
    final documents = await Directory('${root.path}/documents').create();
    final file = await File('${documents.path}/deck.html')
        .writeAsString('unused');
    await File('${documents.path}/theme.css')
        .writeAsString('.grid{display:grid}');
    final outside = await File('${root.path}/private.json')
        .writeAsString('private');
    if (!Platform.isWindows) {
      await Link('${documents.path}/outside.json').create(outside.path);
    }
    const html =
        '<link rel="stylesheet" href="theme.css"><script>window.ready=true</script>'
        '<section id="slide-12">Styled</section>';
    final server = await DocumentServer.start(
      content: html,
      fileUri: file.uri.replace(fragment: 'slide-12'),
    );
    addTearDown(server.close);
    final client = HttpClient();
    addTearDown(client.close);
    Future<(int, String, HttpHeaders)> get(Uri uri) async {
      final response = await (await client.getUrl(uri)).close();
      return (
        response.statusCode,
        await utf8.decoder.bind(response).join(),
        response.headers,
      );
    }

    expect(server.uri.fragment, 'slide-12');
    final page = await get(server.uri);
    expect(page.$1, 200);
    expect(page.$2, html);
    expect(
      page.$3.value('content-security-policy'),
      contains("connect-src 'self'"),
    );
    final style = await get(server.uri.resolve('theme.css'));
    expect(style.$1, 200);
    expect(style.$2, '.grid{display:grid}');
    expect(style.$3.contentType?.mimeType, 'text/css');
    expect((await get(server.uri.resolve('../private.json'))).$1, 404);
    expect((await get(server.uri.resolve('.hidden'))).$1, 404);
    if (!Platform.isWindows) {
      expect((await get(server.uri.resolve('outside.json'))).$1, 404);
    }
    expect(server.allowsNavigation(server.uri.toString()), isTrue);
    expect(server.allowsNavigation('file:///tmp/private.html'), isFalse);
    expect(server.allowsNavigation('https://example.test'), isFalse);
  });

  test('Markdown renders tables, code, task lists and heading anchors', () {
    final html = markdownDocument('''# Guide

| Item | Count |
| --- | ---: |
| Example | 3 |

- [x] Complete

```dart
print("example");
```
''');
    expect(html, contains('<table>'));
    expect(html, contains('<pre><code class="language-dart">'));
    expect(html, contains('type="checkbox"'));
    expect(html, contains('scrollIntoView'));
    expect(html, contains('navigator.clipboard'));
  });

  test(
    'notification artwork gets a new URI only when its contents change',
    () async {
      final root = await Directory.systemTemp.createTemp('zommi-icon-test-');
      addTearDown(() => root.delete(recursive: true));
      final source = await File('${root.path}/app-icon.png')
          .writeAsBytes([1, 2, 3]);
      final cache = Directory('${root.path}/icons');
      final first = await prepareNotificationIcon(source, cache);
      expect(await prepareNotificationIcon(source, cache), first);
      await source.writeAsBytes([4, 5, 6]);
      final updated = await prepareNotificationIcon(source, cache);
      expect(updated, isNot(first));
      expect(await File.fromUri(first).readAsBytes(), [1, 2, 3]);
      expect(await File.fromUri(updated).readAsBytes(), [4, 5, 6]);
    },
  );
}
