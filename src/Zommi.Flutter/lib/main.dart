import 'dart:async';

import 'package:flutter/material.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/diagnostics/scroll_performance.dart';
import 'package:zommi_flutter/diagnostics/macos_capture_probe.dart';
import 'package:zommi_flutter/diagnostics/document_preview_probe.dart';
import 'package:zommi_flutter/state/sqlite_session_catalog_store.dart';
import 'package:zommi_flutter/theme/app_preferences.dart';
import 'package:zommi_flutter/zommi_app.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (runWebViewTitleBarWidget(arguments)) return;
  ScrollPerformance.initialize();
  final preferencesStore = FileAppPreferencesStore.platform();
  final preferences = await preferencesStore.load();
  final desktop = await FlutterDesktopBridge.bootstrap(
    selectionShortcut: preferences.selectionShortcut,
    windowSize: preferences.windowSize,
  );
  runApp(
    ZommiApp(
      core: ProcessCoreBridge(),
      desktop: desktop,
      initialPreferences: preferences,
      preferencesStore: preferencesStore,
      sessionCatalogStore: SqliteSessionCatalogStore.platform(),
      catalogStartupDelay: const Duration(seconds: 5),
    ),
  );
  unawaited(runMacCaptureProbe());
  unawaited(runDocumentPreviewProbe(desktop));
}
