import 'dart:async';
import 'dart:collection';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:focalet_flutter/desktop/document_environment.dart';
import 'package:focalet_flutter/desktop/document_server.dart';
import 'package:focalet_flutter/desktop/linux_document_renderer.dart';
import 'package:focalet_flutter/state/focalet_models.dart';

/// Renders a desktop-sized page once, then releases its browser. Chat scrolling
/// displays the resulting image instead of retaining a browser for every card.
final class DocumentThumbnailRequest {
  DocumentThumbnailRequest(this.artifact);

  final ArtifactPreview artifact;
  static final _queue =
      Queue<(DocumentThumbnailRequest, Completer<Uint8List>)>();
  static bool _running = false;
  bool _cancelled = false;
  void cancel() => _cancelled = true;

  Future<Uint8List> render() {
    final result = Completer<Uint8List>();
    _queue.add((this, result));
    _startNext();
    return result.future;
  }

  static void _startNext() {
    if (_running || _queue.isEmpty) return;
    _running = true;
    final (request, result) = _queue.removeFirst();
    unawaited(request._complete(result));
  }

  Future<void> _complete(Completer<Uint8List> result) async {
    try {
      _checkCurrent();
      result.complete(await _render());
    } on Object catch (error, stack) {
      result.completeError(error, stack);
    } finally {
      _running = false;
      _startNext();
    }
  }

  void _checkCurrent() {
    if (_cancelled) throw StateError('Preview was closed.');
  }

  Future<Uint8List> _render() async {
    if (defaultTargetPlatform == TargetPlatform.linux) {
      final server = await DocumentServer.start(
        content: artifact.html!,
        fileUri: artifact.fileUri,
        isMarkdown: artifact.kind == 'markdown',
      );
      try {
        _checkCurrent();
        return await LinuxDocumentRenderer.thumbnail(server.uri);
      } finally {
        await server.close();
      }
    }
    final environment = await documentEnvironment();
    _checkCurrent();
    final server = await DocumentServer.start(
      content: artifact.html!,
      fileUri: artifact.fileUri,
      isMarkdown: artifact.kind == 'markdown',
    );
    final loaded = Completer<InAppWebViewController>();
    // A listener is attached before run(), which can fail before the page loads.
    final ready = loaded.future.timeout(const Duration(seconds: 15));
    ready.ignore();
    void fail(String message) {
      if (!loaded.isCompleted) loaded.completeError(StateError(message));
    }

    HeadlessInAppWebView? browser;
    try {
      browser = HeadlessInAppWebView(
        initialSize: const Size(1280, 720),
        webViewEnvironment: environment,
        initialUrlRequest: URLRequest(url: WebUri(server.uri.toString())),
        initialSettings: documentBrowserSettings(),
        shouldOverrideUrlLoading: (_, action) async =>
            server.allowsNavigation(action.request.url?.toString() ?? '')
            ? NavigationActionPolicy.ALLOW
            : NavigationActionPolicy.CANCEL,
        onCreateWindow: (_, action) async => false,
        onPermissionRequest: (_, request) async => PermissionResponse(
          resources: request.resources,
          action: PermissionResponseAction.DENY,
        ),
        onLoadStop: (controller, url) {
          if (!loaded.isCompleted &&
              server.allowsNavigation(url?.toString() ?? '')) {
            loaded.complete(controller);
          }
        },
        onReceivedError: (_, request, error) {
          if (request.isForMainFrame == true) fail(error.description);
        },
        onReceivedHttpError: (_, request, response) {
          if (request.isForMainFrame == true) fail('Document unavailable.');
        },
        onRenderProcessGone: (_, detail) => fail('Document renderer stopped.'),
        onWebContentProcessDidTerminate: (_) =>
            fail('Document renderer stopped.'),
      );
      await browser.run().timeout(const Duration(seconds: 10));
      final controller = await ready;
      _checkCurrent();
      // Preserve the document's styles and scripts before taking the thumbnail.
      await controller
          .evaluateJavascript(source: 'document.fonts.ready.then(() => true)')
          .timeout(const Duration(seconds: 3));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      _checkCurrent();
      final image = await controller.takeScreenshot().timeout(
        const Duration(seconds: 5),
      );
      if (image == null || image.isEmpty) {
        throw StateError('The document renderer produced no preview.');
      }
      return image;
    } finally {
      fail('Preview was closed.');
      if (browser != null) {
        try {
          await browser.dispose().timeout(const Duration(seconds: 3));
        } on Object {
          // Closing a failed renderer must still release its document server.
        }
      }
      await server.close();
    }
  }
}
