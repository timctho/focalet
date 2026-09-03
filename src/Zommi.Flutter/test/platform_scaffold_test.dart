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
    expect(pubspec, isNot(contains('fossui:')));
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
      'skipTaskbar: false',
      'windowManager.minimize()',
      'Capture completes before Flutter is shown or focused',
      "'--capture-host'",
      'Zommi.Capture.exe',
      "_selectorClient.request('selectImage')",
      "Process.run('osascript'",
      'LinuxCaptureProvider',
      'zommi-x11-capture',
      'portal-shortcuts',
      'portal-region',
      'shouldUseWaylandPortals',
    ]) {
      expect(bridge, contains(contract));
    }
    expect(
      bridge,
      allOf(
        contains('void onTrayIconRightMouseDown()'),
        contains('trayManager.popUpContextMenu()'),
      ),
    );

    final windowsMain = File('${root.path}/windows/runner/main.cpp')
        .readAsStringSync();
    final windowsInstance = File('${root.path}/windows/runner/zommi_instance.h')
        .readAsStringSync();
    final windowsFlutterWindow = File(
      '${root.path}/windows/runner/flutter_window.cpp',
    ).readAsStringSync();
    final desktopBridge = File('${root.path}/lib/desktop/desktop_bridge.dart')
        .readAsStringSync();
    expect(
      windowsMain,
      allOf(
        contains('CreateMutexW(nullptr, TRUE, kZommiInstanceMutexName)'),
        contains('ERROR_ALREADY_EXISTS'),
        contains('PostMessageW(HWND_BROADCAST, ZommiShowWindowMessage()'),
        contains('Win32Window::Size size(720, 620)'),
      ),
    );
    expect(windowsInstance, contains('Zommi.Desktop.SingleInstance'));
    expect(
      desktopBridge,
      allOf(
        contains('await windowManager.waitUntilReadyToShow'),
        isNot(contains('unawaited(\n      windowManager.waitUntilReadyToShow')),
      ),
    );
    expect(
      windowsFlutterWindow,
      isNot(contains('SetNextFrameCallback([&]() { this->Show(); }')),
    );
    expect(
      windowsFlutterWindow,
      allOf(
        contains('message == ZommiShowWindowMessage()'),
        contains('ShowWindow(hwnd, SW_RESTORE)'),
        contains('"zommi/window_animation"'),
        contains('kWindowAnimationFrameMs'),
        contains('message == WM_TIMER'),
        allOf(
          contains('SymmetricSurfaceEase(linear)'),
          contains('WS_POPUP | WS_SYSMENU | WS_MINIMIZEBOX'),
        ),
        allOf(
          allOf(
            contains('"isPointerWithinWindow"'),
            contains('GetCursorPos(&cursor)'),
            contains('WindowFromPoint(cursor)'),
            contains('GetAncestor(hit_window, GA_ROOT)'),
          ),
          allOf(
            contains('"setBoundsWithoutCopy"'),
            contains('SetNextFrameCallback([this]()'),
            contains('flutter_controller_->ForceRedraw()'),
            contains('SWP_NOCOPYBITS'),
            allOf(
              contains('BeginSurfaceFrameTransition(current)'),
              contains('DWMWA_CLOAK'),
              contains('STM_SETIMAGE'),
              contains('SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_NOZORDER'),
            ),
          ),
        ),
      ),
    );
    expect(
      File('${root.path}/windows/runner/win32_window.cpp').readAsStringSync(),
      contains('SWP_NOACTIVATE | SWP_NOCOPYBITS | SWP_NOZORDER'),
    );
    expect(
      File('${root.path}/windows/flutter/generated_plugins.cmake')
          .readAsStringSync(),
      allOf(
        contains('hotkey_manager_windows'),
        contains('screen_capturer_windows'),
        contains('url_launcher_windows'),
        contains('window_manager'),
      ),
    );
    expect(
      File('${root.path}/linux/flutter/generated_plugins.cmake')
          .readAsStringSync(),
      allOf(
        contains('hotkey_manager_linux'),
        contains('screen_capturer_linux'),
        contains('url_launcher_linux'),
        contains('window_manager'),
      ),
    );
    expect(
      File('${root.path}/macos/Flutter/GeneratedPluginRegistrant.swift')
          .readAsStringSync(),
      allOf(
        contains('HotkeyManagerMacosPlugin'),
        contains('ScreenCapturerMacosPlugin'),
        contains('UrlLauncherPlugin'),
        contains('WindowManagerPlugin'),
      ),
    );
    final captureSource = File(
      '${root.parent.path}/Zommi.Windows/ForegroundContextCapture.cs',
    ).readAsStringSync();
    expect(
      captureSource,
      allOf(
        contains('Require actual raw-tree ancestry to the exact HWND root'),
        isNot(
          contains(
            'if (elementProcessId != 0 && elementProcessId == rootProcessId)',
          ),
        ),
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
      'windows_interactive:',
      'type: boolean',
      'runs-on: [self-hosted, Linux, X64, zommi-release]',
      'bash scripts/package-linux-self-hosted.sh',
      "ZOMMI_LINUX_STARTUP_SMOKE: '1'",
      'Native release (windows)',
      'runs-on: [self-hosted, Windows, X64, zommi-release]',
      'CMAKE_GENERATOR=Visual Studio 17 2022',
      'CMAKE_GENERATOR_INSTANCE',
      r'Git\bin\bash.exe',
      'jq-windows-amd64.exe',
      '23cb60a1354eed6bcc8d9b9735e8c7b388cd1fdcb75726b93bc299ef22dd9334',
      'Verify local Python',
      'Verify local .NET capture publisher',
      'cache: false',
      'bash scripts/package-unix.sh macos',
      'Native release (macOS, temporarily skipped)',
      r'if: ${{ false }}',
      'runs-on: [self-hosted, macOS, zommi-release]',
      './scripts/package-windows.ps1 -Runtime win-x64',
      'Accept Windows non-visual capture contracts',
      '-NonVisualOnly',
      'Accept Windows shortcuts and capture UX',
      "if: github.event_name == 'workflow_dispatch' && inputs.windows_interactive",
      'scripts/accept-windows-capture.ps1',
      'tests/test_release_package.py',
      'tests/test_linux_startup_smoke.py',
      'Accept Linux X11 shortcuts and capture UX',
      'scripts/accept-linux-x11.py',
    ]) {
      expect(workflow, contains(contract));
    }
    expect(workflow, isNot(contains('npm ')));
    expect(workflow, isNot(contains('src/Zommi.Electron')));
    expect(workflow, isNot(contains('windows-2025')));
    expect(workflow, isNot(contains('macos-15')));

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
      contains('gtk_window_set_default_size(window, 720, 620)'),
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

    final windowsPackager = File(
      '${repository.path}/scripts/package-windows.ps1',
    ).readAsStringSync();
    expect(
      windowsPackager,
      allOf(
        contains('--config-only'),
        contains('CMAKE_GENERATOR_INSTANCE'),
        contains('CMakeCache.txt'),
      ),
    );
    final windowsAcceptance = File(
      '${repository.path}/scripts/accept-windows-capture.ps1',
    ).readAsStringSync();
    expect(
      windowsAcceptance,
      allOf(
        contains('Assert-ProbeRegionSize'),
        contains('PNG dimensions'),
        contains(r'$width -ne $selected.bounds.width'),
      ),
    );

    final linuxSmoke = File('${repository.path}/scripts/smoke-linux-release.sh')
        .readAsStringSync();
    expect(linuxSmoke, contains('MissingPluginException'));
    expect(linuxSmoke, contains('rustCoreStarted'));
    expect(linuxSmoke, contains('hotkeyWarnings'));

    expect(unixPackager, contains('--linux-capture-host'));
    expect(unixPackager, contains('--bin zommi-x11-capture'));
    final linuxCapture = File(
      '${repository.path}/crates/zommi-x11-capture/src/main.rs',
    ).readAsStringSync();
    expect(
      linuxCapture,
      allOf(
        contains('GlobalShortcuts'),
        contains('AvailableTargets::Area'),
        contains('Wayland portals do not expose active-window metadata'),
      ),
    );

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
