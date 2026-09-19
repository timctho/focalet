import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';

import 'test_support.dart';

RichFakeCore startupCore(String error) => RichFakeCore()
  ..historyCount = 1
  ..savedBinding = {
    'runtimeTargetId': 'runtime-codex',
    'sessionId': 'saved-chat',
    'cwd': '/runtime/home',
    'sessionMetadata': {'cwd': '/work/saved', 'profile': 'saved-profile'},
  }
  ..connectErrorCode = error
  ..connectErrorMessage = 'The runtime is still starting';

ZommiController controllerFor(RichFakeCore core) => ZommiController(
  core: core,
  desktop: FakeDesktopBridge(),
  catalogStartupDelay: const Duration(days: 1),
);

void main() {
  for (final code in [
    'core-timeout',
    'runtime-unavailable',
    'runtime-exited',
  ]) {
    testWidgets('startup recovers $code without clicking a saved chat', (
      tester,
    ) async {
      final core = startupCore(code);
      final controller = controllerFor(core);
      addTearDown(controller.close);
      await controller.initialize();
      expect(controller.starting, isFalse);
      expect(controller.status, contains('Reconnecting'));
      controller.updateComposerValue(
        const TextEditingValue(text: 'Draft while waiting'),
      );
      // Discovery changing its selected chat must not redirect the retry.
      core.savedBinding = {
        'runtimeTargetId': 'runtime-pi',
        'sessionId': 'other-chat',
      };
      core.connectErrorCode = null;
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(controller.activeSessionId, 'saved-chat');
      expect(controller.activeRuntime?.id, 'runtime-codex');
      expect(core.connectionRequests.last, {
        'runtimeTargetId': 'runtime-codex',
        'preferredSessionId': 'saved-chat',
        'cwd': '/work/saved',
      });
      expect(core.openedSessionOptions.last['profile'], 'saved-profile');
      expect(controller.composerValue.text, 'Draft while waiting');
      expect(core.createdSessions, isEmpty);
      expect(core.lastMessage, isNull);
      expect(controller.statusWarning, isFalse);
      await tester.runAsync(controller.close);
    });
  }

  testWidgets('choosing another session cancels the startup retry', (
    tester,
  ) async {
    final core = startupCore('core-timeout');
    final controller = controllerFor(core);
    addTearDown(controller.close);
    await controller.initialize();
    core.connectErrorCode = null;
    await controller.switchSession(
      'session-2',
      runtimeTargetId: 'runtime-codex',
    );
    final connected = core.connectCount;
    await tester.pump(const Duration(seconds: 20));
    expect(core.connectCount, connected);
    expect(controller.activeSessionId, 'session-2');
    await tester.runAsync(controller.close);
  });

  testWidgets('closing cancels a pending startup retry', (tester) async {
    final core = startupCore('runtime-unavailable');
    final controller = controllerFor(core);
    await controller.initialize();
    await tester.runAsync(controller.close);
    await tester.pump(const Duration(seconds: 20));
    expect(core.connectCount, 1);
  });

  testWidgets(
    'clicking the selected chat retries a failed startup history read',
    (tester) async {
      final core = startupCore('core-timeout')
        ..connectErrorCode = null
        ..readSessionErrorCode = 'core-timeout'
        ..activeSessionsByRuntime['runtime-codex'] = 'saved-chat';
      final controller = controllerFor(core);
      addTearDown(controller.close);
      await controller.initialize();
      expect(controller.activeSessionId, 'saved-chat');
      expect(controller.status, contains('Reconnecting'));
      core.readSessionErrorCode = null;
      await controller.switchSession('saved-chat');
      expect(core.openedSessions, [('runtime-codex', 'saved-chat')]);
      expect(controller.turns, hasLength(1));
      final attempts = core.connectCount;
      await tester.pump(const Duration(seconds: 20));
      expect(core.connectCount, attempts);
      await tester.runAsync(controller.close);
    },
  );

  testWidgets('authentication failures do not retry automatically', (
    tester,
  ) async {
    final core = startupCore('authentication-required');
    final controller = controllerFor(core);
    addTearDown(controller.close);
    await controller.initialize();
    await tester.pump(const Duration(seconds: 20));
    expect(core.connectCount, 1);
    expect(controller.status, contains('sign-in required'));
    await tester.runAsync(controller.close);
  });

  testWidgets(
    'a failure without an exact saved binding does not create chats on retry',
    (tester) async {
      final core = startupCore('core-timeout')..savedBinding = {};
      final controller = controllerFor(core);
      addTearDown(controller.close);
      await controller.initialize();
      await tester.pump(const Duration(seconds: 20));
      expect(core.connectCount, 1);
      expect(core.createdSessions, isEmpty);
      await tester.runAsync(controller.close);
    },
  );
}
