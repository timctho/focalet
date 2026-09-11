import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/widgets/transcript_view.dart';
import 'package:zommi_flutter/zommi_app.dart';

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

void main() {
  testWidgets('a slow cold switch still starts on a bounded history page', (
    tester,
  ) async {
    final core = RichFakeCore()..historyCount = 50;
    await tester.pumpWidget(ZommiApp(core: core, desktop: FakeDesktopBridge()));
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
      find.byKey(const ValueKey('zommi-transcript')),
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
    final controller = ZommiController(
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
        final controller = ZommiController(
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
        final controller = ZommiController(
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
      final controller = ZommiController(
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
      final controller = ZommiController(
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
