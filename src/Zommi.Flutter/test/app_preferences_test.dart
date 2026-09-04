import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/theme/app_preferences.dart';

void main() {
  test(
    'readable message size is the default and persisted values stay valid',
    () {
      expect(const AppPreferences().chatFontSize, 13);
      expect(
        AppPreferences.fromJson(const {'chatFontSize': 2}).chatFontSize,
        12,
      );
      expect(
        AppPreferences.fromJson(const {'chatFontSize': 99}).chatFontSize,
        15,
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
      chatFontSize: 14,
      themeColor: ZommiThemeColor.ocean,
      windowSize: WindowSizeSetting.wide,
    );

    await store.save(expected);
    final restored = await store.load();

    expect(restored.chatFontSize, 14);
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
