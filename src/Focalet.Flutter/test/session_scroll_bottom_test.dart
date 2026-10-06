import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focalet_flutter/widgets/transcript_view.dart';
import 'package:focalet_flutter/focalet_app.dart';

import 'test_support.dart';

Map<String, Object?> history(String session, {int count = 50}) => {
  'thread': {
    'id': session,
    'turns': [
      for (var index = 1; index <= count; index++)
        {
          'id': '$session-turn-$index',
          'items': [
            {
              'id': '$session-question-$index',
              'type': 'userMessage',
              'content': [
                {'type': 'inputText', 'text': 'Question $index'},
              ],
            },
            {
              'id': '$session-answer-$index',
              'type': 'agentMessage',
              'phase': 'final',
              'text': index == count
                  ? '${'A long final reply with variable-height paragraphs.\n\n' * 60}Latest line.'
                  : 'Answer $index.',
            },
          ],
        },
    ],
  },
};

ScrollPosition position(WidgetTester tester) => tester
    .widget<ListView>(find.byKey(const ValueKey('focalet-transcript')))
    .controller!
    .position;

void expectBottom(WidgetTester tester) {
  expect(position(tester).extentAfter, lessThan(1));
  expect(
    tester
        .widget<IconButton>(find.byKey(const ValueKey('scroll-to-latest')))
        .onPressed,
    isNull,
  );
}

void main() {
  testWidgets(
    'switching and returning to long chats always reaches the bottom',
    (tester) async {
      final core = RichFakeCore()..historyCount = 50;
      core.historyBySession['runtime-codex\u0000session-2'] = history(
        'session-2',
      );
      await tester.pumpWidget(
        FocaletApp(core: core, desktop: FakeDesktopBridge()),
      );
      await tester.pumpAndSettle();
      for (final session in ['session-2', 'session-1', 'session-2']) {
        position(tester).jumpTo(300);
        await tester.pumpAndSettle();
        expect(position(tester).extentAfter, greaterThan(36));
        await tester.tap(
          find.byKey(ValueKey('session-runtime-codex-$session')),
        );
        await tester.pumpAndSettle();
        expectBottom(tester);
        expect(
          find.byKey(ValueKey('user-message-$session-turn-1')),
          findsNothing,
          reason: 'Opening at the bottom must not page in older history',
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'returning to a cached chat settles again after refreshed history arrives',
    (tester) async {
      final core = RichFakeCore()..historyCount = 18;
      await tester.pumpWidget(
        FocaletApp(core: core, desktop: FakeDesktopBridge()),
      );
      await tester.pumpAndSettle();
      final controller = tester
          .widget<TranscriptPane>(find.byType(TranscriptPane))
          .controller;
      await controller.switchSession('session-2');
      await tester.pumpAndSettle();
      core.historyBySession['runtime-codex\u0000session-1'] = history(
        'session-1',
        count: 80,
      );
      final gate = Completer<void>();
      core.readSessionGate = gate.future;
      final switching = controller.switchSession('session-1');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.activeSessionId, 'session-1');
      expect(controller.turns, hasLength(18));
      gate.complete();
      await switching;
      await tester.pumpAndSettle();
      expect(controller.turns, hasLength(80));
      expectBottom(tester);
      expect(
        find.byKey(const ValueKey('user-message-session-1-turn-1')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'delayed history and identical session IDs in different runtimes start at bottom',
    (tester) async {
      final core = RichFakeCore()..historyCount = 18;
      core.historyBySession['runtime-pi\u0000session-1'] = history('session-1');
      await tester.pumpWidget(
        FocaletApp(core: core, desktop: FakeDesktopBridge()),
      );
      await tester.pumpAndSettle();
      final controller = tester
          .widget<TranscriptPane>(find.byType(TranscriptPane))
          .controller;
      position(tester).jumpTo(300);
      await tester.pumpAndSettle();
      final gate = Completer<void>();
      core.readSessionGate = gate.future;
      final switching = controller.switchSession(
        'session-1',
        runtimeTargetId: 'runtime-pi',
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.activeRuntime?.id, 'runtime-pi');
      gate.complete();
      await switching;
      await tester.pumpAndSettle();
      expectBottom(tester);
      // Normal scrolling after switching still lets the user read older content.
      await tester.drag(
        find.byKey(const ValueKey('focalet-transcript')),
        const Offset(0, 300),
      );
      await tester.pumpAndSettle();
      expect(position(tester).extentAfter, greaterThan(36));
      expect(tester.takeException(), isNull);
    },
  );
}
