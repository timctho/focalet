import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'test_support.dart';

class RecoveryCore extends RichFakeCore {
  Object? nextOpenError;
  bool readOnly = false;
  Object? nextTurnError;

  @override
  Future<TurnReceipt> startTurn({
    required String runtimeTargetId,
    required String sessionId,
    required String message,
    List<Map<String, Object?>> snapshots = const [],
    List<String> images = const [],
    String? clientOperationId,
    String? model,
    String? effort,
    String? cwd,
    String? profile,
  }) async {
    if (nextTurnError case final error?) {
      nextTurnError = null;
      throw error;
    }
    return super.startTurn(
      runtimeTargetId: runtimeTargetId,
      sessionId: sessionId,
      message: message,
      snapshots: snapshots,
      images: images,
      clientOperationId: clientOperationId,
      model: model,
      effort: effort,
      cwd: cwd,
      profile: profile,
    );
  }

  @override
  Future<RuntimeConnection> openSession({
    required String runtimeTargetId,
    required String sessionId,
    String? cwd,
    String? profile,
  }) async {
    if (nextOpenError case final error?) {
      nextOpenError = null;
      openedSessions.add((runtimeTargetId, sessionId));
      throw error;
    }
    final value = await super.openSession(
      runtimeTargetId: runtimeTargetId,
      sessionId: sessionId,
      cwd: cwd,
      profile: profile,
    );
    return RuntimeConnection(
      runtimeTargetId: value.runtimeTargetId,
      sessionId: value.sessionId,
      protocolVersion: value.protocolVersion,
      models: value.models,
      sessions: value.sessions,
      capabilities: value.capabilities,
      sessionMetadata: {...value.sessionMetadata, 'readOnly': readOnly},
      history: value.history,
    );
  }
}

