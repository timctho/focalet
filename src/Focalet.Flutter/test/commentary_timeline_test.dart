import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focalet_flutter/core/core_bridge.dart';
import 'package:focalet_flutter/state/history_mapper.dart';
import 'package:focalet_flutter/state/focalet_controller.dart';
import 'package:focalet_flutter/state/focalet_models.dart';
import 'package:focalet_flutter/widgets/transcript_view.dart';
import 'package:focalet_flutter/focalet_app.dart';

import 'test_support.dart';

void main() {
  test(
    'history restores missing activity before its shared final response',
    () {
      TranscriptBlock block(String id, TranscriptKind kind, String text) =>
          TranscriptBlock(id: id, kind: kind, title: '', text: text);
      for (final preserveCached in [false, true]) {
        final canonical = ConversationTurn(
          id: 'turn',
          userText: 'Inspect',
          blocks: [
            block('r', TranscriptKind.thinking, 'Inspecting'),
            block('answer', TranscriptKind.assistant, 'Done'),
          ],
        );
        final cached = ConversationTurn(
          id: 'turn',
          userText: 'Inspect',
          blocks: [
            block('r-live', TranscriptKind.thinking, 'Inspecting'),
            block('tool', TranscriptKind.tool, 'Tool output'),
            block('answer-live', TranscriptKind.assistant, 'Done'),
          ],
        );
        final merged = mergeSessionHistory(
          [canonical],
          [cached],
          preserveCached: preserveCached,
        );
        expect(merged.single.blocks.map((block) => block.text), [
          'Inspecting',
          'Tool output',
          'Done',
        ]);
      }
    },
  );

  test(
    'history inserts an earlier missing segment before a shared commentary',
    () {
      TranscriptBlock block(String id, TranscriptKind kind, String text) =>
          TranscriptBlock(id: id, kind: kind, title: '', text: text);
      final merged = mergeConversationTurn(
        ConversationTurn(
          id: 'turn',
          userText: 'Inspect',
          blocks: [
            block('comment', TranscriptKind.commentary, 'Checking'),
            block('answer', TranscriptKind.assistant, 'Done'),
          ],
        ),
        ConversationTurn(
          id: 'turn',
          userText: 'Inspect',
          blocks: [
            block('reason', TranscriptKind.thinking, 'Plan'),
            block('comment', TranscriptKind.commentary, 'Checking'),
            block('tool', TranscriptKind.tool, 'Result'),
            block('answer', TranscriptKind.assistant, 'Done'),
          ],
        ),
      );
      expect(merged.blocks.map((block) => block.text), [
        'Plan',
        'Checking',
        'Result',
        'Done',
      ]);
    },
  );

  test(
    'repeated assistant messages separated by activity retain both positions',
    () {
      final blocks = distinctTranscriptBlocks([
        TranscriptBlock(
          id: 'first',
          kind: TranscriptKind.assistant,
          title: '',
          text: 'Done',
        ),
        TranscriptBlock(
          id: 'verify',
          kind: TranscriptKind.thinking,
          title: '',
          text: 'Verify',
        ),
        TranscriptBlock(
          id: 'final',
          kind: TranscriptKind.assistant,
          title: '',
          text: 'Done',
        ),
      ]);
      expect(blocks.map((block) => block.id), ['first', 'verify', 'final']);
    },
  );

  test(
    'interleaved tool progress completes its original activity block',
    () async {
      final core = RichFakeCore()..historyCount = 0;
      final controller = FocaletController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      await controller.submit('Inspect');
      var sequence = 0;
      void emit(
        String kind,
        String id,
        String text,
        String lifecycle, {
        String? before,
      }) {
        core.emit(
          CoreEvent(
            name: 'item.update',
            sequence: ++sequence,
            runtimeTargetId: 'runtime-codex',
            sessionId: 'session-1',
            turnId: controller.turns.single.id,
            payload: {
              'kind': kind,
              'itemId': id,
              'text': text,
              'lifecycle': lifecycle,
              'beforeItemId': ?before,
            },
          ),
        );
      }

      emit('tool', 'command', 'Started', 'started');
      emit('commentary', 'comment', 'Checking another file', 'completed');
      emit('thinking', 'reason', 'Next step', 'completed');
      emit('toolOutput', 'command', 'Progress', 'delta');
      emit('assistant', 'answer', 'Done', 'delta');
      emit(
        'thinking',
        'final-reason',
        'Final check',
        'completed',
        before: 'answer',
      );
      emit('tool', 'command', 'Completed', 'completed');
      final blocks = controller.turns.single.blocks;
      expect(blocks.map((block) => block.id), [
        'command',
        'comment',
        'reason',
        'final-reason',
        'answer',
      ]);
      expect(blocks.first.completed, isTrue);
      expect(
        blocks.where((block) => block.kind == TranscriptKind.tool),
        hasLength(1),
      );
    },
  );
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
    await tester.pumpWidget(
      FocaletApp(core: core, desktop: FakeDesktopBridge()),
    );
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
        FocaletApp(core: core, desktop: FakeDesktopBridge()),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(
        find.byKey(const ValueKey('focalet-composer')),
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
