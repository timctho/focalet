import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'test_support.dart';

const _onePixelPng =
    'data:image/png;base64,'
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

void main() {
  testWidgets(
    'shortcut capture accumulates selection-first tokens before panel focus',
    (tester) async {
      final core = RichFakeCore()..historyCount = 0;
      final desktop = FakeDesktopBridge();
      await _pumpApp(tester, core: core, desktop: desktop);
      desktop.calls.clear();

      final first = _browserAttachment('capture-1');
      desktop.emit(
        DesktopInvocation(
          kind: DesktopInvocationKind.context,
          attachment: first,
          message: 'Context attached',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('zommi-composer')), findsOneWidget);
      expect(find.text('[example.com]'), findsOneWidget);
      expect(
        desktop.calls,
        containsAllInOrder(['surface:true:false', 'showPanel']),
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('zommi-composer')))
            .focusNode
            ?.hasFocus,
        isTrue,
      );

      desktop.emit(
        DesktopInvocation(
          kind: DesktopInvocationKind.context,
          attachment: _browserAttachment('capture-2'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('[example.com 2]'), findsOneWidget);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(
        tester.getCenter(find.byKey(const ValueKey('attachment-capture-1'))),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('context-preview')), findsOneWidget);
      expect(find.textContaining('PRIMARY SURFACE SELECTION'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('zommi-composer')),
        'compare captures',
      );
      await tester.tap(find.byKey(const ValueKey('send-message')));
      await tester.pumpAndSettle();
      expect(core.lastMessage, 'compare captures');
      expect(core.lastSnapshots, hasLength(2));
      expect(core.lastImages, isEmpty);
    },
  );

  testWidgets(
    'explicit image selection keeps pointer context and can be removed',
    (tester) async {
      final core = RichFakeCore()..historyCount = 0;
      final desktop = FakeDesktopBridge()
        ..nextImage = ContextAttachment(
          id: 'image-1',
          token: '',
          snapshot: _browserAttachment('pointer').snapshot,
          previewText: 'Pointer context beside image',
          imageDataUrl: _onePixelPng,
          bounds: const {'x': 10, 'y': 20, 'width': 1, 'height': 1},
        );
      await _pumpApp(tester, core: core, desktop: desktop);
      await _expand(tester);

      await tester.tap(find.byKey(const ValueKey('select-image')));
      await tester.pumpAndSettle();
      expect(desktop.calls, contains('selectImage:false'));
      expect(find.text('[image]'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('zommi-composer')),
        'inspect the image',
      );
      await tester.tap(find.byKey(const ValueKey('send-message')));
      await tester.pumpAndSettle();
      expect(core.lastSnapshots, hasLength(1));
      expect(core.lastImages, [_onePixelPng]);

      desktop.emit(
        DesktopInvocation(
          kind: DesktopInvocationKind.image,
          attachment: desktop.nextImage,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove [image]'));
      await tester.pump();
      expect(find.byKey(const ValueKey('attachment-image-1')), findsNothing);
    },
  );

  testWidgets(
    'runtime, model, effort, and provider-owned sessions stay exact',
    (tester) async {
      final core = RichFakeCore()..historyCount = 0;
      final desktop = FakeDesktopBridge();
      await _pumpApp(tester, core: core, desktop: desktop);
      await _expand(tester);

      await tester.tap(find.byKey(const ValueKey('runtime-summary')));
      await tester.pumpAndSettle();
      expect(find.text('Codex app-server · Linux'), findsOneWidget);
      expect(find.text('Pi RPC · WSL · Ubuntu'), findsOneWidget);
      expect(find.text('Compatible'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('runtime-runtime-pi')));
      await tester.pumpAndSettle();
      expect(core.activeTargetId, 'runtime-pi');
      expect(find.textContaining('Pi 9.8.7 ready'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('model-summary')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('model-search')),
        'Mini',
      );
      await tester.pump();
      expect(find.text('Fixture Mini'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('model-fixture-mini')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('effort-medium')));
      await tester.pump();
      expect(find.textContaining('Fixture Mini · Medium'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('toggle-sessions')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('session-sidebar')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('session-sidebar'))).height,
        lessThan(expandedPanelHeight / 2),
      );
      await tester.tap(find.byKey(const ValueKey('session-session-2')));
      await tester.pumpAndSettle();
      expect(core.activeSessionId, 'session-2');
      expect(find.byKey(const ValueKey('session-sidebar')), findsNothing);
    },
  );

  testWidgets(
    'advanced runtime overrides use host paths or credential-free endpoints',
    (tester) async {
      final core = RichFakeCore()..historyCount = 0;
      await _pumpApp(tester, core: core, desktop: FakeDesktopBridge());
      await _expand(tester);
      await tester.tap(find.byKey(const ValueKey('runtime-summary')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Advanced overrides'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('runtime-override-override-existing')),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (widget) => widget is TextField && widget.obscureText,
        ),
        findsNothing,
      );
      await tester.enterText(
        find.byKey(const ValueKey('runtime-override-locator')),
        '/custom/codex',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('save-runtime-override')));
      await tester.pumpAndSettle();
      expect(
        core.configuredOverrides.any(
          (value) => value['executablePath'] == '/custom/codex',
        ),
        isTrue,
      );

      await tester.tap(find.byKey(const ValueKey('runtime-override-adapter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OpenClaw · Direct Gateway').last);
      await tester.pumpAndSettle();
      expect(find.text('Gateway endpoint'), findsOneWidget);
      expect(find.byKey(const ValueKey('runtime-override-host')), findsNothing);
    },
  );

  testWidgets('authentication failure exposes runtime-owned sign-in action', (
    tester,
  ) async {
    final core = RichFakeCore()
      ..historyCount = 0
      ..connectErrorCode = 'authentication-required';
    final desktop = FakeDesktopBridge();
    await _pumpApp(tester, core: core, desktop: desktop);
    await _expand(tester);
    expect(find.text('Codex sign-in required'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('runtime-summary')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('runtime-sign-in')));
    await tester.pump();
    expect(desktop.calls, contains('signIn:runtime-codex'));
  });

  testWidgets('blank titlebar space starts native window drag', (tester) async {
    final core = RichFakeCore()..historyCount = 0;
    final desktop = FakeDesktopBridge();
    await _pumpApp(tester, core: core, desktop: desktop);
    await _expand(tester);
    await tester.drag(
      find.byKey(const ValueKey('window-drag-region')),
      const Offset(40, -20),
    );
    await tester.pump();
    expect(desktop.calls, contains('startDragging'));
  });

  testWidgets(
    'thinking, tools, markdown, artifacts, approvals, and questions render once',
    (tester) async {
      final core = RichFakeCore()..historyCount = 0;
      final desktop = FakeDesktopBridge();
      await _pumpApp(
        tester,
        core: core,
        desktop: desktop,
        artifactLoader: FakeArtifactLoader(),
      );
      await _expand(tester);
      await tester.enterText(
        find.byKey(const ValueKey('zommi-composer')),
        'stream please',
      );
      await tester.tap(find.byKey(const ValueKey('send-message')));
      await tester.pumpAndSettle();

      core.emit(
        _event(
          1,
          'turn.started',
          turnId: 'session-1-live-turn',
          payload: const {'status': 'inProgress'},
        ),
      );
      core.emit(
        _event(
          2,
          'item.update',
          turnId: 'session-1-live-turn',
          payload: const {
            'kind': 'thinking',
            'lifecycle': 'delta',
            'title': 'Thinking',
            'text': 'Reading the selected table.',
            'itemId': 'thinking-a',
          },
        ),
      );
      core.emit(
        _event(
          3,
          'item.update',
          turnId: 'session-1-live-turn',
          payload: const {
            'kind': 'thinking',
            'lifecycle': 'completed',
            'title': 'Thinking',
            'text': 'Reading the selected table.',
            'itemId': 'thinking-b',
          },
        ),
      );
      core.emit(
        _event(
          4,
          'item.update',
          turnId: 'session-1-live-turn',
          payload: const {
            'kind': 'tool',
            'lifecycle': 'completed',
            'title': 'Command',
            'text': 'rg selected',
            'itemId': 'tool-1',
          },
        ),
      );
      core.emit(
        _event(
          5,
          'item.update',
          turnId: 'session-1-live-turn',
          payload: const {
            'kind': 'assistant',
            'lifecycle': 'completed',
            'title': 'Codex',
            'text': '## Result\n\n- first\n- second\n\n```text\ncopy me\n```',
            'itemId': 'answer-1',
            'artifacts': [
              {
                'id': 'html-1',
                'kind': 'html',
                'title': 'Generated report',
                'path': 'report.html',
              },
              {
                'id': 'image-artifact-1',
                'kind': 'image',
                'title': 'Generated image',
                'dataUrl': _onePixelPng,
              },
            ],
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('activity-turn-thinking')),
        findsOneWidget,
      );
      expect(find.text('Reading the selected table.'), findsOneWidget);
      expect(find.byKey(const ValueKey('activity-tool-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('assistant-answer-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('artifact-html-1')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('artifact-image-artifact-1')),
        findsOneWidget,
      );
      expect(find.byTooltip('Copy code'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('Copy code'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Copy code'));
      await tester.pump();
      expect(desktop.copiedText, contains('copy me'));
      final copyImageButton = tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip('Copy image'),
          matching: find.byType(IconButton),
        ),
      );
      copyImageButton.onPressed!();
      await tester.pump();
      expect(desktop.copiedImage, _onePixelPng);
      final htmlPreviewButton = tester.widget<TextButton>(
        find.descendant(
          of: find.byKey(const ValueKey('artifact-html-1')),
          matching: find.widgetWithText(TextButton, 'Preview'),
        ),
      );
      htmlPreviewButton.onPressed!();
      await tester.pumpAndSettle();
      final viewer = find.byKey(const ValueKey('artifact-viewer'));
      expect(viewer, findsOneWidget);
      expect(
        tester.getTopLeft(viewer).dy,
        greaterThanOrEqualTo(
          tester
              .getBottomLeft(find.byKey(const ValueKey('runtime-summary')))
              .dy,
        ),
      );
      await tester.tap(find.byTooltip('Close artifact preview'));
      await tester.pumpAndSettle();

      core.emit(
        _event(
          6,
          'approval.requested',
          payload: const {
            'approvalId': 'approval-1',
            'toolCall': {
              'title': 'Run command',
              'rawInput': {'cmd': 'cargo test'},
            },
            'options': [
              {
                'optionId': 'allow-once',
                'name': 'Allow once',
                'kind': 'allow_once',
              },
              {'optionId': 'deny', 'name': 'Deny', 'kind': 'reject'},
            ],
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel(RegExp('Agent requests permission')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('approval-allow-once')));
      await tester.pumpAndSettle();
      expect(core.approvalResolution, (
        'runtime-codex',
        'session-1',
        'approval-1',
        'allow-once',
      ));

      core.emit(
        _event(
          7,
          'question.requested',
          payload: const {
            'questionId': 'question-1',
            'title': 'Choose delivery',
            'questions': [
              {
                'questionId': 'speed',
                'header': 'Speed',
                'question': 'How quickly?',
                'options': [
                  {'label': 'Fast', 'description': 'Ship now'},
                  {'label': 'Careful', 'description': 'More checks'},
                ],
                'multiSelect': false,
                'isOther': true,
              },
            ],
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel(RegExp('Agent asks a question')),
        findsOneWidget,
      );
      await tester.tap(find.text('Fast'));
      await tester.tap(find.byKey(const ValueKey('question-submit')));
      await tester.pumpAndSettle();
      expect(core.questionResolution?.$3, 'question-1');
      expect(core.questionResolution?.$4, {
        'answers': {
          'speed': ['Fast'],
        },
      });

      core.emit(
        _event(
          8,
          'turn.completed',
          turnId: 'session-1-live-turn',
          payload: const {'status': 'completed'},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('stop-turn')), findsNothing);
      expect(find.text('Codex reply complete'), findsOneWidget);
    },
  );

  testWidgets(
    'long canonical history loads in bounded pages without losing the first turn',
    (tester) async {
      final core = RichFakeCore()..historyCount = 50;
      await _pumpApp(tester, core: core, desktop: FakeDesktopBridge());
      await _expand(tester);

      expect(
        find.byKey(const ValueKey('user-message-session-1-turn-50')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('user-message-session-1-turn-1')),
        findsNothing,
      );
      final transcript = find.byKey(const ValueKey('zommi-transcript'));
      for (var page = 0; page < 4; page++) {
        await tester.drag(transcript, const Offset(0, 2400));
        await tester.pumpAndSettle();
        if (page == 0) {
          expect(
            tester
                .widget<IconButton>(
                  find.byKey(const ValueKey('scroll-to-latest')),
                )
                .onPressed,
            isNotNull,
          );
        }
      }
      expect(
        find.byKey(const ValueKey('user-message-session-1-turn-1')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('scroll-to-latest')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('user-message-session-1-turn-50')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'compact orb stays active while any background session is running',
    (tester) async {
      final core = RichFakeCore()..historyCount = 0;
      await _pumpApp(tester, core: core, desktop: FakeDesktopBridge());

      core.emit(
        _event(
          1,
          'turn.started',
          sessionId: 'session-2',
          turnId: 'background-turn',
          payload: const {'status': 'inProgress'},
        ),
      );
      await tester.pump();
      expect(tester.widget<ZommiOrb>(find.byType(ZommiOrb)).working, isTrue);

      core.emit(
        _event(
          2,
          'turn.completed',
          sessionId: 'session-2',
          turnId: 'background-turn',
          payload: const {'status': 'completed'},
        ),
      );
      await tester.pump();
      expect(tester.widget<ZommiOrb>(find.byType(ZommiOrb)).working, isFalse);
    },
  );

  testWidgets(
    'background completion becomes unread and exact interruption is preserved',
    (tester) async {
      final core = RichFakeCore()..historyCount = 0;
      await _pumpApp(tester, core: core, desktop: FakeDesktopBridge());
      await _expand(tester);
      core.emit(
        _event(
          1,
          'turn.started',
          sessionId: 'session-2',
          turnId: 'background-turn',
          payload: const {'status': 'inProgress'},
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('toggle-sessions')));
      await tester.pump();
      expect(
        find.bySemanticsLabel('Secondary chat, running session'),
        findsOneWidget,
      );

      core.emit(
        _event(
          2,
          'turn.completed',
          sessionId: 'session-2',
          turnId: 'background-turn',
          payload: const {'status': 'completed'},
        ),
      );
      await tester.pump();
      expect(
        find.bySemanticsLabel('Secondary chat, unread session'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('session-session-2')));
      await tester.pumpAndSettle();
      core.emit(
        _event(
          3,
          'turn.started',
          sessionId: 'session-2',
          turnId: 'exact-turn-2',
          payload: const {'status': 'inProgress'},
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('stop-turn')));
      await tester.pump();
      expect(core.interrupted, ('runtime-codex', 'session-2', 'exact-turn-2'));
    },
  );
}

Future<void> _pumpApp(
  WidgetTester tester, {
  required RichFakeCore core,
  required FakeDesktopBridge desktop,
  FakeArtifactLoader? artifactLoader,
}) async {
  await tester.binding.setSurfaceSize(const Size(1000, 820));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ZommiApp(core: core, desktop: desktop, artifactLoader: artifactLoader),
  );
  await tester.pumpAndSettle();
}

Future<void> _expand(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('zommi-orb')));
  await tester.pumpAndSettle();
}

ContextAttachment _browserAttachment(String id) => ContextAttachment(
  id: id,
  token: '',
  snapshot: const {
    'surfaceKind': 'Browser',
    'application': 'Edge',
    'locator': {'kind': 'URL', 'value': 'https://example.com/table'},
    'selection': ['row 7'],
  },
  previewText:
      'PRIMARY SURFACE SELECTION\nrow 7\nURL: https://example.com/table',
);

CoreEvent _event(
  int sequence,
  String name, {
  String sessionId = 'session-1',
  String? turnId,
  required Map<String, Object?> payload,
}) => CoreEvent(
  name: name,
  sequence: sequence,
  runtimeTargetId: 'runtime-codex',
  sessionId: sessionId,
  turnId: turnId,
  clientOperationId: 'flutter:test',
  payload: payload,
);
