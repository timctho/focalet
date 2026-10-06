import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:focalet_flutter/theme/app_preferences.dart';
import 'package:focalet_flutter/focalet_app.dart';

import 'test_support.dart';

class _PreferencesStore implements AppPreferencesStore {
  AppPreferences saved = const AppPreferences();
  @override
  Future<AppPreferences> load() async => saved;
  @override
  Future<void> save(AppPreferences preferences) async {
    saved = preferences;
  }
}

void main() {
  test(
    'appearance migration, defaults and custom colors survive serialization',
    () {
      expect(const AppPreferences().themeColor, FocaletThemeColor.ocean);
      expect(AppPreferences.fromJson({}).themeMode, ThemeMode.system);
      final custom = const AppPreferences(
        themeColor: FocaletThemeColor.custom,
        customThemeColor: Color(0xff39bba0),
        themeMode: ThemeMode.dark,
      );
      expect(AppPreferences.fromJson(custom.toJson()), custom);
      final legacy = AppPreferences.fromJson({'themeColor': 'forest'});
      expect(legacy.seedColor, const Color(0xff468267));
      expect(
        AppPreferences.fromJson({
          'themeColor': 'unknown',
          'themeMode': 'unknown',
          'customThemeColor': 'bad',
        }).themeColor,
        FocaletThemeColor.ocean,
      );
    },
  );

  testWidgets(
    'system and explicit themes update all surfaces; palette applies and cancels',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      if (Platform.environment['FOCALET_THEME_PREVIEW_FONT']
          case final String fontPath) {
        await tester.runAsync(() async {
          final loader = FontLoader(codexUiFontFamily)
            ..addFont(
              File(fontPath)
                  .readAsBytes()
                  .then((bytes) => ByteData.sublistView(bytes)),
            );
          await loader.load();
          final icons = Platform.environment['FOCALET_THEME_PREVIEW_ICONS'];
          if (icons != null) {
            await (FontLoader('MaterialIcons')..addFont(
                  File(icons)
                      .readAsBytes()
                      .then((bytes) => ByteData.sublistView(bytes)),
                ))
                .load();
          }
        });
      }
      final store = _PreferencesStore();
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: FocaletApp(
            core: RichFakeCore()..historyCount = 2,
            desktop: FakeDesktopBridge(),
            preferencesStore: store,
          ),
        ),
      );
      await tester.pumpAndSettle();
      ThemeData theme() => Theme.of(tester.element(find.byType(FocaletShell)));
      Color sidebarColor() => tester
          .widget<Material>(find.byKey(const ValueKey('session-sidebar')))
          .color!;
      final oceanLightSidebar = sidebarColor();
      expect(theme().brightness, Brightness.light);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(theme().brightness, Brightness.dark);
      final oceanDarkSidebar = sidebarColor();
      final editable = tester.widget<EditableText>(
        find.byType(EditableText).first,
      );
      expect(editable.style.color!.computeLuminance(), greaterThan(.5));
      expect(theme().colorScheme.surface.computeLuminance(), lessThan(.1));
      await tester.tap(find.byKey(const ValueKey('app-settings')));
      await tester.pumpAndSettle();
      Future<void> capturePreview(String name) async {
        if (!Platform.environment.containsKey('FOCALET_THEME_PREVIEW_DIR')) {
          return;
        }
        await tester.runAsync(() async {
          final boundary =
              capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final snapshot = await boundary.toImage(pixelRatio: 1.5);
          final bytes = await snapshot.toByteData(
            format: ui.ImageByteFormat.png,
          );
          final file = File(
            '${Platform.environment['FOCALET_THEME_PREVIEW_DIR']}/$name.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          snapshot.dispose();
        });
      }

      await capturePreview('dark');
      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();
      expect(theme().brightness, Brightness.light);
      expect(store.saved.themeMode, ThemeMode.light);
      await capturePreview('light');
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('theme-color-ocean'))).dx,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('theme-color-mist'))).dx,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('theme-color-cream')));
      await tester.pumpAndSettle();
      expect(store.saved.themeColor, FocaletThemeColor.cream);
      final creamSidebar = sidebarColor();
      expect(creamSidebar, isNot(oceanLightSidebar));
      await tester.tap(find.byKey(const ValueKey('theme-color-custom')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('theme-color-picker')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('color-hex')), '1EA37B');
      await tester.pumpAndSettle();
      await capturePreview('palette');
      await tester.tap(find.byKey(const ValueKey('apply-custom-color')));
      await tester.pumpAndSettle();
      expect(store.saved.customThemeColor, const Color(0xff1ea37b));
      expect(store.saved.themeColor, FocaletThemeColor.custom);
      final customLightSidebar = sidebarColor();
      expect(customLightSidebar, isNot(creamSidebar));
      expect(
        customLightSidebar.computeLuminance(),
        lessThan(theme().colorScheme.surface.computeLuminance()),
      );
      await tester.tap(find.byKey(const ValueKey('theme-color-custom')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('color-hex')), 'FF0000');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(store.saved.customThemeColor, const Color(0xff1ea37b));
      expect(sidebarColor(), customLightSidebar);
      await tester.tap(find.text('System'));
      await tester.pumpAndSettle();
      expect(theme().brightness, Brightness.dark);
      expect(sidebarColor(), isNot(oceanDarkSidebar));
      expect(
        sidebarColor().computeLuminance(),
        lessThan(theme().colorScheme.surface.computeLuminance()),
      );
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(theme().brightness, Brightness.light);
      await tester.tap(find.byKey(const ValueKey('app-settings')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('session-runtime-codex-session-1')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      for (final action in ['pin', 'rename', 'copy', 'duplicate', 'delete']) {
        expect(find.byKey(ValueKey('session-action-$action')), findsOneWidget);
      }
      await capturePreview('session-menu');
      await tester.tap(find.byKey(const ValueKey('session-action-pin')));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.push_pin_rounded), findsOneWidget);
      if (Platform.environment.containsKey('FOCALET_THEME_PREVIEW_DIR')) {
        await tester.tap(find.byKey(const ValueKey('app-settings')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('theme-color-ocean')));
        await tester.tap(find.byKey(const ValueKey('app-settings')));
        await tester.pumpAndSettle();
        final composer = find.byKey(const ValueKey('focalet-composer'));
        await tester.enterText(composer, 'Check the implementation');
        await tester.tap(find.byKey(const ValueKey('send-message')));
        await tester.pump();
        await tester.enterText(composer, 'Review the tests once this finishes');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await tester.enterText(
          composer,
          'Summarize the results and remaining risks',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump(const Duration(milliseconds: 300));
        await capturePreview('queue-light');
        tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        await tester.pump();
        for (var frame = 0; frame < 8; frame++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(theme().brightness, Brightness.dark);
        await capturePreview('queue-dark');
      }
      expect(tester.takeException(), isNull);
    },
  );
}
