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
      'Zommi.Capture.exe',
      "_selectorClient.request('selectImage')",
      "Process.run('osascript'",
      'LinuxCaptureProvider',
      'zommi-x11-capture',
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

  test('release cutover packages Flutter and Rust without Electron', () {
    final repository = Directory.current.parent.parent;
    bool hasFiles(String path) {
      final directory = Directory(path);
      return directory.existsSync() &&
          directory.listSync(recursive: true).whereType<File>().isNotEmpty;
    }

    expect(hasFiles('${repository.path}/src/Zommi.Electron'), isFalse);
    expect(hasFiles('${repository.path}/src/Zommi.Hook'), isFalse);
    final workflow = File('${repository.path}/.github/workflows/ci.yml')
        .readAsStringSync();
    for (final contract in [
      'Native release (linux)',
      'runs-on: [self-hosted, Linux, X64, zommi-release]',
      'bash scripts/package-linux-self-hosted.sh',
      "ZOMMI_LINUX_STARTUP_SMOKE: '1'",
      r'Native release (${{ matrix.target }})',
      'bash scripts/package-unix.sh macos',
      './scripts/package-windows.ps1 -Runtime win-x64',
      'tests/test_release_package.py',
      'tests/test_linux_startup_smoke.py',
      'Accept Linux X11 shortcuts and capture UX',
      'scripts/accept-linux-x11.py',
    ]) {
      expect(workflow, contains(contract));
    }
    expect(workflow, isNot(contains('npm ')));
    expect(workflow, isNot(contains('src/Zommi.Electron')));

    final verifier = File('${repository.path}/scripts/verify_release.py')
        .readAsStringSync();
    expect(verifier, contains('Legacy Electron/Node payload found'));
    expect(verifier, contains('Rust core initialize smoke did not succeed'));

    final linuxPackager = File(
      '${repository.path}/scripts/package-linux-self-hosted.sh',
    ).readAsStringSync();
    expect(linuxPackager, contains('Ubuntu 20.04 only'));
    expect(linuxPackager, contains('PKG_CONFIG_SYSROOT_DIR'));
    expect(linuxPackager, contains('ZOMMI_LINUX_RUNTIME_LIBRARY_DIRS'));

    final unixPackager = File('${repository.path}/scripts/package-unix.sh')
        .readAsStringSync();
    expect(
      unixPackager,
      allOf(
        contains('bundle_linux_runtime_libraries'),
        contains('libayatana-appindicator3.so.1'),
      ),
    );
    expect(
      File('${repository.path}/src/Zommi.Flutter/linux/CMakeLists.txt')
          .readAsStringSync(),
      contains('CMAKE_BUILD_RPATH_USE_ORIGIN TRUE'),
    );
    expect(
      File(
        '${repository.path}/src/Zommi.Flutter/linux/runner/my_application.cc',
      ).readAsStringSync(),
      contains('gtk_window_set_default_size(window, 56, 56)'),
    );
    final hotkeyPlugin = File(
      '${repository.path}/third_party/hotkey_manager_linux/linux/'
      'hotkey_manager_linux_plugin.cc',
    ).readAsStringSync();
    expect(
      hotkeyPlugin,
      allOf(
        contains('XGrabKey'),
        contains('GDK_IS_X11_DISPLAY'),
        contains('registration.modifiers == modifiers'),
      ),
    );
    expect(linuxPackager, contains('scripts/package-unix.sh'));

    final linuxSmoke = File('${repository.path}/scripts/smoke-linux-release.sh')
        .readAsStringSync();
    expect(linuxSmoke, contains('MissingPluginException'));
    expect(linuxSmoke, contains('rustCoreStarted'));
    expect(linuxSmoke, contains('hotkeyWarnings'));

    expect(unixPackager, contains('--linux-capture-host'));
    expect(unixPackager, contains('--bin zommi-x11-capture'));

    final linuxAcceptance = File(
      '${repository.path}/scripts/accept-linux-x11.py',
    ).readAsStringSync();
    expect(
      linuxAcceptance,
      allOf(
        contains('XTestFakeKeyEvent'),
        contains('shortcut.image.cancelled'),
        contains('ZOMMI_X11_CONTEXT_FIXTURE'),
        contains('pointerContextPaired'),
      ),
    );
  });
}
