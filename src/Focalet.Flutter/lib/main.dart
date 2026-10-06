import 'dart:async';

import 'package:flutter/material.dart';
import 'package:focalet_flutter/core/core_bridge.dart';
import 'package:focalet_flutter/desktop/desktop_bridge.dart';
import 'package:focalet_flutter/diagnostics/scroll_performance.dart';
import 'package:focalet_flutter/diagnostics/macos_capture_probe.dart';
import 'package:focalet_flutter/state/sqlite_session_catalog_store.dart';
import 'package:focalet_flutter/theme/app_preferences.dart';
import 'package:focalet_flutter/focalet_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ScrollPerformance.initialize();
  final preferencesStore = FileAppPreferencesStore.platform();
  final preferences = await preferencesStore.load();
  final desktop = await FlutterDesktopBridge.bootstrap(
    selectionShortcut: preferences.selectionShortcut,
    windowSize: preferences.windowSize,
  );
  runApp(
    FocaletApp(
      core: ProcessCoreBridge(),
      desktop: desktop,
      initialPreferences: preferences,
      preferencesStore: preferencesStore,
      sessionCatalogStore: SqliteSessionCatalogStore.platform(),
      catalogStartupDelay: const Duration(seconds: 5),
    ),
  );
  unawaited(runMacCaptureProbe());
}
