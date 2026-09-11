import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/state/history_mapper.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/widgets/transcript_view.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'test_support.dart';

void main() {
  test('a partial live cache cannot swallow a later identical commentary', () {
    TranscriptBlock block(String id, TranscriptKind kind, String text) =>
        TranscriptBlock(id: id, kind: kind, title: '', text: text);
    final merged = mergeConversationTurn(
      ConversationTurn(
        id: 'live',
        userText: 'Inspect',
        blocks: [
          block('live-comment', TranscriptKind.commentary, 'Checking'),
          block('live-reason', TranscriptKind.thinking, 'First reasoning'),
        ],
      ),
      ConversationTurn(
        id: 'history',
        userText: 'Inspect',
        blocks: [
          block('c1', TranscriptKind.commentary, 'Checking'),
          block('r1', TranscriptKind.thinking, 'First reasoning'),
          block('c2', TranscriptKind.commentary, 'Checking'),
          block('r2', TranscriptKind.thinking, 'Second reasoning'),
        ],
      ),
    );
    expect(merged.blocks.map((block) => block.text), [
      'Checking',
      'First reasoning',
      'Checking',
      'Second reasoning',
    ]);
  });

  testWidgets('history shows thinking before repeated commentary and final', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final history = <String, Object?>{
      'thread': {
        'turns': [
          {
            'id': 'turn',
            'items': [
              {
                'id': 'c1',
                'type': 'agentMessage',
                'phase': 'commentary',
                'text': '正在查',
              },
              {
                'id': 'r1',
                'type': 'reasoning',
                'summary': ['Checking files'],
              },
              {
                'id': 'c2',
                'type': 'agentMessage',
                'phase': 'commentary',
                'text': '正在查',
              },
              {
                'id': 'r2',
                'type': 'reasoning',
                'summary': ['Checking results'],
              },
              {
                'id': 'answer',
                'type': 'agentMessage',
                'phase': 'final_answer',
                'text': '完成',
              },
            ],
          },
        ],
      },
    };
    final turns = mapThreadHistory(history);
    final blocks = distinctTranscriptBlocks(turns.single.blocks);
    expect(blocks.map((block) => block.id), ['c1', 'r1', 'c2', 'r2', 'answer']);
    expect(blocks.map((block) => block.kind), [
      TranscriptKind.commentary,
      TranscriptKind.thinking,
      TranscriptKind.commentary,
      TranscriptKind.thinking,
      TranscriptKind.assistant,
    ]);
    final core = RichFakeCore()
      ..historyBySession['runtime-codex\u0000session-1'] = history;
    await tester.pumpWidget(ZommiApp(core: core, desktop: FakeDesktopBridge()));
    await tester.pumpAndSettle();
    _expectThinkingBeforeMessages(tester, ['正在查', '正在查', '完成']);
    final group = tester.widget<ThinkingActivityGroup>(
      find.byType(ThinkingActivityGroup),
    );
    expect(group.activities.map((block) => block.id), ['r1', 'r2']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'streamed thinking stays above commentary and final as activity arrives',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final core = RichFakeCore()..historyCount = 0;
      await tester.pumpWidget(
        ZommiApp(core: core, desktop: FakeDesktopBridge()),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('zommi-composer')),
        'Check the changes',
      );
      await tester.tap(find.byKey(const ValueKey('send-message')));
      await tester.pump();
      var sequence = 0;
      void emit(String kind, String id, String text, {bool completed = false}) {
        core.emit(
          CoreEvent(
            name: 'item.update',
            sequence: ++sequence,
            runtimeTargetId: 'runtime-codex',
            sessionId: 'session-1',
            turnId: 'session-1-live-turn',
            payload: {
              'kind': kind,
              'itemId': id,
              'text': text,
              'lifecycle': completed ? 'completed' : 'delta',
              if (completed) 'replace': true else 'textMode': 'append',
            },
          ),
        );
      }

      emit('commentary', 'comment', 'Checking files');
      await tester.pump();
      expect(find.text('Checking files'), findsOneWidget);
      emit('commentary', 'comment', 'Checking files', completed: true);
      emit('thinking', 'reason', 'First reasoning', completed: true);
      await tester.pump();
      _expectThinkingBeforeMessages(tester, ['Checking files']);
      final initialGroup = tester.widget<ThinkingActivityGroup>(
        find.byType(ThinkingActivityGroup),
      );
      emit('commentary', 'comment', 'Checking files');
      emit('commentary', 'comment', 'Checking files', completed: true);
      emit('tool', 'inspect', 'Inspection result', completed: true);
      emit('thinking', 'reason', 'Second reasoning', completed: true);
      emit('assistant', 'answer', 'Complete', completed: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      const messages = ['Checking files', 'Checking files', 'Complete'];
      _expectThinkingBeforeMessages(tester, messages);
      final group = tester.widget<ThinkingActivityGroup>(
        find.byType(ThinkingActivityGroup),
      );
      expect(group.id, initialGroup.id);
      expect(group.activities.map((block) => block.text), [
        'First reasoning',
        'Inspection result',
        'Second reasoning',
      ]);
      expect(find.text('First reasoning'), findsNothing);
      expect(find.text('Second reasoning'), findsNothing);
      final toggle = find.byKey(ValueKey('thinking-toggle-${group.id}'));
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text('First reasoning'), findsOneWidget);
      expect(find.byKey(const ValueKey('activity-inspect')), findsOneWidget);
      expect(find.text('Second reasoning'), findsOneWidget);
      _expectThinkingBeforeMessages(tester, messages);

      emit('thinking', 'late-reason', 'Late reasoning', completed: true);
      await tester.pumpAndSettle();
      expect(find.text('First reasoning'), findsOneWidget);
      expect(find.text('Second reasoning'), findsOneWidget);
      expect(find.text('Late reasoning'), findsOneWidget);
      _expectThinkingBeforeMessages(tester, messages);

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text('First reasoning'), findsNothing);
      expect(find.text('Second reasoning'), findsNothing);
      expect(find.text('Late reasoning'), findsNothing);
      expect(find.text('Checking files'), findsNWidgets(2));
      _expectThinkingBeforeMessages(tester, messages);
      expect(tester.takeException(), isNull);
    },
  );
}

void _expectThinkingBeforeMessages(WidgetTester tester, List<String> texts) {
  expect(find.byType(ThinkingActivityGroup), findsOneWidget);
  final group = tester.widget<ThinkingActivityGroup>(
    find.byType(ThinkingActivityGroup),
  );
  final messages = tester
      .widgetList<AssistantBlockView>(find.byType(AssistantBlockView))
      .toList();
  expect(messages.map((message) => message.block.text), texts);
  final ordered = [
    find.byKey(ValueKey('user-message-${group.turn.id}')),
    find.byKey(ValueKey('activity-section-${group.id}')),
    for (final message in messages)
      find.byKey(ValueKey('assistant-${message.block.id}')),
  ];
  for (var index = 1; index < ordered.length; index++) {
    expect(
      tester.getTopLeft(ordered[index]).dy,
      greaterThan(tester.getBottomLeft(ordered[index - 1]).dy),
    );
  }
}