void main() {
  testWidgets(
    'initialize timeout keeps diagnostics visible without repeating a 30 second stall',
    (tester) async {
      final core = RecoveryCore()..historyCount = 0;
      final controller = ZommiController(
        core: core,
        desktop: FakeDesktopBridge(),
        catalogStartupDelay: const Duration(days: 1),
      );
      await controller.initialize();
      controller.updateComposerValue(
        const TextEditingValue(text: 'keep my draft'),
      );
      core.nextOpenError = const CoreProtocolException(
        'runtime-initialize-timeout',
        'Startup stderr: configuration unavailable',
      );
      await controller.switchSession('session-2');
      await tester.pump(const Duration(seconds: 35));
      expect(core.openedSessions, hasLength(1));
      expect(controller.status, contains('configuration unavailable'));
      expect(controller.sessionBusy, isFalse);
      expect(controller.composerValue.text, 'keep my draft');
      await controller.switchSession('session-2');
      expect(controller.activeSessionId, 'session-2');
      await tester.runAsync(controller.close);
    },
  );

  testWidgets('a pre-submission recovery error restores the visible composer', (
    tester,
  ) async {
    final core = RecoveryCore()..historyCount = 0;
    await tester.pumpWidget(ZommiApp(core: core, desktop: FakeDesktopBridge()));
    await tester.pumpAndSettle();
    core.nextTurnError = const CoreProtocolException(
      'runtime-recovering',
      'not sent',
    );
    await tester.enterText(
      find.byKey(const ValueKey('zommi-composer')),
      'restore this draft',
    );
    await tester.tap(find.byKey(const ValueKey('send-message')));
    await tester.pumpAndSettle();
    expect(find.text('restore this draft'), findsOneWidget);
    expect(core.lastMessage, isNull);
  });
  test(
    'rapid selections keep the latest intent and preserve the original draft',
    () async {
      final core = RecoveryCore()..historyCount = 0;
      final controller = ZommiController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      controller.updateComposerValue(
        const TextEditingValue(text: 'unsent original'),
      );
      final gate = Completer<void>();
      core.openSessionGate = gate.future;
      final first = controller.switchSession('session-2');
      final latest = controller.switchSession('session-1');
      gate.complete();
      await Future.wait([first, latest]);
      expect(core.activeSessionId, 'session-1');
      expect(controller.activeSessionId, 'session-1');
      expect(controller.composerValue.text, 'unsent original');
      expect(controller.sessionBusy, isFalse);
    },
  );

  for (final code in [
    'runtime-recovering',
    'runtime-exited',
    'unknown-outcome',
    'runtime-overloaded',
    'wsl-startup-failed',
  ]) {
    testWidgets('$code automatically retries only the requested switch', (
      tester,
    ) async {
      final core = RecoveryCore()..historyCount = 0;
      final controller = ZommiController(
        core: core,
        desktop: FakeDesktopBridge(),
        catalogStartupDelay: const Duration(days: 1),
      );
      await controller.initialize();
      controller.updateComposerValue(
        const TextEditingValue(text: 'keep my draft'),
      );
      core.nextOpenError = CoreProtocolException(code, 'temporary');
      await controller.switchSession('session-2');
      expect(controller.activeSessionId, 'session-1');
      expect(controller.composerValue.text, 'keep my draft');
      expect(controller.status, contains('Reconnecting'));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(controller.activeSessionId, 'session-2');
      expect(
        core.openedSessions.where((s) => s.$2 == 'session-2'),
        hasLength(2),
      );
      expect(core.lastMessage, isNull);
      await tester.runAsync(controller.close);
    });
  }

  test('a newer choice cancels a pending automatic retry', () async {
    final core = RecoveryCore()..historyCount = 0;
    final controller = ZommiController(
      core: core,
      desktop: FakeDesktopBridge(),
    );
    await controller.initialize();
    core.nextOpenError = const CoreProtocolException(
      'runtime-recovering',
      'temporary',
    );
    await controller.switchSession('session-2');
    await controller.switchSession('session-3');
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(controller.activeSessionId, 'session-3');
    expect(core.openedSessions.where((s) => s.$2 == 'session-2'), hasLength(1));
    await controller.close();
  });

  test(
    'a busy turn preserves the draft without locking future submission',
    () async {
      final core = RecoveryCore()..historyCount = 0;
      final controller = ZommiController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      controller.updateComposerValue(const TextEditingValue(text: 'keep this'));
      core.nextTurnError = const CoreProtocolException(
        'session-busy',
        'turn active',
      );
      await controller.submit('keep this');
      expect(controller.composerValue.text, 'keep this');
      expect(controller.sessionReadOnly, isFalse);
      expect(core.lastMessage, isNull);
      await controller.submit('keep this');
      expect(core.lastMessage, 'keep this');
    },
  );

  for (final action in ['new chat', 'same runtime', 'different runtime']) {
    test('$action cancels a pending chat recovery', () async {
      final core = RecoveryCore()..historyCount = 0;
      final controller = ZommiController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      core.nextOpenError = const CoreProtocolException(
        'runtime-recovering',
        'temporary',
      );
      await controller.switchSession('session-2');
      switch (action) {
        case 'new chat':
          await controller.createSession();
        case 'same runtime':
          await controller.selectRuntime('runtime-codex');
        case 'different runtime':
          await controller.selectRuntime('runtime-pi');
      }
      final selectedSession = controller.activeSessionId;
      final selectedRuntime = controller.activeRuntime?.id;
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(controller.activeSessionId, selectedSession);
      expect(controller.activeRuntime?.id, selectedRuntime);
      expect(
        core.openedSessions.where((s) => s.$2 == 'session-2'),
        hasLength(1),
      );
    });
  }

  test(
    'permanent errors preserve the selected chat and do not retry',
    () async {
      final core = RecoveryCore()..historyCount = 0;
      final controller = ZommiController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      await controller.initialize();
      core.nextOpenError = const CoreProtocolException(
        'invalid-configuration',
        'invalid home',
      );
      await controller.switchSession('session-2');
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(controller.activeSessionId, 'session-1');
      expect(core.openedSessions, hasLength(1));
      expect(controller.status, contains('invalid home'));
      await controller.close();
    },
  );

  test(
    'read-only chat preserves its draft and becomes writable on refresh',
    () async {
      final core = RecoveryCore()
        ..historyCount = 1
        ..readOnly = true;
      final controller = ZommiController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      await controller.switchSession('session-2');
      controller.updateComposerValue(
        const TextEditingValue(text: 'wait for me'),
      );
      expect(controller.sessionReadOnly, isTrue);
      expect(controller.turns, isNotEmpty);
      await controller.submit('wait for me');
      expect(core.lastMessage, isNull);
      expect(controller.composerValue.text, 'wait for me');
      core.emit(
        const CoreEvent(
          name: 'session.refreshed',
          sequence: 200,
          runtimeTargetId: 'runtime-codex',
          sessionId: 'session-2',
          payload: {
            'connection': {
              'runtimeTargetId': 'runtime-codex',
              'sessionId': 'session-2',
              'sessionMetadata': {'readOnly': false},
              'history': {
                'thread': {'id': 'session-2', 'turns': []},
              },
            },
          },
        ),
      );
      expect(controller.sessionReadOnly, isFalse);
      expect(controller.activeSessionId, 'session-2');
      expect(controller.composerValue.text, 'wait for me');
      await controller.submit('wait for me');
      expect(core.lastMessage, 'wait for me');
    },
  );
}
