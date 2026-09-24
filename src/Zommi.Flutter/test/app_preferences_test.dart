import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'test_support.dart';

import 'package:zommi_flutter/theme/app_preferences.dart';

void main() {
  testWidgets('first launch and settings persist runtime launch permissions', (
    tester,
  ) async {
    final store = _PermissionPreferencesStore();
    final core = RichFakeCore();
    await tester.pumpWidget(
      ZommiApp(
        core: core,
        preferencesStore: store,
        initialPreferences: const AppPreferences(runtimeSetupCompleted: false),
      ),
    );
    await tester.pumpAndSettle();
    expect(core.fullAccessRuntimes, isFalse);
    expect(AppPreferences.fromJson(const {}).fullAccessRuntimes, isFalse);
    await tester.tap(find.byKey(const ValueKey('runtime-full-access')));
    await tester.pumpAndSettle();
    expect(core.fullAccessRuntimes, isTrue);
    final saved = await store.load();
    expect(saved.fullAccessRuntimes, isTrue);
    await tester.pumpWidget(const SizedBox());
    final restarted = RichFakeCore();
    await tester.pumpWidget(
      ZommiApp(
        core: restarted,
        preferencesStore: store,
        initialPreferences: saved.copyWith(runtimeSetupCompleted: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(restarted.fullAccessRuntimes, isTrue);
    await tester.tap(find.byKey(const ValueKey('app-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('runtime-full-access')));
    await tester.pumpAndSettle();
    expect(restarted.fullAccessRuntimes, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'full webpage capture can be disabled and restored without changing other preferences',
    (tester) async {
      final desktop = FakeDesktopBridge()..supportsBrowserPageDetails = true;
      await tester.pumpWidget(
        ZommiApp(
          core: RichFakeCore(),
          desktop: desktop,
          initialPreferences: const AppPreferences(browserPageDetails: false),
        ),
      );
      await tester.pumpAndSettle();
      expect(desktop.browserPageDetails, isFalse);
      await tester.tap(find.byKey(const ValueKey('app-settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('browser-page-details')));
      await tester.pumpAndSettle();
      expect(desktop.browserPageDetails, isTrue);
      await tester.tap(find.byKey(const ValueKey('browser-page-details')));
      await tester.pumpAndSettle();
      expect(desktop.browserPageDetails, isFalse);
      expect(AppPreferences.fromJson(const {}).browserPageDetails, isTrue);
      expect(
        AppPreferences.fromJson(
          const AppPreferences(browserPageDetails: false).toJson(),
        ).browserPageDetails,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'readable message size is the default and persisted values stay valid',
    () {
      expect(const AppPreferences().chatFontSize, 14);
      expect(AppPreferences.fromJson(const {}).chatFontSize, 14);
      expect(
        AppPreferences.fromJson(const {'chatFontSize': 13}).chatFontSize,
        14,
      );
      expect(
        AppPreferences.fromJson(const {'chatFontSize': 2}).chatFontSize,
        12,
      );
      expect(
        AppPreferences.fromJson(const {'chatFontSize': 99}).chatFontSize,
        17,
      );
    },
  );

  test('app appearance preferences round trip locally', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zommi-app-preferences-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final store = FileAppPreferencesStore('${directory.path}/settings.json');
    const expected = AppPreferences(
      fullAccessRuntimes: true,
      chatFontSize: 17,
      themeColor: ZommiThemeColor.ocean,
      windowSize: WindowSizeSetting.wide,
    );

    await store.save(expected);
    final restored = await store.load();

    expect(restored.fullAccessRuntimes, isTrue);
    expect(restored.chatFontSize, 17);
    expect(restored.themeColor, ZommiThemeColor.ocean);
    expect(restored.windowSize, WindowSizeSetting.wide);
  });

  test('app preference paths follow each desktop convention', () {
    expect(
      defaultAppPreferencesPath(
        operatingSystem: 'windows',
        environment: const {'APPDATA': r'C:\Users\example\AppData\Roaming'},
      ),
      r'C:\Users\example\AppData\Roaming\Zommi\settings.json',
    );
    expect(
      defaultAppPreferencesPath(
        operatingSystem: 'linux',
        environment: const {'XDG_CONFIG_HOME': '/tmp/config'},
      ),
      '/tmp/config/zommi/settings.json',
    );
  });
}

class _PermissionPreferencesStore implements AppPreferencesStore {
  AppPreferences saved = const AppPreferences();
  @override
  Future<AppPreferences> load() async =>
      AppPreferences.fromJson(saved.toJson());
  @override
  Future<void> save(AppPreferences preferences) async {
    saved = preferences;
  }
}
