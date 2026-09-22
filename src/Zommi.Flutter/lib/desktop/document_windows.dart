import 'dart:async';
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
      view.launch(server.uri.toString());
      unawaited(
        view.onClose.then((_) async {
          _windows.remove(view);
          await server.close();
        }),
      );
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
