import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focalet_flutter/core/core_bridge.dart';
import 'package:focalet_flutter/state/focalet_controller.dart';
import 'package:focalet_flutter/state/focalet_models.dart';
import 'package:focalet_flutter/widgets/transcript_view.dart';
import 'package:focalet_flutter/focalet_app.dart';

import 'test_support.dart';

Map<String, Object?> page(
  String session,
  int first,
  int last, {
  String? cursor,
  bool full = false,
}) => {
  'thread': {
    'id': session,
    'turns': [
      for (var i = first; i <= last; i++)
        {
          'id': '$session-turn-$i',
          'itemsView': full ? 'full' : 'summary',
          'items': [
            {
              'type': 'userMessage',
              'content': [
                {'type': 'text', 'text': 'Question $i'},
              ],
            },
            if (full)
              {
                'id': 'thinking-$i',
                'type': 'reasoning',
                'summary': [
                  {'type': 'summary_text', 'text': 'Activity $i'},
                ],
              },
            {'id': 'answer-$i', 'type': 'agentMessage', 'text': 'Answer $i'},
          ],
        },
    ],
  },
  if (!full) 'pagination': {'nextCursor': cursor},
};

class PagedCore extends RichFakeCore implements PagedHistoryBridge {
  Future<void>? pageGate;
  Future<void>? detailGate;
  bool detailFails = false;
  bool wrongDetail = false;
  int detailReads = 0;
  int pageReads = 0;
  PagedCore() {
    historyCount = 0;
    openHistoryBySession['runtime-codex\u0000session-2'] = page(
      'session-2',
      24,
      41,
      cursor: 'older',
    );
    historyBySession['runtime-codex\u0000session-2'] = page(
      'session-2',
      1,
      41,
      full: true,
    );
  }
  @override
  Future<Map<String, Object?>> readHistoryPage({
    required String runtimeTargetId,
    required String sessionId,
    required String cursor,
  }) async {
    pageReads++;
    if (pageGate case final gate?) await gate;
    return page(
      sessionId,
      cursor == 'older' ? 6 : 1,
      cursor == 'older' ? 23 : 5,
      cursor: cursor == 'older' ? 'oldest' : null,
    );
  }

  @override
  Future<Map<String, Object?>> readHistoryTurn({
    required String runtimeTargetId,
    required String sessionId,
    required String turnId,
  }) async {
    detailReads++;
    if (detailGate case final gate?) await gate;
    if (detailFails) throw StateError('offline');
    final number = int.parse(turnId.split('-').last);
    return page(wrongDetail ? 'wrong' : sessionId, number, number, full: true);
  }
}

