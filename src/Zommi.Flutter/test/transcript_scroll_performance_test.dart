import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/widgets/content_views.dart';
import 'package:zommi_flutter/widgets/transcript_view.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'test_support.dart';

void main() {
  testWidgets(
    'folded thinking updates keep the visible reply and scroll idle',
    (tester) async {
      await tester.binding.setSurfaceSize(normalWindowSize);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final core = RichFakeCore()..historyCount = 0;
      await tester.pumpWidget(
        ZommiApp(core: core, desktop: FakeDesktopBridge()),
      );
      await tester.pumpAndSettle();
      var sequence = 0;
      void emit(String id, String kind, String text, {bool completed = false}) {
        core.emit(
          CoreEvent(
            name: 'item.update',
            sequence: ++sequence,
            runtimeTargetId: 'runtime-codex',
            sessionId: 'session-1',
            turnId: 'folded-turn',
            payload: {
              'itemId': id,
              'kind': kind,
              'text': text,
              'textMode': 'append',
              'lifecycle': completed ? 'completed' : 'delta',
            },
          ),
        );
      }

      emit(
        'answer',
        'assistant',
        'A visible answer.\n\n' * 30,
        completed: true,
      );
      for (var index = 0; index < 100; index++) {
        emit(
          'tool-$index',
          'tool',
          'Large hidden result. ' * 200,
          completed: true,
        );
      }
      emit('reasoning', 'thinking', 'Hidden starting text.');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      final transcript = find.byKey(const ValueKey('zommi-transcript'));
      final position = tester.widget<ListView>(transcript).controller!.position;
      final originalBodies = tester
          .elementList(find.byType(MarkdownBody))
          .toList();
      var messageBuilds = 0;
      debugOnRebuildDirtyWidget = (element, _) {
        if (element.widget is ConversationTurnView) messageBuilds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);
      for (var delta = 0; delta < 20; delta++) {
        emit('reasoning', 'thinking', ' Hidden delta $delta.');
        await tester.pump(const Duration(milliseconds: 50));
        expect(position.isScrollingNotifier.value, isFalse);
      }
      expect(messageBuilds, 0);
      expect(tester.elementList(find.byType(MarkdownBody)), originalBodies);
      expect(
        find.byKey(const ValueKey('thinking-activity-list')),
        findsNothing,
      );
      debugOnRebuildDirtyWidget = null;
      final toggle = find.byKey(const ValueKey('thinking-toggle-folded-turn'));
      await tester.ensureVisible(toggle);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(toggle);
      await tester.pump();
      expect(
        tester
            .widgetList<MarkdownBody>(find.byType(MarkdownBody))
            .any((body) => body.data.contains('Hidden delta 19.')),
        isTrue,
      );
      await tester.tap(toggle);
      await tester.pump();
      emit('reasoning', 'thinking', '', completed: true);
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('live thinking spinner does not repaint the surrounding turn', (
    tester,
  ) async {
    final core = RichFakeCore()..historyCount = 0;
    await tester.pumpWidget(ZommiApp(core: core, desktop: FakeDesktopBridge()));
    await tester.pumpAndSettle();
    core.emit(
      const CoreEvent(
        name: 'item.update',
        sequence: 1,
        runtimeTargetId: 'runtime-codex',
        sessionId: 'session-1',
        turnId: 'live',
        payload: {
          'itemId': 'reason',
          'kind': 'thinking',
          'text': 'Working',
          'lifecycle': 'delta',
        },
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    final group = find.byType(ThinkingActivityGroup);
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.ancestor(of: group, matching: find.byType(RepaintBoundary)).first,
    );
    final paintedContent = boundary.debugLayer!.firstChild;
    for (var frame = 0; frame < 5; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(boundary.debugLayer!.firstChild, same(paintedContent));
  });

  testWidgets(
    'recent replies retain Markdown state on return with a bounded cache',
    (tester) async {
      await tester.binding.setSurfaceSize(normalWindowSize);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final core = RichFakeCore()..historyCount = 18;
      await tester.pumpWidget(
        ZommiApp(core: core, desktop: FakeDesktopBridge()),
      );
      await tester.pumpAndSettle();
      final transcript = find.byKey(const ValueKey('zommi-transcript'));
      final position = tester.widget<ListView>(transcript).controller!.position;
      final body = find.byWidgetPredicate(
        (widget) =>
            widget is MarkdownBody && widget.data == 'history answer 18',
        skipOffstage: false,
      );
      final original = tester.element(body);
      final lastOffset = position.pixels;
      position.jumpTo(lastOffset - 700);
      await tester.pumpAndSettle();
      position.jumpTo(lastOffset);
      await tester.pumpAndSettle();
      expect(tester.element(body), same(original));
      for (var offset = lastOffset; offset > 0; offset -= 400) {
        position.jumpTo(offset);
        await tester.pumpAndSettle();
      }
      expect(original.mounted, isFalse, reason: 'Old rows must be evicted');
      final mounted = find
          .byType(ConversationTurnView, skipOffstage: false)
          .evaluate()
          .length;
      expect(mounted, lessThan(18));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('scrolling inside a long reply does not rebuild its message', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(normalWindowSize);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final core = RichFakeCore()..historyCount = 0;
    core.historyBySession['runtime-codex\u0000session-1'] = {
      'thread': {
        'id': 'session-1',
        'turns': [
          {
            'id': 'long-turn',
            'items': [
              {
                'id': 'question',
                'type': 'userMessage',
                'content': [
                  {'type': 'inputText', 'text': 'Explain the observations.'},
                ],
              },
              {
                'id': 'answer',
                'type': 'agentMessage',
                'phase': 'final',
                'text': List.generate(
                  60,
                  (index) =>
                      '### Observation $index\n\n'
                      'Keep this complete paragraph readable while scrolling. '
                      'Preserve **formatting**, links and selectable text.\n\n',
                ).join(),
              },
            ],
          },
        ],
      },
    };
    await tester.pumpWidget(ZommiApp(core: core, desktop: FakeDesktopBridge()));
    await tester.pumpAndSettle();
    final transcript = find.byKey(const ValueKey('zommi-transcript'));
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: transcript, matching: find.byType(Scrollable)).first,
    );
    final before = scrollable.position.pixels;
    var messageRebuilds = 0;
    debugOnRebuildDirtyWidget = (element, alreadyBuilt) {
      if (element.widget is ConversationTurnView) {
        messageRebuilds++;
      }
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    await tester.drag(transcript, const Offset(0, 220));
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, lessThan(before - 100));
    expect(messageRebuilds, 0);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('scroll-to-latest')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('streaming preserves the reader and skips unchanged history', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(normalWindowSize);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final core = RichFakeCore()..historyCount = 8;
    await tester.pumpWidget(ZommiApp(core: core, desktop: FakeDesktopBridge()));
    await tester.pumpAndSettle();
    final transcript = find.byKey(const ValueKey('zommi-transcript'));
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: transcript, matching: find.byType(Scrollable)).first,
    );
    await tester.drag(transcript, const Offset(0, 250));
    await tester.pumpAndSettle();
    final readingPosition = scrollable.position.pixels;
    expect(scrollable.position.extentAfter, greaterThan(36));
    final visibleHistory = tester
        .widgetList<ConversationTurnView>(find.byType(ConversationTurnView))
        .map((view) => view.turn.id)
        .toSet();
    expect(visibleHistory, isNotEmpty);
    var historyRebuilds = 0;
    debugOnRebuildDirtyWidget = (element, alreadyBuilt) {
      if (element.widget case ConversationTurnView(:final turn)) {
        if (visibleHistory.contains(turn.id)) historyRebuilds++;
      }
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);

    for (var index = 0; index < 12; index++) {
      core.emit(
        CoreEvent(
          name: 'item.update',
          sequence: index + 1,
          runtimeTargetId: 'runtime-codex',
          sessionId: 'session-1',
          turnId: 'live-turn',
          payload: {
            'itemId': 'live-answer',
            'kind': 'assistant',
            'lifecycle': 'delta',
            'text': 'Streaming fragment $index. ',
            'textMode': 'append',
          },
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(scrollable.position.pixels, closeTo(readingPosition, 0.1));
    }
    expect(historyRebuilds, 0);
    debugOnRebuildDirtyWidget = null;
    await tester.tap(find.byKey(const ValueKey('scroll-to-latest')));
    await tester.pumpAndSettle();
    expect(scrollable.position.extentAfter, lessThan(1));
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is CopyableMarkdown &&
            widget.text.contains('Streaming fragment 11.'),
      ),
      findsOneWidget,
    );

    core.emit(
      const CoreEvent(
        name: 'item.update',
        sequence: 13,
        runtimeTargetId: 'runtime-codex',
        sessionId: 'session-1',
        turnId: 'live-turn',
        payload: {
          'itemId': 'live-answer',
          'kind': 'assistant',
          'lifecycle': 'completed',
          'text': 'Final visible answer.',
          'replace': true,
        },
      ),
    );
    core.emit(
      const CoreEvent(
        name: 'turn.completed',
        sequence: 14,
        runtimeTargetId: 'runtime-codex',
        sessionId: 'session-1',
        turnId: 'live-turn',
        payload: {'status': 'completed'},
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is CopyableMarkdown &&
            widget.text == 'Final visible answer.',
      ),
      findsOneWidget,
    );
    expect(scrollable.position.extentAfter, lessThan(1));
  });
}
