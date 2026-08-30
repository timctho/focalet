import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop runners target Windows, Linux, and macOS as Zommi', () {
    final root = Directory.current;
    expect(Directory('${root.path}/windows/runner').existsSync(), isTrue);
    expect(Directory('${root.path}/linux/runner').existsSync(), isTrue);
    expect(Directory('${root.path}/macos/Runner').existsSync(), isTrue);

    expect(
      File('${root.path}/windows/CMakeLists.txt').readAsStringSync(),
      contains('set(BINARY_NAME "Zommi")'),
    );
    expect(
      File('${root.path}/linux/CMakeLists.txt').readAsStringSync(),
      allOf(
        contains('set(BINARY_NAME "zommi")'),
        contains('set(APPLICATION_ID "com.zommi.desktop")'),
      ),
    );
    expect(
      File('${root.path}/macos/Runner/Configs/AppInfo.xcconfig')
          .readAsStringSync(),
      allOf(
        contains('PRODUCT_NAME = Zommi'),
        contains('PRODUCT_BUNDLE_IDENTIFIER = com.zommi.desktop'),
      ),
    );
  });

  test('desktop shell registers cross-platform window, shortcut, tray, and capture plugins', () {
    final root = Directory.current;
    final pubspec = File('${root.path}/pubspec.yaml').readAsStringSync();
    for (final dependency in [
      'window_manager:',
      'hotkey_manager:',
      'screen_retriever:',
      'screen_capturer:',
      'tray_manager:',
    ]) {
      expect(pubspec, contains(dependency));
    }
    final main = File('${root.path}/lib/main.dart').readAsStringSync();
    expect(main, contains('FlutterDesktopBridge.bootstrap()'));
    final bridge = File('${root.path}/lib/desktop/desktop_bridge.dart')
        .readAsStringSync();
    for (final contract in [
      'HotKeyModifier.alt',
      'CaptureMode.region',
      'setAlwaysOnTop(true)',
      'Capture completes before Flutter is shown or focused',
      "'--capture-host'",
      "_selectorClient.request('selectImage')",
      "Process.run('osascript'",
      "_runText('xdotool'",
    ]) {
      expect(bridge, contains(contract));
    }
    expect(
      File('${root.path}/windows/flutter/generated_plugins.cmake')
          .readAsStringSync(),
      allOf(
        contains('hotkey_manager_windows'),
        contains('screen_capturer_windows'),
        contains('window_manager'),
      ),
    );
    expect(
      File('${root.path}/linux/flutter/generated_plugins.cmake')
          .readAsStringSync(),
      allOf(
        contains('hotkey_manager_linux'),
        contains('screen_capturer_linux'),
        contains('window_manager'),
      ),
    );
    expect(
      File('${root.path}/macos/Flutter/GeneratedPluginRegistrant.swift')
          .readAsStringSync(),
      allOf(
        contains('HotkeyManagerMacosPlugin'),
        contains('ScreenCapturerMacosPlugin'),
        contains('WindowManagerPlugin'),
      ),
    );
  });

  test(
    'macOS non-App-Store build declares explicit local capture authority',
    () {
      final root = Directory.current;
      for (final name in [
        'DebugProfile.entitlements',
        'Release.entitlements',
      ]) {
        expect(
          File('${root.path}/macos/Runner/$name').readAsStringSync(),
          contains('<key>com.apple.security.app-sandbox</key>\n\t<false/>'),
        );
      }
      expect(
        File('${root.path}/macos/Runner/Info.plist').readAsStringSync(),
        allOf(
          contains('NSAppleEventsUsageDescription'),
          contains('NSScreenCaptureUsageDescription'),
        ),
      );
    },
  );
}
