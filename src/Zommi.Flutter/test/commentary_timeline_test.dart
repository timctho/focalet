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

  testWidgets('history preserves alternating responses and thinking', (
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
    _expectTimeline(tester, [
      'message:正在查',
      'thinking:Checking files',
      'message:正在查',
      'thinking:Checking results',
      'message:完成',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'streamed responses and activity retain their chronological groups',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final core = RichFakeCore()..historyCount = 0;
      await tester.pumpWidget(
        ZommiApp(core: core, desktop: FakeDesktopBridge()),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
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
      _expectTimeline(tester, [
        'message:Checking files',
        'thinking:First reasoning',
      ]);
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

      const timeline = [
        'message:Checking files',
        'thinking:First reasoning',
        'message:Checking files',
        'thinking:Inspection result|Second reasoning',
        'message:Complete',
      ];
      _expectTimeline(tester, timeline);
      final groups = tester
          .widgetList<ThinkingActivityGroup>(find.byType(ThinkingActivityGroup))
          .toList();
      expect(groups.first.id, initialGroup.id);
      expect(find.text('First reasoning'), findsNothing);
      expect(find.text('Second reasoning'), findsNothing);
      final toggle = find.byKey(ValueKey('thinking-toggle-${groups.first.id}'));
      await tester.tap(toggle);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('First reasoning'), findsOneWidget);
      expect(find.text('Second reasoning'), findsNothing);
      _expectTimeline(tester, timeline);

      emit('thinking', 'late-reason', 'Late reasoning', completed: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('First reasoning'), findsOneWidget);
      expect(find.text('Late reasoning'), findsNothing);
      _expectTimeline(tester, [...timeline, 'thinking:Late reasoning']);

      await tester.tap(toggle);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('First reasoning'), findsNothing);
      expect(find.text('Checking files'), findsNWidgets(2));
      _expectTimeline(tester, [...timeline, 'thinking:Late reasoning']);
      expect(tester.takeException(), isNull);
    },
  );
}

void _expectTimeline(WidgetTester tester, List<String> expected) {
  final views = find.byWidgetPredicate(
    (widget) => widget is AssistantBlockView || widget is ThinkingActivityGroup,
  );
  final widgets = tester.widgetList(views).toList();
  expect(
    widgets.map(
      (widget) => switch (widget) {
        AssistantBlockView() => 'message:${widget.block.text}',
        ThinkingActivityGroup() =>
          'thinking:${widget.activities.map((block) => block.text).join('|')}',
        _ => throw StateError('Unexpected transcript view'),
      },
    ),
    expected,
  );
  for (var index = 1; index < widgets.length; index++) {
    expect(
      tester.getTopLeft(find.byWidget(widgets[index])).dy,
      greaterThan(tester.getBottomLeft(find.byWidget(widgets[index - 1])).dy),
    );
  }
}
