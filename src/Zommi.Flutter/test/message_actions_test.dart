import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/state/history_mapper.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/widgets/inline_attachment_composer.dart';
import 'package:zommi_flutter/widgets/transcript_view.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'test_support.dart';

Map<String, Object?> history() => {
  'thread': {
    'turns': [
      {
        'id': 'original',
        'startedAt': DateTime(2026, 9, 14, 14, 32).toIso8601String(),
        'items': [
          {
            'type': 'userMessage',
            'content': [
              {
                'type': 'text',
                'text':
                    'Polish the message controls and improve panel contrast.',
              },
            ],
          },
          {
            'id': 'answer',
            'type': 'agentMessage',
            'createdAt': DateTime(2026, 9, 14, 14, 33).toIso8601String(),
            'text': 'The message controls now sit below each message.\n\nYou can **copy**, edit and resend your messages, with the time beside the controls.\n\nThe panels use clear contrast, subtle borders and your selected theme color.',
            'status': 'completed',
          },
        ],
      },
    ],
  },
};

void main() {
  for (final text in [
    'A short message',
    'Please check the alignment of this user message and keep the spacing equal on both sides.',
  ]) {
    testWidgets('user bubble has equal visible text insets: $text', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(640, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final core = RichFakeCore()
        ..historyBySession['runtime-codex\u0000session-1'] = {
          'thread': {
            'turns': [
              {
                'id': 'padding',
                'items': [
                  {
                    'type': 'userMessage',
                    'content': [
                      {'type': 'text', 'text': text},
                    ],
                  },
                ],
              },
            ],
          },
        };
      await tester.pumpWidget(
        ZommiApp(core: core, desktop: FakeDesktopBridge()),
      );
      await tester.pumpAndSettle();
      final bubble = find.byKey(const ValueKey('user-message-padding'));
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: bubble,
          matching: find.byWidgetPredicate(
            (widget) => widget is RichText && widget.text.toPlainText() == text,
          ),
        ),
      );
      // Selecting whole wrapped lines includes invisible trailing spaces;
      // compare the visible words, allowing subpixel glyph side bearings.
      final boxes = [
        for (final word in RegExp(r'\S+').allMatches(text))
          ...paragraph.getBoxesForSelection(
            TextSelection(baseOffset: word.start, extentOffset: word.end),
          ),
      ];
      final left = boxes.map((box) => box.left).reduce((a, b) => a < b ? a : b);
      final right = boxes
          .map((box) => box.right)
          .reduce((a, b) => a > b ? a : b);
      final origin = paragraph.localToGlobal(Offset.zero).dx;
      final bounds = tester.getRect(bubble);
      expect(
        origin + left - bounds.left,
        closeTo(bounds.right - origin - right, .5),
      );
    });
  }

  test('history preserves timestamps through normalization and refresh', () {
    final original = mapThreadHistory(history()).single;
    expect(original.createdAt, DateTime(2026, 9, 14, 14, 32));
    expect(original.blocks.single.createdAt, DateTime(2026, 9, 14, 14, 33));
    final untimed = ConversationTurn(
      id: original.id,
      userText: original.userText,
      blocks: [
        TranscriptBlock(
          id: 'answer',
          kind: TranscriptKind.assistant,
          title: 'Agent',
          text: original.blocks.single.text,
        ),
      ],
    );
    final merged = mergeConversationTurn(untimed, original);
    expect(merged.createdAt, original.createdAt);
    expect(merged.blocks.single.createdAt, original.blocks.single.createdAt);
    expect(
      messageTimestamp({'timestamp': 1789396320}),
      DateTime.fromMillisecondsSinceEpoch(1789396320000, isUtc: true),
    );
    expect(
      messageTimestamp({'createdAt': '1789396320000'}),
      DateTime.fromMillisecondsSinceEpoch(1789396320000, isUtc: true),
    );
    expect(messageTimestamp({}), isNull);
    expect(messageTimestamp({'timestamp': 'invalid'}), isNull);
  });

  test('resend preserves attachments and draft, queues once and keeps its send time', () async {
    final core = RichFakeCore()
      ..historyCount = 0
      ..uniqueTurnIds = true;
    var now = DateTime(2026, 9, 14, 14, 32);
    final controller = ZommiController(
      core: core,
      desktop: FakeDesktopBridge(),
      clock: () => now,
    );
    addTearDown(controller.close);
    await controller.initialize();
    controller.addAttachment(
      ContextAttachment(
        id: 'image',
        token: '',
        imageDataUrl: 'data:image/png;base64,YQ==',
        snapshot: const {
          'selection': ['Original context'],
        },
      ),
    );
    await controller.submit('Original prompt');
    final original = controller.turns.single;
    expect(original.createdAt, now);
    controller.updateComposerValue(
      const TextEditingValue(text: 'Unrelated draft'),
    );
    controller.addAttachment(ContextAttachment(id: 'draft-image', token: ''));
    now = now.add(const Duration(minutes: 1));
    expect(await controller.resendMessage(original, 'Edited prompt'), isTrue);
    expect(controller.composerValue.text, 'Unrelated draft');
    expect(controller.attachments.single.id, 'draft-image');
    expect(controller.turns.single.userText, 'Original prompt');
    expect(controller.queuedMessages.single.text, 'Edited prompt');
    expect(controller.queuedMessages.single.createdAt, now);
    final first = core.startedTurns.single;
    now = now.add(const Duration(minutes: 3));
    core.emit(
      CoreEvent(
        name: 'turn.completed',
        sequence: 1,
        runtimeTargetId: 'runtime-codex',
        sessionId: 'session-1',
        turnId: first['turnId'] as String,
        clientOperationId: first['clientOperationId'] as String,
        payload: const {'status': 'completed'},
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(core.startedTurns.map((turn) => turn['message']), [
      'Original prompt',
      'Edited prompt',
    ]);
    expect(core.lastImages, ['data:image/png;base64,YQ==']);
    expect(core.lastSnapshots.single['contextLabel'], 'A');
    expect(controller.turns.last.createdAt, DateTime(2026, 9, 14, 14, 33));
    core.emit(
      CoreEvent(
        name: 'item.update',
        sequence: 2,
        runtimeTargetId: 'runtime-codex',
        sessionId: 'session-1',
        turnId: core.startedTurns.last['turnId'] as String,
        clientOperationId:
            core.startedTurns.last['clientOperationId'] as String,
        payload: const {
          'kind': 'assistant',
          'lifecycle': 'delta',
          'text': 'Reply',
          'itemId': 'live-answer',
        },
      ),
    );
    expect(controller.turns.last.blocks.single.createdAt, now);
    controller.sessionBusy = true;
    expect(await controller.resendMessage(original, 'Blocked'), isFalse);
    expect(core.startedTurns, hasLength(2));
  });

  testWidgets(
    'footers align below messages and edit cancel/resend preserves the composer',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final core = RichFakeCore()
        ..historyBySession['runtime-codex\u0000session-1'] = history();
      final desktop = FakeDesktopBridge();
      await tester.pumpWidget(ZommiApp(core: core, desktop: desktop));
      await tester.pumpAndSettle();
      final user = tester.getRect(
        find.byKey(const ValueKey('user-message-original')),
      );
      final userActions = tester.getRect(
        find.byKey(const ValueKey('user-actions-original')),
      );
      final agent = tester.getRect(
        find.byKey(const ValueKey('assistant-answer')),
      );
      final agentActions = tester.getRect(
        find.byKey(const ValueKey('assistant-actions-answer')),
      );
      expect(userActions.top, greaterThanOrEqualTo(user.bottom));
      expect(userActions.right, closeTo(user.right, .1));
      expect(agentActions.top, greaterThanOrEqualTo(agent.bottom));
      expect(agentActions.left, closeTo(agent.left, .1));
      expect(find.text('14:32'), findsOneWidget);
      expect(find.text('14:33'), findsOneWidget);
      expect(find.byTooltip('Copy response'), findsOneWidget);
      await tester.tap(find.byTooltip('Copy message'));
      await tester.pump();
      expect(desktop.copiedText, contains('Polish the message controls'));
      await tester.pump(const Duration(seconds: 1));
      final composer = find.byKey(const ValueKey('zommi-composer'));
      await tester.enterText(composer, 'Keep my draft');
      await tester.tap(find.byTooltip('Edit and resend'));
      await tester.pumpAndSettle();
      final editor = find.byKey(const ValueKey('edit-message-text-original'));
      await tester.enterText(editor, 'Discard this edit');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(core.startedTurns, isEmpty);
      expect(
        tester.widget<TextField>(composer).controller!.text,
        'Keep my draft',
      );
      await tester.tap(find.byTooltip('Edit and resend'));
      await tester.pumpAndSettle();
      await tester.enterText(editor, 'Edited and resent');
      await tester.tap(find.byKey(const ValueKey('resend-message-original')));
      await tester.pump();
      expect(core.lastMessage, 'Edited and resent');
      expect(core.startedTurns, hasLength(1));
      expect(
        tester.widget<TextField>(composer).controller!.text,
        'Keep my draft',
      );
      expect(
        find.byKey(const ValueKey('user-message-original')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'only the final answer gets a copy action after turn completion',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final core = RichFakeCore()..historyCount = 0;
      final desktop = FakeDesktopBridge();
      await tester.pumpWidget(ZommiApp(core: core, desktop: desktop));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('zommi-composer')),
        'Inspect',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      var sequence = 0;
      void emit(String kind, String id, String text, {bool completed = true}) {
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
              'replace': true,
            },
          ),
        );
      }

      const answer = 'Verified.\n\n```text\nfinal code\n```';
      emit('commentary', 'progress', 'Checking files');
      emit('assistant', 'early', answer);
      emit('thinking', 'reason', 'Inspecting\n\n```text\nreasoning code\n```');
      emit('tool', 'tool', '```text\ntool output\n```');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final group = tester.widget<ThinkingActivityGroup>(
        find.byType(ThinkingActivityGroup),
      );
      await tester.tap(find.byKey(ValueKey('thinking-toggle-${group.id}')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('tool-toggle-tool')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('reasoning code'), findsOneWidget);
      expect(find.textContaining('tool output'), findsOneWidget);
      expect(find.byTooltip('Copy response'), findsNothing);
      expect(find.byTooltip('Copy code'), findsNothing);

      emit('assistant', 'final', answer, completed: false);
      await tester.pump();
      expect(find.byTooltip('Copy response'), findsNothing);
      emit('assistant', 'final', answer);
      await tester.pump();
      expect(find.byTooltip('Copy response'), findsNothing);
      core.emit(
        CoreEvent(
          name: 'turn.completed',
          sequence: ++sequence,
          runtimeTargetId: 'runtime-codex',
          sessionId: 'session-1',
          turnId: 'session-1-live-turn',
          payload: const {'status': 'completed'},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Copy response'), findsOneWidget);
      expect(find.byTooltip('Copy code'), findsNothing);
      expect(
        find.byKey(const ValueKey('assistant-actions-early')),
        findsNothing,
      );
      final footer = find.byKey(const ValueKey('assistant-actions-final'));
      expect(footer, findsOneWidget);
      expect(
        tester.getTopLeft(footer).dy,
        greaterThanOrEqualTo(
          tester
              .getBottomLeft(find.byKey(const ValueKey('assistant-final')))
              .dy,
        ),
      );
      await tester.tap(find.byTooltip('Copy response'));
      await tester.pump();
      expect(desktop.copiedText, answer);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('attached user messages expose the same copy and edit actions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const image =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
    final desktop = FakeDesktopBridge()
      ..nextSelections = [
        ContextAttachment(id: 'image', token: '', imageDataUrl: image),
      ];
    final core = RichFakeCore()..historyCount = 0;
    await tester.pumpWidget(ZommiApp(core: core, desktop: desktop));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('zommi-composer')),
      'Explain the image',
    );
    await tester.tap(find.byKey(const ValueKey('select-content')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('send-message')));
    await tester.pump();
    await tester.tap(find.byTooltip('Copy message'));
    await tester.pump();
    expect(desktop.copiedText, 'Explain the image');
    await tester.tap(find.byTooltip('Edit and resend'));
    await tester.pump();
    expect(find.byType(InlineAttachmentMessage), findsOneWidget);
    expect(find.byType(Image), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
