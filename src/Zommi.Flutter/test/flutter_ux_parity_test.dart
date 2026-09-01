import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/widgets/content_views.dart';
import 'package:zommi_flutter/widgets/inline_attachment_composer.dart';
import 'package:zommi_flutter/widgets/transcript_view.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'test_support.dart';

const _onePixelPng =
    'data:image/png;base64,'
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

void main() {
  testWidgets('startup orb has visible motion until runtime is ready', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(240, 180));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final startup = Completer<void>();
    final core = RichFakeCore()
      ..historyCount = 0
      ..initializeGate = startup.future;
    await tester.pumpWidget(ZommiApp(core: core, desktop: FakeDesktopBridge()));
    await tester.pump();

    expect(tester.widget<ZommiOrb>(find.byType(ZommiOrb)).loading, isTrue);
    final canvas = find.byKey(const ValueKey('zommi-orb-canvas'));
    final firstPainter = tester.widget<CustomPaint>(canvas).painter;
    await tester.pump(const Duration(milliseconds: 180));
    final secondPainter = tester.widget<CustomPaint>(canvas).painter;
    expect(secondPainter, isNot(same(firstPainter)));
    expect(secondPainter!.shouldRepaint(firstPainter!), isTrue);

    startup.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<ZommiOrb>(find.byType(ZommiOrb)).loading, isFalse);
  });

  testWidgets('native resize renders only the lightweight morph surface', (
    tester,
  ) async {
    final core = RichFakeCore()..historyCount = 0;
    final desktop = FakeDesktopBridge();
    await _pumpApp(tester, core: core, desktop: desktop);
    final resizeGate = Completer<void>();
    desktop.surfaceGate = resizeGate.future;

    await tester.tap(find.byKey(const ValueKey('zommi-orb')));
    await tester.pump();
    expect(find.byKey(const ValueKey('surface-transition')), findsOneWidget);
    expect(find.byKey(const ValueKey('zommi-transcript')), findsNothing);
    expect(find.byKey(const ValueKey('zommi-composer')), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('zommi-surface'))),
      const Size(expandedPanelWidth, expandedPanelHeight),
    );

    resizeGate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('surface-transition')), findsNothing);
    expect(find.byKey(const ValueKey('zommi-composer')), findsOneWidget);
  });

  testWidgets('single-line and fenced markdown copy controls never overlap', (
    tester,
  ) async {
    const singleLine = 'A concise answer';
    Future<void> pumpMarkdown(String text) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: CopyableMarkdown(text: text, onCopy: (_) async {}),
          ),
        ),
      ),
    );

    await pumpMarkdown(singleLine);
    await tester.pump();
    final responseCopy = find.byKey(ValueKey('copy-${singleLine.hashCode}'));
    final layout = find.byKey(ValueKey('copy-layout-${singleLine.hashCode}'));
    final responseCopyRect = tester.getRect(responseCopy);
    final layoutRect = tester.getRect(layout);
    expect(tester.getSize(responseCopy), const Size(30, 30));
    expect(responseCopyRect.top, greaterThanOrEqualTo(layoutRect.top));
    expect(responseCopyRect.bottom, lessThanOrEqualTo(layoutRect.bottom));

    const fenced = '```text\ncopy me\n```';
    await pumpMarkdown(fenced);
    await tester.pump();
    final fencedResponseCopy = find.byKey(ValueKey('copy-${fenced.hashCode}'));
    final codeCopy = find.byTooltip('Copy code');
    expect(
      tester.getRect(fencedResponseCopy).overlaps(tester.getRect(codeCopy)),
      isFalse,
    );
    final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    final codeDecoration = markdown.styleSheet?.codeblockDecoration;
    expect(codeDecoration, isA<BoxDecoration>());
    final codeBoxDecoration = codeDecoration! as BoxDecoration;
    expect(codeBoxDecoration.color, isNull);
    expect(codeBoxDecoration.border, isNull);
  });

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
      await tester.pump();

      expect(find.byKey(const ValueKey('zommi-composer')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('inline-attachment-capture-1')),
        findsOneWidget,
      );
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
      expect(
        find.byKey(const ValueKey('inline-attachment-capture-2')),
        findsOneWidget,
      );

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(
        tester.getCenter(
          find.byKey(const ValueKey('inline-attachment-capture-1')),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('context-preview')), findsOneWidget);
      expect(find.textContaining('PRIMARY SURFACE SELECTION'), findsOneWidget);

      _appendComposerText(tester, 'compare captures');
      await tester.tap(find.byKey(const ValueKey('send-message')));
      await tester.pump();
      expect(core.lastMessage, 'compare captures');
      expect(core.lastSnapshots, hasLength(2));
      expect(core.lastImages, isEmpty);
    },
  );

  testWidgets(
    'image previews stay inline at the cursor, submit in order, and can be removed',
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

      await tester.enterText(
        find.byKey(const ValueKey('zommi-composer')),
        'hey i own ',
      );
      await tester.tap(find.byKey(const ValueKey('select-image')));
      await tester.pumpAndSettle();
      expect(desktop.calls, contains('selectImage:false'));
      expect(
        find.byKey(const ValueKey('inline-image-image-1')),
        findsOneWidget,
      );
      expect(find.text('[image]'), findsNothing);
      expect(find.byKey(const ValueKey('context-chips')), findsNothing);

      _appendComposerText(tester, " and i'd like to consider to buy ");
      desktop.nextImage = ContextAttachment(
        id: 'image-2',
        token: '',
        imageDataUrl: _onePixelPng,
      );
      await tester.tap(find.byKey(const ValueKey('select-image')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('inline-image-image-2')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('send-message')));
      await tester.pump();
      expect(core.lastMessage, "hey i own and i'd like to consider to buy");
      expect(core.lastSnapshots, hasLength(1));
      expect(core.lastImages, [_onePixelPng, _onePixelPng]);
      expect(find.byType(InlineAttachmentMessage), findsOneWidget);
      expect(
        find.byKey(const ValueKey('sent-inline-image-image-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('sent-inline-image-image-2')),
        findsOneWidget,
      );
      expect(find.text('[image]'), findsNothing);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(
        tester.getCenter(
          find.byKey(const ValueKey('sent-inline-image-image-1')),
        ),
      );
      await tester.pump();
      final preview = find.byKey(const ValueKey('context-preview'));
      expect(preview, findsOneWidget);
      final previewOrigin = tester.getTopLeft(preview);
      await mouse.moveTo(tester.getCenter(preview));
      await tester.pump(const Duration(milliseconds: 300));
      expect(preview, findsOneWidget);
      expect(tester.getTopLeft(preview), previewOrigin);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('context-preview-image-frame')))
            .height,
        220,
      );

      desktop.emit(
        DesktopInvocation(
          kind: DesktopInvocationKind.image,
          attachment: desktop.nextImage,
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('zommi-composer')));
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('inline-attachment-image-2')),
        findsNothing,
      );
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

      final switchGate = Completer<void>();
      core.connectGate = switchGate.future;
      await tester.tap(find.byKey(const ValueKey('runtime-runtime-pi')));
      await tester.pump();
      expect(find.byKey(const ValueKey('runtime-panel')), findsNothing);
      expect(
        find.byKey(const ValueKey('runtime-loading-indicator')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('loading-status')), findsOneWidget);
      expect(core.activeTargetId, 'runtime-codex');
      switchGate.complete();
      await tester.pumpAndSettle();
      expect(core.activeTargetId, 'runtime-pi');
      expect(find.textContaining('Pi 9.8.7 ready'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('model-summary')));
      await tester.pumpAndSettle();
      final reasoningRow = find.byKey(const ValueKey('reasoning-options-row'));
      expect(reasoningRow, findsOneWidget);
      expect(tester.getSize(reasoningRow).height, lessThan(34));
      final effortTopEdges = ['low', 'medium', 'high', 'xhigh']
          .map(
            (effort) =>
                tester.getTopLeft(find.byKey(ValueKey('effort-$effort'))).dy,
          )
          .toSet();
      expect(effortTopEdges, hasLength(1));
      await tester.enterText(
        find.byKey(const ValueKey('model-search')),
        'Mini',
      );
      await tester.pump();
      expect(find.text('Fixture Mini'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('Fixture Mini')).style?.fontSize,
        lessThanOrEqualTo(11.5),
      );
      await tester.tap(find.byKey(const ValueKey('model-fixture-mini')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('effort-medium')));
      await tester.pump();
      expect(find.textContaining('Fixture Mini · Medium'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('toggle-sessions')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('session-sidebar')), findsOneWidget);
      final sessionPanelSize = tester.getSize(
        find.byKey(const ValueKey('session-sidebar')),
      );
      expect(sessionPanelSize.width, expandedPanelWidth / 2);
      expect(sessionPanelSize.height, greaterThan(expandedPanelHeight / 2));
      await tester.tap(find.byKey(const ValueKey('session-session-2')));
      await tester.pumpAndSettle();
      expect(core.activeSessionId, 'session-2');
      expect(find.byKey(const ValueKey('session-sidebar')), findsNothing);
    },
  );

  testWidgets('runtime, model, and session overlays dismiss on outside click', (
    tester,
  ) async {
    final core = RichFakeCore()..historyCount = 0;
    await _pumpApp(tester, core: core, desktop: FakeDesktopBridge());
    await _expand(tester);
    final composer = find.byKey(const ValueKey('zommi-composer'));

    await tester.tap(find.byKey(const ValueKey('runtime-summary')));
    await tester.pump();
    expect(find.byKey(const ValueKey('runtime-panel')), findsOneWidget);
    await tester.tap(composer);
    await tester.pump();
    expect(find.byKey(const ValueKey('runtime-panel')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('model-summary')));
    await tester.pump();
    expect(find.byKey(const ValueKey('model-panel')), findsOneWidget);
    await tester.tap(composer);
    await tester.pump();
    expect(find.byKey(const ValueKey('model-panel')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('toggle-sessions')));
    await tester.pump();
    expect(find.byKey(const ValueKey('session-sidebar')), findsOneWidget);
    await tester.tap(composer);
    await tester.pump();
    expect(find.byKey(const ValueKey('session-sidebar')), findsNothing);
  });

  testWidgets('large panel stays large when the window is shown again', (
    tester,
  ) async {
    final core = RichFakeCore()..historyCount = 0;
    final desktop = FakeDesktopBridge();
    await _pumpApp(tester, core: core, desktop: desktop);
    await _expand(tester);
    desktop.calls.clear();

    await tester.tap(find.byKey(const ValueKey('expand-zommi')));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const ValueKey('zommi-surface'))),
      largeWindowSize,
    );
    expect(desktop.calls, contains('surface:true:true'));

    desktop.emit(const DesktopInvocation(kind: DesktopInvocationKind.open));
    await tester.pumpAndSettle();
    expect(
      desktop.calls,
      containsAllInOrder(['surface:true:true', 'showPanel']),
    );
    expect(
      desktop.calls.where((call) => call == 'surface:true:true'),
      hasLength(1),
    );
    expect(desktop.calls, isNot(contains('surface:true:false')));
    expect(
      tester.getSize(find.byKey(const ValueKey('zommi-surface'))),
      largeWindowSize,
    );
  });

  testWidgets(
    'chat typography stays readable without changing composer layout',
    (tester) async {
      final core = RichFakeCore()..historyCount = 0;
      await _pumpApp(tester, core: core, desktop: FakeDesktopBridge());
      await _expand(tester);
      await tester.enterText(
        find.byKey(const ValueKey('zommi-composer')),
        'compact type',
      );
      await tester.tap(find.byKey(const ValueKey('send-message')));
      await tester.pump();
      core.emit(
        _event(
          1,
          'item.update',
          payload: const {
            'kind': 'assistant',
            'lifecycle': 'delta',
            'text': '# Compact heading\nReadable body',
            'itemId': 'answer',
          },
        ),
      );
      await tester.pump();

      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('zommi-composer')),
      );
      expect(field.style?.fontSize, 12);
      expect(field.textAlignVertical, TextAlignVertical.center);
      final markdown = tester.widgetList<MarkdownBody>(
        find.byType(MarkdownBody),
      );
      expect(markdown, isNotEmpty);
      final bodySizes = markdown
          .map((body) => body.styleSheet?.p?.fontSize)
          .whereType<double>()
          .toSet();
      expect(bodySizes, containsAll(<double>[12, 13]));
    },
  );

  testWidgets('expanded header does not repeat the compact orb', (
    tester,
  ) async {
    final core = RichFakeCore()..historyCount = 0;
    await _pumpApp(tester, core: core, desktop: FakeDesktopBridge());
    await _expand(tester);
    await tester.enterText(
      find.byKey(const ValueKey('zommi-composer')),
      'please think',
    );
    await tester.tap(find.byKey(const ValueKey('send-message')));
    await tester.pump();

    expect(find.byKey(const ValueKey('panel-orb')), findsNothing);
    expect(find.byType(ZommiOrb), findsNothing);
    expect(find.byKey(const ValueKey('stop-turn')), findsOneWidget);
  });

  test('duplicate assistant blocks collapse to one visible message', () {
    final blocks = [
      TranscriptBlock(
        id: 'first',
        kind: TranscriptKind.assistant,
        title: 'Codex',
        text: 'same answer',
      ),
      TranscriptBlock(
        id: 'second',
        kind: TranscriptKind.assistant,
        title: 'Codex',
        text: 'same answer',
      ),
      TranscriptBlock(
        id: 'tool',
        kind: TranscriptKind.tool,
        title: 'Tool',
        text: 'same answer',
      ),
    ];
    expect(distinctTranscriptBlocks(blocks), [blocks.first, blocks.last]);
  });

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
      await tester.pump();

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
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

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
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byTooltip('Copy code'));
      await tester.pump();
      expect(desktop.copiedText, contains('copy me'));
      await tester.pump(const Duration(seconds: 1));
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
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
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
      await tester.pump();

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
      await tester.pump();
      expect(
        find.bySemanticsLabel(RegExp('Agent requests permission')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('approval-allow-once')));
      await tester.pump();
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
      await tester.pump();
      expect(
        find.bySemanticsLabel(RegExp('Agent asks a question')),
        findsOneWidget,
      );
      await tester.tap(find.text('Fast'));
      await tester.tap(find.byKey(const ValueKey('question-submit')));
      await tester.pump();
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
          final latest = find.byKey(const ValueKey('scroll-to-latest'));
          expect(tester.widget<IconButton>(latest).onPressed, isNotNull);
          expect(
            tester.getCenter(latest).dx,
            closeTo(tester.getCenter(find.byType(TranscriptPane)).dx, 0.01),
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

void _appendComposerText(WidgetTester tester, String value) {
  final field = tester.widget<TextField>(
    find.byKey(const ValueKey('zommi-composer')),
  );
  final controller = field.controller!;
  final updated = '${controller.text}$value';
  controller.value = controller.value.copyWith(
    text: updated,
    selection: TextSelection.collapsed(offset: updated.length),
    composing: TextRange.empty,
  );
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
