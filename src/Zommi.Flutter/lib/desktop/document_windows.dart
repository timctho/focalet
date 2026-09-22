import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:zommi_flutter/desktop/document_server.dart';
import 'package:zommi_flutter/state/zommi_models.dart';

final class DocumentWindows {
  final Map<Webview, DocumentServer> _windows = {};
  bool _closed = false;

  Future<Webview?> open(ArtifactPreview artifact) async {
    if (_closed) return null;
    if (!await WebviewWindow.isWebviewAvailable()) {
      throw StateError(
        'Install Microsoft Edge WebView2 Runtime to preview documents.',
      );
    }
    final server = await DocumentServer.start(
      content: artifact.html!,
      fileUri: artifact.fileUri,
      isMarkdown: artifact.kind == 'markdown',
    );
    try {
      final local =
          Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
      final view = await WebviewWindow.create(
        configuration: CreateConfiguration(
          title: '${artifact.title} · Zommi',
          windowWidth: 1200,
          windowHeight: 850,
          userDataFolderWindows: '$local/Zommi/document-webview',
          titleBarTopPadding: Platform.isMacOS ? 24 : 0,
        ),
      );
      if (_closed) {
        view.close();
        await server.close();
        return null;
      }
      _windows[view] = server;
      view.setOnUrlRequestCallback(server.allowsNavigation);
      // The initial URL is created by us. Avoid the native cancel/relaunch
      // handshake while the secondary Flutter view is still starting.
      view.launch(server.uri.toString(), triggerOnUrlRequestEvent: false);
      unawaited(
        view.onClose.then((_) async {
          _windows.remove(view);
          await server.close();
        }),
      );
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (true) {
          final ready = await view
              .evaluateJavaScript(
                "document.readyState === 'complete' && "
                'location.origin === ${jsonEncode(server.uri.origin)}',
              )
              .timeout(const Duration(seconds: 5));
          if (ready == 'true') break;
          if (DateTime.now().isAfter(deadline)) {
            throw StateError('Document did not load. Close it and try again.');
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      } on Object {
        view.close();
        _windows.remove(view);
        rethrow;
      }
      await view.bringToForeground();
      return view;
    } on Object {
      await server.close();
      rethrow;
    }
  }

  Future<void> close() async {
    _closed = true;
    for (final entry in _windows.entries.toList()) {
      entry.key.close();
      await entry.value.close();
    }
    _windows.clear();
  }
}
