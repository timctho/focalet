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

  test('history preserves repeated commentary separated by reasoning', () {
    final turns = mapThreadHistory({
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
    });
    final blocks = distinctTranscriptBlocks(turns.single.blocks);
    expect(blocks.map((block) => block.id), ['c1', 'r1', 'c2', 'r2', 'answer']);
    expect(blocks.map((block) => block.kind), [
      TranscriptKind.commentary,
      TranscriptKind.thinking,
      TranscriptKind.commentary,
      TranscriptKind.thinking,
      TranscriptKind.assistant,
    ]);
  });

  testWidgets(
    'alternating streamed messages stay visible and fold independently',
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
      emit('commentary', 'comment', 'Checking files');
      emit('commentary', 'comment', 'Checking files', completed: true);
      emit('thinking', 'reason', 'Second reasoning', completed: true);
      emit('assistant', 'answer', 'Complete', completed: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final messages = tester
          .widgetList<AssistantBlockView>(find.byType(AssistantBlockView))
          .toList();
      final groups = tester
          .widgetList<ThinkingActivityGroup>(find.byType(ThinkingActivityGroup))
          .toList();
      expect(messages.map((message) => message.block.text), [
        'Checking files',
        'Checking files',
        'Complete',
      ]);
      expect(groups, hasLength(2));
      final ordered = [
        find.byKey(ValueKey('assistant-${messages[0].block.id}')),
        find.byKey(ValueKey('activity-section-${groups[0].id}')),
        find.byKey(ValueKey('assistant-${messages[1].block.id}')),
        find.byKey(ValueKey('activity-section-${groups[1].id}')),
        find.byKey(ValueKey('assistant-${messages[2].block.id}')),
      ];
      for (var index = 1; index < ordered.length; index++) {
        expect(
          tester.getTopLeft(ordered[index]).dy,
          greaterThan(tester.getBottomLeft(ordered[index - 1]).dy),
        );
      }
      expect(find.text('First reasoning'), findsNothing);
      expect(find.text('Second reasoning'), findsNothing);
      await tester.tap(find.byKey(ValueKey('thinking-toggle-${groups[0].id}')));
      await tester.pumpAndSettle();
      expect(find.text('First reasoning'), findsOneWidget);
      expect(find.text('Second reasoning'), findsNothing);
      await tester.tap(find.byKey(ValueKey('thinking-toggle-${groups[1].id}')));
      await tester.pumpAndSettle();
      expect(find.text('First reasoning'), findsOneWidget);
      expect(find.text('Second reasoning'), findsOneWidget);
      expect(find.text('Checking files'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );
}
