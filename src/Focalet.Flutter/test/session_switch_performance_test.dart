import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focalet_flutter/core/core_bridge.dart';
import 'package:focalet_flutter/state/focalet_controller.dart';
import 'package:focalet_flutter/widgets/transcript_view.dart';
import 'package:focalet_flutter/focalet_app.dart';

import 'test_support.dart';

Map<String, Object?> history(String session, {String? answer}) => {
  'thread': {
    'id': session,
    'turns': [
      if (answer != null)
        {
          'id': 'turn',
          'items': [
            {'id': 'answer', 'type': 'agentMessage', 'text': answer},
          ],
        },
    ],
  },
};

class ColdSwitchCore extends RichFakeCore {
  bool returnPreviousSession = false;

  @override
  Future<RuntimeConnection> connectRuntime({
    required String runtimeTargetId,
    String? preferredSessionId,
    String? cwd,
  }) async {
    final value = await super.connectRuntime(
      runtimeTargetId: runtimeTargetId,
      preferredSessionId: returnPreviousSession ? null : preferredSessionId,
      cwd: cwd,
    );
    return RuntimeConnection(
      runtimeTargetId: value.runtimeTargetId,
      sessionId: value.sessionId,
      protocolVersion: value.protocolVersion,
      capabilities: value.capabilities,
      models: value.models,
      sessions: value.sessions,
      history: history(value.sessionId, answer: 'Connected history'),
    );
  }
}

class SlowGoalCore extends RichFakeCore {
  Completer<void>? goalGate;

  @override
  Future<Map<String, Object?>> goalCommand({
    required String runtimeTargetId,
    required String sessionId,
    required String action,
    String? objective,
    String? model,
    String? effort,
    String? cwd,
  }) async {
    if (goalGate case final gate?) await gate.future;
    return {'goal': null};
  }
}

