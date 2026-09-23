import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

Future<WebViewEnvironment>? _windowsEnvironment;

Future<WebViewEnvironment?> documentEnvironment() async {
  if (InAppWebViewPlatform.instance == null) {
    throw StateError('Document renderer unavailable. Restart Zommi and retry.');
  }
  if (defaultTargetPlatform != TargetPlatform.windows) return null;
  if (await WebViewEnvironment.getAvailableVersion() == null) {
    throw StateError(
      'Install Microsoft Edge WebView2 Runtime to preview documents.',
    );
  }
  final local =
      Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
  try {
    return await (_windowsEnvironment ??= WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: '$local/Zommi/document-webview',
      ),
    )).timeout(const Duration(seconds: 15));
  } on Object {
    _windowsEnvironment = null;
    rethrow;
  }
}

InAppWebViewSettings documentBrowserSettings() => InAppWebViewSettings(
  javaScriptEnabled: true,
  javaScriptBridgeEnabled: false,
  useShouldOverrideUrlLoading: true,
  supportMultipleWindows: false,
  allowFileAccess: false,
  allowContentAccess: false,
  disableContextMenu: true,
);
