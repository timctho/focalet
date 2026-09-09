import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/widgets/content_views.dart';
import 'package:zommi_flutter/widgets/transcript_view.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'test_support.dart';

void main() {
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
