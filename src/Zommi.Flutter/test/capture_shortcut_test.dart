import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/desktop/capture_shortcut.dart';
import 'package:zommi_flutter/theme/app_preferences.dart';
import 'package:zommi_flutter/widgets/capture_shortcut_setting.dart';
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
  test('Mac modifier glyphs leave portable shortcut bindings unchanged', () {
    const shortcut = CaptureShortcut(usage: 0x70016, modifiers: 15);
    expect(
      CaptureShortcut.standard.labelForPlatform(TargetPlatform.macOS),
      '⌥ A',
    );
    expect(shortcut.labelForPlatform(TargetPlatform.macOS), '⌃ ⌥ ⇧ ⌘ S');
    for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
      expect(shortcut.labelForPlatform(platform), 'Ctrl+Alt+Shift+Meta+S');
    }
    expect(shortcut.toJson(), {'usage': 0x70016, 'modifiers': 15});
    expect(shortcut.toHotKey().key, PhysicalKeyboardKey.keyS);
    expect(shortcut.toHotKey().modifiers, hasLength(4));
  });

  testWidgets('Mac shortcut settings and reset use native key names', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CaptureShortcutSetting(
            settings: ShortcutDesktop(),
            value: CaptureShortcut.standard,
            onChanged: (_) {},
          ),
        ),
      ),
    );
    expect(find.text('⌥ A'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('selection-shortcut-setting')));
    await tester.pumpAndSettle();
    expect(find.text('Reset to ⌥ A'), findsOneWidget);
    expect(find.textContaining('Option (⌥)'), findsOneWidget);
    expect(find.textContaining('Alt'), findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(find.text('⌘ S'), findsOneWidget);
    await tester.tap(find.text('Reset to ⌥ A'));
    await tester.pump();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('shortcut-recording')))
          .data,
      '⌥ A',
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

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
