import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/theme/app_preferences.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'test_support.dart';

class _Store implements AppPreferencesStore {
  AppPreferences value = const AppPreferences(runtimeSetupCompleted: false);
  bool fail = false;
  int saves = 0;

  @override
  Future<AppPreferences> load() async => value;
  @override
  Future<void> save(AppPreferences preferences) async {
    saves++;
    if (fail) throw const FileSystemException('read only');
    value = preferences;
  }
}

void main() {
  test('fresh, interrupted and unreadable installs need setup; legacy settings skip', () async {
    final directory = await Directory.systemTemp.createTemp('zommi-first-run-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/settings.json');
    final store = FileAppPreferencesStore(file.path);
    expect((await store.load()).runtimeSetupCompleted, isFalse);
    await store.save(const AppPreferences(runtimeSetupCompleted: false));
    expect((await store.load()).runtimeSetupCompleted, isFalse);
    await store.save(const AppPreferences(runtimeSetupCompleted: true));
    expect((await store.load()).runtimeSetupCompleted, isTrue);
    await file.writeAsString('{"themeMode":"dark"}');
    expect((await store.load()).runtimeSetupCompleted, isTrue);
    await file.writeAsString('{"runtimeSetupCompleted":"invalid"}');
    expect((await store.load()).runtimeSetupCompleted, isFalse);
    await file.writeAsString('{broken');
    expect((await store.load()).runtimeSetupCompleted, isFalse);
  });

  Future<void> launch(
    WidgetTester tester,
    RichFakeCore core,
    _Store store,
    FakeDesktopBridge desktop,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ZommiApp(
        core: core,
        desktop: desktop,
        initialPreferences: await store.load(),
        preferencesStore: store,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> press(WidgetTester tester, String key) async {
    final button = find.byKey(ValueKey(key));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  for (final (id, adapter, code, label, call) in [
    (
      'claude',
      'claude-stream-json',
      'runtime-update-required',
      'Update Claude Code',
      'update',
    ),
    (
      'openclaw',
      'openclaw-acp',
      'gateway-unavailable',
      'Open OpenClaw setup',
      'signIn',
    ),
  ]) {
    testWidgets(
      '$id startup offers runtime setup and then connects without restarting the app',
      (tester) async {
        final target = RuntimeTarget(
          id: 'runtime-$id',
          runtimeId: id,
          adapterId: adapter,
          displayName: id,
          protocolName: 'fixture',
          executablePath: '/usr/bin/$id',
          executionHost: const {'kind': 'wsl', 'name': 'Ubuntu'},
          capabilityHints: RichFakeCore.capabilities,
        );
        final core = RichFakeCore()
          ..discoveredTargets.clear()
          ..discoveredTargets.add(target)
          ..connectErrorCode = code
          ..connectErrorMessage = 'Complete runtime setup, then retry.';
        final desktop = FakeDesktopBridge();
        final store = _Store();
        await launch(tester, core, store, desktop);
        await press(tester, 'setup-continue');
        expect(store.saves, 0);
        expect(find.text(label), findsWidgets);
        await press(tester, 'setup-runtime-recovery');
        expect(desktop.calls, contains('$call:${target.id}'));
        expect(core.connectCount, 1);
        core.connectErrorCode = null;
        await press(tester, 'setup-continue');
        expect(store.value.runtimeSetupCompleted, isTrue);
        expect(core.activeTargetId, target.id);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'cancelled setup unlocks controls and ignores the late connection',
    (tester) async {
      final core = RichFakeCore();
      final store = _Store();
      await launch(tester, core, store, FakeDesktopBridge());
      final gate = Completer<void>();
      core.connectGate = gate.future;
      await tester.tap(find.byKey(const ValueKey('setup-continue')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('setup-cancel-connection')));
      await tester.pump();
      final skip = tester.widget<TextButton>(
        find.byKey(const ValueKey('setup-skip')),
      );
      expect(skip.onPressed, isNotNull);
      gate.complete();
      await tester.pumpAndSettle();
      expect(store.saves, 0);
      expect(find.text('Welcome to Zommi'), findsOneWidget);
    },
  );

  testWidgets(
    'detects without connecting, then connects the chosen runtime and remembers completion',
    (tester) async {
      final core = RichFakeCore();
      final store = _Store();
      await launch(tester, core, store, FakeDesktopBridge());
      expect(find.text('Welcome to Zommi'), findsOneWidget);
      expect(core.connectCount, 0);
      expect(core.createdSessions, isEmpty);
      expect(core.catalogRequests, isEmpty);
      await press(tester, 'setup-runtime-runtime-pi');
      await press(tester, 'setup-continue');
      expect(core.activeTargetId, 'runtime-pi');
      expect(core.connectCount, 1);
      expect(store.value.runtimeSetupCompleted, isTrue);
      expect(find.byKey(const ValueKey('first-run-setup')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await launch(tester, RichFakeCore(), store, FakeDesktopBridge());
      expect(find.text('Welcome to Zommi'), findsNothing);
    },
  );

  testWidgets(
    'empty discovery can rescan and configure without connecting; explicit skip works',
    (tester) async {
      final core = RichFakeCore()..discoveredTargets.clear();
      final store = _Store();
      final desktop = FakeDesktopBridge();
      await launch(tester, core, store, desktop);
      expect(find.textContaining('No agents found.'), findsOneWidget);
      await press(tester, 'setup-configure');
      expect(find.text('Advanced agent runtime'), findsOneWidget);
      await press(tester, 'close-runtime-setup');
      core.discoveredTargets.add(RichFakeCore.targets.first);
      await press(tester, 'setup-rescan');
      expect(core.lastDiscoveryForce, isTrue);
      expect(core.connectCount, 0);
      expect(
        find.byKey(const ValueKey('setup-runtime-runtime-codex')),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Welcome to Zommi'), findsOneWidget);
      expect(desktop.calls, isNot(contains('hide')));
      await press(tester, 'setup-skip');
      expect(store.value.runtimeSetupCompleted, isTrue);
      expect(core.connectCount, 0);
    },
  );

  testWidgets(
    'Add runtime detects once, returns to setup and selects each added CLI',
    (tester) async {
      final core = RichFakeCore()..discoveredTargets.clear();
      final store = _Store();
      await launch(tester, core, store, FakeDesktopBridge());
      for (final path in ['/home/agent/bin/codex', '/home/agent/other/codex']) {
        await press(tester, 'setup-configure');
        await press(tester, 'runtime-setup-host-wsl:ubuntu');
        final field = find.byKey(
          const ValueKey('runtime-wsl-path-codex-app-server-wsl:ubuntu'),
        );
        await tester.ensureVisible(field);
        await tester.enterText(field, path);
        await tester.pump();
        final gate = Completer<void>();
        core.addOverrideGate = gate.future;
        final before = core.configuredOverrides.length;
        final add = find.byKey(const ValueKey('save-runtime-override'));
        await tester.ensureVisible(add);
        await tester.tap(add);
        await tester.pump();
        expect(find.text('Detecting…'), findsOneWidget);
        expect(tester.widget<FilledButton>(add).onPressed, isNull);
        expect(core.configuredOverrides.length, before);
        gate.complete();
        await tester.pumpAndSettle();
        expect(core.configuredOverrides.length, before + 1);
        expect(core.configuredOverrides.last['executablePath'], path);
        expect(find.byKey(const ValueKey('runtime-setup-panel')), findsNothing);
        expect(find.text('Welcome to Zommi'), findsOneWidget);
        final choice = find.byKey(
          ValueKey('setup-runtime-runtime-added-$before'),
        );
        final group = tester.widget<RadioGroup<String>>(
          find.ancestor(of: choice, matching: find.byType(RadioGroup<String>)),
        );
        expect(group.groupValue, 'runtime-added-$before');
        expect(core.connectCount, 0);
        expect(store.saves, 0);
      }
      await press(tester, 'setup-continue');
      expect(core.activeTargetId, core.discoveredTargets.last.id);
      expect(store.value.runtimeSetupCompleted, isTrue);
    },
  );

  testWidgets('failed runtime detection keeps the path and supports retry', (
    tester,
  ) async {
    final core = RichFakeCore()
      ..discoveredTargets.clear()
      ..addOverrideFails = true;
    final store = _Store();
    await launch(
      tester,
      core,
      store,
      FakeDesktopBridge()..nextRuntimeExecutable = '/custom/codex',
    );
    await press(tester, 'setup-configure');
    await press(tester, 'select-runtime-executable');
    await press(tester, 'save-runtime-override');
    expect(find.byKey(const ValueKey('runtime-setup-panel')), findsOneWidget);
    expect(find.text('/custom/codex'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('runtime-setup-error')))
          .data,
      contains('CLI executable was not found.'),
    );
    expect(core.connectCount, 0);
    core.addOverrideFails = false;
    await press(tester, 'save-runtime-override');
    expect(find.byKey(const ValueKey('runtime-setup-panel')), findsNothing);
    expect(
      find.byKey(const ValueKey('setup-runtime-runtime-added-1')),
      findsOneWidget,
    );
  });

  testWidgets(
    'authentication failure offers runtime sign-in and allows retry',
    (tester) async {
      final core = RichFakeCore()..connectErrorCode = 'authentication-required';
      final store = _Store();
      final desktop = FakeDesktopBridge();
      await launch(tester, core, store, desktop);
      await press(tester, 'setup-continue');
      expect(store.saves, 0);
      expect(find.text('Sign in needed'), findsOneWidget);
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(desktop.calls, contains('signIn:runtime-codex'));
      core.connectErrorCode = null;
      await press(tester, 'setup-continue');
      expect(store.value.runtimeSetupCompleted, isTrue);
    },
  );

  testWidgets(
    'failed completion save keeps setup open; retry reuses the connected session',
    (tester) async {
      final core = RichFakeCore();
      final store = _Store()..fail = true;
      await launch(tester, core, store, FakeDesktopBridge());
      await press(tester, 'setup-continue');
      expect(
        find.text('Could not save setup. Please try again.'),
        findsOneWidget,
      );
      expect(store.value.runtimeSetupCompleted, isFalse);
      expect(core.connectCount, 1);
      final sessionCount = core.createdSessions.length;
      store.fail = false;
      await press(tester, 'setup-continue');
      expect(core.connectCount, 1);
      expect(core.createdSessions.length, sessionCount);
      expect(find.text('Welcome to Zommi'), findsNothing);
    },
  );

  testWidgets(
    'minimum window scrolls all setup controls including Mac permissions',
    (tester) async {
      final desktop = FakeDesktopBridge()..supportsCapturePermissions = true;
      await launch(tester, RichFakeCore(), _Store(), desktop);
      await tester.binding.setSurfaceSize(const Size(640, 500));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('setup-continue')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('setup-skip')).hitTestable(),
        findsOneWidget,
      );
      await press(tester, 'allow-accessibility');
      expect(desktop.permissionRequests, ['accessibility']);
      await press(tester, 'setup-skip');
      expect(tester.takeException(), isNull);
      expect(find.text('Welcome to Zommi'), findsNothing);
    },
  );
}
