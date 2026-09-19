import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/desktop/capture_shortcut.dart';
import 'package:zommi_flutter/theme/app_preferences.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'test_support.dart';

class ShortcutDesktop extends FakeDesktopBridge
    implements CaptureShortcutSettings {
  CaptureShortcut shortcut = CaptureShortcut.standard;
  bool suspended = false;
  bool reject = false;
  @override
  bool get canCustomizeSelectionShortcut => true;
  @override
  Future<void> configureSelectionShortcut(CaptureShortcut value) async {
    if (reject) throw StateError('Already registered');
    shortcut = value;
    suspended = false;
  }

  @override
  Future<void> suspendSelectionShortcut() async {
    suspended = true;
  }

  @override
  Future<void> resumeSelectionShortcut() async {
    suspended = false;
  }
}

class ShortcutPreferences implements AppPreferencesStore {
  AppPreferences value = const AppPreferences();
  @override
  Future<AppPreferences> load() async => value;
  @override
  Future<void> save(AppPreferences next) async {
    value = next;
  }
}

void main() {
  test(
    'shortcut preferences round trip and reject malformed/unmodified keys',
    () {
      const shortcut = CaptureShortcut(usage: 0x70016, modifiers: 5);
      final settings = AppPreferences(selectionShortcut: shortcut);
      expect(AppPreferences.fromJson(settings.toJson()), settings);
      expect(shortcut.label, 'Alt+Shift+S');
      expect(
        CaptureShortcut.fromJson({'usage': 0x70004, 'modifiers': 4}),
        CaptureShortcut.standard,
      );
      expect(
        CaptureShortcut.fromJson({'usage': 0, 'modifiers': 1}),
        CaptureShortcut.standard,
      );
      expect(
        AppPreferences.fromJson({}).selectionShortcut,
        CaptureShortcut.standard,
      );
    },
  );

  testWidgets(
    'recording a shortcut updates registration, preferences and Select tooltip',
    (tester) async {
      final desktop = ShortcutDesktop();
      final preferences = ShortcutPreferences();
      await tester.pumpWidget(
        ZommiApp(
          core: RichFakeCore()..historyCount = 0,
          desktop: desktop,
          preferencesStore: preferences,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('app-settings')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('selection-shortcut-setting')),
      );
      await tester.pumpAndSettle();
      expect(desktop.suspended, isTrue);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(find.text('Alt+Shift+S'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(desktop.suspended, isFalse);
      expect(desktop.shortcut.label, 'Alt+Shift+S');
      expect(preferences.value.selectionShortcut, desktop.shortcut);
      await tester.tap(find.byKey(const ValueKey('app-settings')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('select-content')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Select content (Alt+Shift+S)'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'shortcut conflict retains the dialog and cancel restores the previous key',
    (tester) async {
      final desktop = ShortcutDesktop()..reject = true;
      final preferences = ShortcutPreferences();
      await tester.pumpWidget(
        ZommiApp(
          core: RichFakeCore()..historyCount = 0,
          desktop: desktop,
          preferencesStore: preferences,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('app-settings')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('selection-shortcut-setting')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('That shortcut is unavailable'),
        findsOneWidget,
      );
      expect(desktop.suspended, isTrue);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(desktop.suspended, isFalse);
      expect(preferences.value.selectionShortcut, CaptureShortcut.standard);
    },
  );
}