void main() {
  for (final previous in [false, true]) {
    test(
      'cold cross-runtime connection reuses only exact history ($previous)',
      () async {
        final core = ColdSwitchCore()..returnPreviousSession = previous;
        final controller = FocaletController(
          core: core,
          desktop: FakeDesktopBridge(),
        );
        addTearDown(controller.close);
        await controller.initialize();
        final reads = core.readSessionCount;
        final connects = core.connectCount;
        await controller.switchSession(
          'pi-second',
          runtimeTargetId: 'runtime-pi',
        );
        expect(controller.activeRuntime?.id, 'runtime-pi');
        expect(controller.activeSessionId, 'pi-second');
        expect(core.connectCount, connects + 1);
        expect(
          core.openedSessions,
          previous ? [('runtime-pi', 'pi-second')] : isEmpty,
        );
        expect(core.readSessionCount, reads + (previous ? 1 : 0));
        if (!previous) {
          expect(
            controller.turns.single.blocks.single.text,
            'Connected history',
          );
        }
        await controller.switchSession(
          'session-2',
          runtimeTargetId: 'runtime-codex',
        );
        await controller.switchSession(
          'pi-second',
          runtimeTargetId: 'runtime-pi',
        );
        expect(core.connectCount, connects + 1);
        expect(core.openedSessions.last, ('runtime-pi', 'pi-second'));
        expect(core.lastMessage, isNull);
      },
    );
  }

  test(
    'optional goal read does not hold the selected transcript busy',
    () async {
      final core = SlowGoalCore()..historyCount = 0;
      final controller = FocaletController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      core.goalGate = Completer<void>();
      await controller
          .switchSession('session-2')
          .timeout(const Duration(seconds: 1));
      expect(controller.activeSessionId, 'session-2');
      expect(controller.sessionBusy, isFalse);
      core.goalGate!.complete();
    },
  );

  testWidgets('a slow cold switch still starts on a bounded history page', (
    tester,
  ) async {
    final core = RichFakeCore()..historyCount = 50;
    await tester.pumpWidget(
      FocaletApp(core: core, desktop: FakeDesktopBridge()),
    );
    await tester.pumpAndSettle();
    final controller = tester
        .widget<TranscriptPane>(find.byType(TranscriptPane))
        .controller;
    final gate = Completer<void>();
    core.readSessionGate = gate.future;
    final switching = controller.switchSession('session-2');
    await tester.pump();
    expect(controller.activeSessionId, 'session-2');
    expect(controller.sessionBusy, isTrue);
    gate.complete();
    await switching;
    await tester.pump();
    final list = tester.widget<ListView>(
      find.byKey(const ValueKey('focalet-transcript')),
    );
    expect(list.childrenDelegate.estimatedChildCount, historyPageSize);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('user-message-session-2-turn-50')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('user-message-session-2-turn-1')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  test('switching does not postpone discovery of other saved chats', () async {
    var now = DateTime.utc(2026, 9, 11);
    final core = RichFakeCore()..historyCount = 0;
    final controller = FocaletController(
      core: core,
      desktop: FakeDesktopBridge(),
      clock: () => now,
      catalogStartupDelay: const Duration(days: 1),
    );
    addTearDown(controller.close);
    await controller.initialize();
    now = now.add(const Duration(minutes: 16));
    await controller.switchSession('session-2');
    core.sessionsByRuntime['runtime-codex'] = [
      {
        'id': 'externally-created-chat',
        'preview': 'Discovered after switching',
      },
    ];
    await controller.refreshSessionCatalog();
    expect(
      controller.sessions.any(
        (session) => session.id == 'externally-created-chat',
      ),
      isTrue,
    );
  });

  for (final answer in [null, 'Canonical reply']) {
    test(
      'open history avoids a second read, including empty chats ($answer)',
      () async {
        final core = RichFakeCore()..historyCount = 0;
        final controller = FocaletController(
          core: core,
          desktop: FakeDesktopBridge(),
        );
        addTearDown(controller.close);
        await controller.initialize();
        core.openHistoryBySession['runtime-codex\u0000session-2'] = history(
          'session-2',
          answer: answer,
        );
        final readsBefore = core.readSessionCount;
        await controller.switchSession('session-2');
        expect(core.readSessionCount, readsBefore);
        expect(controller.turns, hasLength(answer == null ? 0 : 1));
        if (answer != null) {
          expect(controller.turns.single.blocks.single.text, answer);
        }
        expect(controller.sessionBusy, isFalse);
      },
    );
  }

  for (final inline in [
    null,
    history('wrong-session'),
    {
      'thread': {'id': 'session-2'},
    },
  ]) {
    test(
      'missing or mismatched inline history falls back to a read ($inline)',
      () async {
        final core = RichFakeCore()..historyCount = 0;
        final controller = FocaletController(
          core: core,
          desktop: FakeDesktopBridge(),
        );
        addTearDown(controller.close);
        await controller.initialize();
        if (inline != null) {
          core.openHistoryBySession['runtime-codex\u0000session-2'] = inline;
        }
        core.historyBySession['runtime-codex\u0000session-2'] = history(
          'session-2',
          answer: 'Fallback reply',
        );
        final readsBefore = core.readSessionCount;
        await controller.switchSession('session-2');
        expect(core.readSessionCount, readsBefore + 1);
        expect(controller.turns.single.blocks.single.text, 'Fallback reply');
      },
    );
  }

  test(
    'cached transcript is notified before a slow fallback read finishes',
    () async {
      final core = RichFakeCore()..historyCount = 1;
      final controller = FocaletController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      await controller.switchSession('session-2');
      final gate = Completer<void>();
      core.readSessionGate = gate.future;
      final visible = Completer<void>();
      controller.addListener(() {
        if (controller.activeSessionId == 'session-1' &&
            controller.turns.isNotEmpty &&
            !visible.isCompleted) {
          visible.complete();
        }
      });
      final switching = controller.switchSession('session-1');
      await visible.future.timeout(const Duration(seconds: 2));
      expect(controller.turns.single.userText, 'history user 1');
      expect(controller.sessionBusy, isTrue);
      await controller.submit('Do not send while the switch is pending');
      expect(core.lastMessage, isNull);
      gate.complete();
      await switching;
      expect(controller.sessionBusy, isFalse);
    },
  );

  test(
    'completion received during open wins over the earlier history snapshot',
    () async {
      final core = RichFakeCore()..historyCount = 0;
      final controller = FocaletController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      core.openHistoryBySession['runtime-codex\u0000session-2'] = history(
        'session-2',
        answer: 'Earlier snapshot',
      );
      final gate = Completer<void>();
      core.openSessionGate = gate.future;
      final switching = controller.switchSession('session-2');
      core.emit(
        const CoreEvent(
          name: 'item.update',
          sequence: 1,
          runtimeTargetId: 'runtime-codex',
          sessionId: 'session-2',
          turnId: 'turn',
          payload: {
            'itemId': 'answer',
            'kind': 'assistant',
            'text': 'Final reply',
            'lifecycle': 'completed',
          },
        ),
      );
      core.emit(
        const CoreEvent(
          name: 'turn.completed',
          sequence: 2,
          runtimeTargetId: 'runtime-codex',
          sessionId: 'session-2',
          turnId: 'turn',
          payload: {'status': 'completed'},
        ),
      );
      gate.complete();
      await switching;
      expect(controller.turnActive, isFalse);
      expect(controller.turns.single.blocks.single.text, 'Final reply');
    },
  );
}