void main() {
  test(
    'pages prepend once, lazy details retry/cache, copy includes full chat',
    () async {
      final core = PagedCore();
      final desktop = FakeDesktopBridge();
      final controller = FocaletController(core: core, desktop: desktop);
      addTearDown(controller.close);
      await controller.initialize();
      await controller.switchSession('session-2');
      expect(controller.turns.length, 18);
      expect(controller.hasOlderHistory, isTrue);
      expect(await controller.loadOlderHistory(), 18);
      expect(await controller.loadOlderHistory(), 5);
      expect(
        controller.turns.map((t) => t.userText),
        List.generate(41, (i) => 'Question ${i + 1}'),
      );
      expect(controller.hasOlderHistory, isFalse);
      core.detailFails = true;
      await controller.loadTurnHistory(controller.turns.last);
      expect(controller.turns.last.historyError, isNotNull);
      core.detailFails = false;
      await controller.loadTurnHistory(controller.turns.last);
      expect(controller.turns.last.historySummary, isFalse);
      expect(controller.turns.last.historyError, isNull);
      expect(
        controller.turns.last.blocks.any((b) => b.text == 'Activity 41'),
        isTrue,
      );
      await controller.loadTurnHistory(controller.turns.last);
      expect(core.detailReads, 2);
      await controller.switchSession('session-1');
      await controller.switchSession('session-2');
      expect(controller.turns.length, 41);
      expect(controller.turns.last.historySummary, isFalse);
      await controller.copySession(
        controller.sessions.firstWhere((s) => s.id == 'session-2'),
      );
      expect(desktop.copiedText, contains('Question 1'));
      expect(desktop.copiedText, contains('Activity 1'));
      expect(desktop.copiedText, contains('Answer 41'));
    },
  );

  test(
    'late pages stay with their chat and cannot revive deleted history',
    () async {
      final core = PagedCore();
      final controller = FocaletController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      await controller.switchSession('session-2');
      final gate = Completer<void>();
      core.pageGate = gate.future;
      final loading = controller.loadOlderHistory();
      await controller.switchSession('session-1');
      gate.complete();
      await loading;
      expect(controller.turns, isEmpty);
      await controller.switchSession('session-2');
      expect(controller.turns.length, 36);
      final deleted = controller.sessions.firstWhere(
        (s) => s.id == 'session-2',
      );
      final next = Completer<void>();
      core.pageGate = next.future;
      final pending = controller.loadOlderHistory();
      controller.deleteSessionMetadata(deleted);
      next.complete();
      await pending;
      expect(controller.turns, isEmpty);
      expect(controller.hasOlderHistory, isFalse);
    },
  );

  test('new streamed completion wins over a late detail snapshot', () async {
    final core = PagedCore();
    final controller = FocaletController(
      core: core,
      desktop: FakeDesktopBridge(),
    );
    addTearDown(controller.close);
    await controller.initialize();
    await controller.switchSession('session-2');
    final gate = Completer<void>();
    core.detailGate = gate.future;
    final loading = controller.loadTurnHistory(controller.turns.last);
    core.emit(
      const CoreEvent(
        name: 'item.update',
        sequence: 1,
        runtimeTargetId: 'runtime-codex',
        sessionId: 'session-2',
        turnId: 'session-2-turn-41',
        payload: {
          'itemId': 'answer-41',
          'kind': 'assistant',
          'text': 'Newest final answer',
          'replace': true,
          'lifecycle': 'completed',
        },
      ),
    );
    await Future<void>.delayed(Duration.zero);
    gate.complete();
    await loading;
    expect(
      controller.turns.last.blocks
          .where((b) => b.kind == TranscriptKind.assistant)
          .single
          .text,
      'Newest final answer',
    );
    core.wrongDetail = true;
    await controller.loadTurnHistory(controller.turns.first);
    expect(controller.turns.first.historySummary, isTrue);
    expect(controller.turns.first.userText, 'Question 24');
    expect(controller.turns.first.historyError, isNotNull);
  });

  test(
    'rewind invalidates pending pages and activity for discarded turns',
    () async {
      final core = PagedCore();
      final controller = FocaletController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      await controller.switchSession('session-2');
      final gate = Completer<void>();
      core.pageGate = gate.future;
      core.detailGate = gate.future;
      final pageLoad = controller.loadOlderHistory();
      final detailLoad = controller.loadTurnHistory(controller.turns.last);
      expect(
        await controller.resendMessage(controller.turns.first, 'Replacement'),
        isTrue,
      );
      final ids = controller.turns.map((turn) => turn.id).toList();
      gate.complete();
      await pageLoad;
      await detailLoad;
      expect(controller.turns.map((turn) => turn.id), ids);
      expect(controller.turns.last.userText, 'Replacement');
      expect(controller.hasOlderHistory, isFalse);
      expect(
        controller.turns.any((turn) => turn.userText == 'Question 41'),
        isFalse,
      );
    },
  );

  testWidgets(
    'scrolling past the first rendered page loads older native turns',
    (tester) async {
      final core = PagedCore();
      await tester.pumpWidget(
        FocaletApp(core: core, desktop: FakeDesktopBridge()),
      );
      await tester.pumpAndSettle();
      final controller = tester
          .widget<TranscriptPane>(find.byType(TranscriptPane))
          .controller;
      await controller.switchSession('session-2');
      await tester.pumpAndSettle();
      final scrollable = find.descendant(
        of: find.byKey(const ValueKey('focalet-transcript')),
        matching: find.byType(Scrollable),
      );
      final state = tester.state<ScrollableState>(scrollable);
      state.position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(core.pageReads, 1);
      expect(controller.turns.length, 36);
      expect(state.position.pixels, greaterThan(0));
      expect(tester.takeException(), isNull);
    },
  );
}
