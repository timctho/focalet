import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focalet_flutter/core/core_bridge.dart';
import 'package:focalet_flutter/widgets/transcript_view.dart';
import 'package:focalet_flutter/focalet_app.dart';

import 'test_support.dart';

void main() {
  testWidgets('dots appear in a repeating sequence without changing size', (
    tester,
  ) async {
    var parentBuilds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            parentBuilds++;
            return const Center(child: TypingDots());
          },
        ),
      ),
    );
    final bounds = tester.getRect(find.byType(TypingDots));
    final initialBuilds = parentBuilds;
    for (final count in [1, 2, 3, 1, 2, 3, 1]) {
      expect(_visibleDots(tester), count);
      expect(tester.getRect(find.byType(TypingDots)), bounds);
      expect(parentBuilds, initialBuilds);
      await tester.pump(const Duration(milliseconds: 400));
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion and disabled tickers pause typing animation', (
    tester,
  ) async {
    Widget view({bool reduceMotion = false, bool enabled = true}) =>
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduceMotion),
            child: TickerMode(enabled: enabled, child: const TypingDots()),
          ),
        );
    await tester.pumpWidget(view(reduceMotion: true));
    expect(_visibleDots(tester), 3);
    await tester.pump(const Duration(seconds: 2));
    expect(_visibleDots(tester), 3);
    await tester.pumpWidget(view(enabled: false));
    final paused = _visibleDots(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(_visibleDots(tester), paused);
    await tester.pumpWidget(view());
    await tester.pump(const Duration(milliseconds: 400));
    expect(_visibleDots(tester), paused % 3 + 1);
    await tester.pumpWidget(const SizedBox());
  });

  for (final kind in ['commentary', 'assistant']) {
    testWidgets('typing waits through activity until the first $kind text', (
      tester,
    ) async {
      final start = Completer<void>();
      final core = RichFakeCore()
        ..historyCount = 0
        ..startTurnGate = start.future;
      await tester.pumpWidget(
        FocaletApp(core: core, desktop: FakeDesktopBridge()),
      );
      await _pumpUi(tester);
      expect(find.text('...'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('focalet-composer')),
        'Check this',
      );
      await tester.tap(find.byKey(const ValueKey('send-message')));
      await tester.pump();
      expect(find.text('...'), findsOneWidget);
      start.complete();
      await _pumpUi(tester);
      final controller = tester
          .widget<TranscriptPane>(find.byType(TranscriptPane))
          .controller;
      expect(controller.submitting, isFalse);
      expect(controller.turnActive, isTrue);
      expect(find.text('...'), findsOneWidget);

      void item(int sequence, String id, String kind, String text) => core.emit(
        CoreEvent(
          name: 'item.update',
          sequence: sequence,
          runtimeTargetId: 'runtime-codex',
          sessionId: 'session-1',
          turnId: 'session-1-live-turn',
          payload: {
            'kind': kind,
            'itemId': id,
            'text': text,
            'lifecycle': 'completed',
          },
        ),
      );
      item(1, 'reason', 'thinking', 'Inspecting');
      item(2, 'tool', 'tool', 'Read files');
      item(3, 'message', kind, '');
      await _pumpUi(tester);
      expect(find.text('...'), findsOneWidget);
      expect(find.byType(AssistantBlockView), findsNothing);
      expect(
        tester.getTopLeft(find.text('...')).dy,
        greaterThan(
          tester.getBottomLeft(find.byType(ThinkingActivityGroup)).dy,
        ),
      );
      item(4, 'message', kind, 'Here is the answer');
      await _pumpUi(tester);
      expect(find.text('...'), findsNothing);
      expect(find.text('Here is the answer'), findsOneWidget);
    });
  }

  for (final status in ['completed', 'interrupted', 'failed']) {
    testWidgets('typing clears when a turn ends as $status without a message', (
      tester,
    ) async {
      final core = RichFakeCore()..historyCount = 0;
      await tester.pumpWidget(
        FocaletApp(core: core, desktop: FakeDesktopBridge()),
      );
      await _pumpUi(tester);
      await tester.enterText(
        find.byKey(const ValueKey('focalet-composer')),
        'Check this',
      );
      await tester.tap(find.byKey(const ValueKey('send-message')));
      await _pumpUi(tester);
      expect(find.text('...'), findsOneWidget);
      core.emit(
        CoreEvent(
          name: 'turn.completed',
          sequence: 1,
          runtimeTargetId: 'runtime-codex',
          sessionId: 'session-1',
          turnId: 'session-1-live-turn',
          payload: {'status': status},
        ),
      );
      await _pumpUi(tester);
      expect(find.text('...'), findsNothing);
    });
  }

  testWidgets(
    'typing follows the active chat and clears after a rejected start',
    (tester) async {
      final start = Completer<void>();
      final core = RichFakeCore()
        ..historyCount = 0
        ..startTurnGate = start.future
        ..startTurnFails = true;
      await tester.pumpWidget(
        FocaletApp(core: core, desktop: FakeDesktopBridge()),
      );
      await _pumpUi(tester);
      final controller = tester
          .widget<TranscriptPane>(find.byType(TranscriptPane))
          .controller;
      final sending = controller.submit('Check this');
      await tester.pump();
      expect(find.text('...'), findsOneWidget);
      start.complete();
      await sending;
      await _pumpUi(tester);
      expect(find.text('...'), findsNothing);

      core.startTurnFails = false;
      await controller.submit('Try again');
      await _pumpUi(tester);
      expect(find.text('...'), findsOneWidget);
      await controller.switchSession('session-2');
      await _pumpUi(tester);
      expect(find.text('...'), findsNothing);
      await controller.switchSession('session-1');
      await _pumpUi(tester);
      expect(find.text('...'), findsOneWidget);
    },
  );
}

int _visibleDots(WidgetTester tester) {
  final span = tester.widget<Text>(find.text('...')).textSpan! as TextSpan;
  return span.children!
      .cast<TextSpan>()
      .where((dot) => dot.style!.color!.a != 0)
      .length;
}

// A live chat can keep focus/caret animations active while it responds.
// Advance the UI without waiting for every animation in the app to stop.
Future<void> _pumpUi(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}
