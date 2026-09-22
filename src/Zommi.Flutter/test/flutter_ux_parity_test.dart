import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/theme/app_preferences.dart';
import 'package:zommi_flutter/widgets/content_views.dart';
import 'package:zommi_flutter/widgets/inline_attachment_composer.dart';
import 'package:zommi_flutter/widgets/transcript_view.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'golden_support.dart';
import 'test_support.dart';

const _onePixelPng =
    'data:image/png;base64,'
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

void main() {
  testWidgets(
    'startup uses a full taskbar window with a clear progress indicator',
    (tester) async {
      await tester.binding.setSurfaceSize(normalWindowSize);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final startup = Completer<void>();
      final core = RichFakeCore()
        ..historyCount = 0
        ..initializeGate = startup.future;
      await tester.pumpWidget(
        ZommiApp(core: core, desktop: FakeDesktopBridge()),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('zommi-orb')), findsNothing);
      expect(find.byKey(const ValueKey('loading-indicator')), findsOneWidget);
      expect(find.byKey(const ValueKey('zommi-composer')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('zommi-surface'))),
        normalWindowSize,
      );

      startup.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('loading-indicator')), findsNothing);
    },
  );

  testWidgets('hovering away never collapses the taskbar chat into an orb', (
    tester,
  ) async {
    final desktop = FakeDesktopBridge();
    await _pumpApp(
      tester,
      core: RichFakeCore()..historyCount = 0,
      desktop: desktop,
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: normalWindowSize.center(Offset.zero));
    await mouse.moveTo(const Offset(-10, -10));
    await tester.pump(const Duration(seconds: 1));

    expect(find.byKey(const ValueKey('zommi-orb')), findsNothing);
    expect(find.byKey(const ValueKey('zommi-composer')), findsOneWidget);
    expect(
      desktop.calls.where((call) => call == 'surface:false:false'),
      isEmpty,
    );
  });

  testWidgets('native resizing keeps the same transcript element mounted', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(normalWindowSize);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final core = RichFakeCore()..historyCount = 24;
    await tester.pumpWidget(ZommiApp(core: core, desktop: FakeDesktopBridge()));
    await tester.pumpAndSettle();
    final transcript = tester.element(find.byType(TranscriptPane));

    await tester.binding.setSurfaceSize(largeWindowSize);
    await tester.pump();

    expect(
      identical(tester.element(find.byType(TranscriptPane)), transcript),
      isTrue,
    );
    expect(find.byKey(const ValueKey('surface-transition')), findsNothing);
    expect(find.byKey(const ValueKey('zommi-orb')), findsNothing);
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
            child: CopyableMarkdown(
              text: text,
              onCopy: (_) async {},
              onOpenLink: (_) async {},
            ),
          ),
        ),
      ),
    );

    await pumpMarkdown(singleLine);
    await tester.pump();
    final responseCopy = find.byKey(ValueKey('copy-${singleLine.hashCode}'));
    final layout = find.byKey(const ValueKey('copy-layout'));
    final responseCopyRect = tester.getRect(responseCopy);
    final layoutRect = tester.getRect(layout);
    final singleLineMarkdown = tester.getRect(
      find.byWidgetPredicate((widget) => widget is MarkdownBody),
    );
    expect(tester.getSize(responseCopy), const Size(24, 24));
    expect(tester.getSize(layout).height, 24);
    expect(singleLineMarkdown.center.dy, closeTo(layoutRect.center.dy, 0.01));
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
  });

  testWidgets('single-line user and agent message boxes stay compact', (
    tester,
  ) async {
    final core = RichFakeCore()..historyCount = 0;
    await _pumpApp(tester, core: core, desktop: FakeDesktopBridge());
    await tester.enterText(
      find.byKey(const ValueKey('zommi-composer')),
      'one line',
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
          'text': 'one line back',
          'itemId': 'single-line-answer',
        },
      ),
    );
    await tester.pump();

    final user = find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('user-message-'),
    );
    final assistant = find.byKey(
      const ValueKey('assistant-single-line-answer'),
    );
    expect(tester.getSize(user).height, lessThanOrEqualTo(36));
    expect(tester.getSize(assistant).height, lessThanOrEqualTo(36));
    expect(
      tester
          .getCenter(
            find.descendant(
              of: user,
              matching: find.byWidgetPredicate(
                (widget) => widget is MarkdownBody,
              ),
            ),
          )
          .dy,
      closeTo(tester.getCenter(user).dy, 0.01),
    );
    expect(
      tester
          .getCenter(
            find.descendant(
              of: assistant,
              matching: find.byWidgetPredicate(
                (widget) => widget is MarkdownBody,
              ),
            ),
          )
          .dy,
      closeTo(tester.getCenter(assistant).dy, 0.01),
    );
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
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('zommi-composer')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('inline-attachment-capture-1')),
        findsOneWidget,
      );
      expect(desktop.calls, contains('showPanel'));
      expect(
        desktop.calls.where((call) => call == 'surface:false:false'),
        isEmpty,
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
      expect(find.textContaining('PRIMARY SURFACE SELECTION'), findsNothing);
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
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
      await _selectImageFromComposer(tester, desktop);
      await tester.pumpAndSettle();
      expect(desktop.calls, contains('selectPointerContext'));
      expect(
        find.byKey(const ValueKey('inline-image-image-1')),
        findsOneWidget,
      );
      expect(find.text('[image]'), findsNothing);
      expect(find.text('Selected image'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(InlineAttachmentTile),
          matching: find.text('A.'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('context-chips')), findsNothing);

      _appendComposerText(tester, " and i'd like to consider to buy ");
      desktop.nextImage = ContextAttachment(
        id: 'image-2',
        token: '',
        imageDataUrl: _onePixelPng,
      );
      await _selectImageFromComposer(tester, desktop);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('inline-image-image-2')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('send-message')));
      await tester.pump();
      expect(core.lastMessage, "hey i own and i'd like to consider to buy");
      expect(core.lastSnapshots, hasLength(2));
      expect(core.lastImages, [_onePixelPng, _onePixelPng]);
      expect(find.byType(InlineAttachmentMessage), findsOneWidget);
      final message = tester.widget<RichText>(
        find
            .descendant(
              of: find.byType(InlineAttachmentMessage),
              matching: find.byType(RichText),
            )
            .first,
      );
      final composer = tester.widget<TextField>(
        find.byKey(const ValueKey('zommi-composer')),
      );
      expect(message.text.style?.fontWeight, FontWeight.w400);
      expect(message.text.style?.fontWeight, composer.style?.fontWeight);
      expect(message.text.style?.fontSize, composer.style?.fontSize);
      expect(message.text.style?.fontFamily, composer.style?.fontFamily);
      expect(
        find.byKey(const ValueKey('sent-inline-image-image-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('sent-inline-image-image-2')),
        findsOneWidget,
      );
      expect(find.text('[image]'), findsNothing);
      expect(find.text('Selected image'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(InlineAttachmentTile),
          matching: find.byType(Text),
        ),
        findsNWidgets(2),
      );
      expect(find.text('A.'), findsOneWidget);
      expect(find.text('B.'), findsOneWidget);

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

  testWidgets('one visible content entry captures without a mode menu', (
    tester,
  ) async {
    final desktop = FakeDesktopBridge()
      ..nextContext = _browserAttachment('menu-context');
    await _pumpApp(
      tester,
      core: RichFakeCore()..historyCount = 0,
      desktop: desktop,
    );

    await tester.tap(find.byKey(const ValueKey('select-content')));
    await tester.pumpAndSettle();
    expect(
      desktop.calls,
      containsAllInOrder(['selectPointerContext', 'showPanel']),
    );
    expect(
      desktop.calls.where((call) => call.startsWith('selectImage:')),
      isEmpty,
    );
    expect(
      find.byKey(const ValueKey('inline-attachment-menu-context')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('zommi-composer')))
          .focusNode
          ?.hasFocus,
      isTrue,
    );
  });

  testWidgets(
    'runtime, model, effort, and provider-owned sessions stay exact',
    (tester) async {
      final core = RichFakeCore()..historyCount = 0;
      core.discoveredTargets.add(
        const RuntimeTarget(
          id: 'runtime-not-detected',
          runtimeId: 'missing',
          adapterId: 'pi-rpc',
          displayName: 'Not detected',
          protocolName: 'Pi RPC',
          executablePath: '/missing/pi',
          executionHost: {'id': 'native:linux', 'kind': 'native'},
          status: 'unavailable',
        ),
      );
      final desktop = FakeDesktopBridge();
      await _pumpApp(tester, core: core, desktop: desktop);
      await _expand(tester);

      await _openNewChatMenu(tester);
      await tester.pumpAndSettle();
      expect(find.text('Codex app-server · Linux'), findsOneWidget);
      expect(find.text('Pi RPC · WSL · Ubuntu'), findsOneWidget);
      expect(find.text('New chats unavailable'), findsOneWidget);
      expect(find.text('Not detected'), findsNothing);

      final switchGate = Completer<void>();
      core.createSessionGate = switchGate.future;
      await tester.tap(find.byKey(const ValueKey('create-session-runtime-pi')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('runtime-panel')), findsNothing);
      expect(
        find.byKey(const ValueKey('session-loading-indicator')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('loading-status')), findsNothing);
      expect(core.activeTargetId, 'runtime-codex');
      switchGate.complete();
      await tester.pumpAndSettle();
      expect(core.activeTargetId, 'runtime-pi');
      expect(find.byKey(const ValueKey('core-status')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('model-summary')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('model-settings-panel')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('settings-model')), findsNothing);
      expect(find.byKey(const ValueKey('settings-back')), findsNothing);
      final reasoningRow = find.byKey(const ValueKey('reasoning-options-row'));
      expect(reasoningRow, findsOneWidget);
      final effortTopEdges = ['low', 'medium', 'high', 'xhigh']
          .map(
            (effort) =>
                tester.getTopLeft(find.byKey(ValueKey('effort-$effort'))).dy,
          )
          .toSet();
      expect(effortTopEdges, hasLength(1));
      expect(find.byKey(const ValueKey('model-search')), findsNothing);
      expect(find.text('Frontier coding model'), findsNothing);
      expect(find.text('Fast agent model'), findsNothing);
      expect(find.text('Fixture Mini'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('model-fixture-mini')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('effort-medium')));
      await tester.pump();
      expect(find.textContaining('Fixture Mini · Medium'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('zommi-composer')));
      await tester.pumpAndSettle();

      if (find.byKey(const ValueKey('session-sidebar')).evaluate().isEmpty) {
        await tester.tap(find.byKey(const ValueKey('toggle-sessions')));
        await tester.pumpAndSettle();
      }
      expect(find.byKey(const ValueKey('session-sidebar')), findsOneWidget);
      final sessionPanelSize = tester.getSize(
        find.byKey(const ValueKey('session-sidebar')),
      );
      final surfaceSize = tester.getSize(
        find.byKey(const ValueKey('zommi-surface')),
      );
      final sessionPanelBounds = tester.getRect(
        find.byKey(const ValueKey('session-sidebar')),
      );
      final composerBounds = tester.getRect(
        find.byKey(const ValueKey('message-composer-shell')),
      );
      expect(sessionPanelSize.width, (surfaceSize.width * .32).clamp(200, 260));
      expect(sessionPanelBounds.right, lessThanOrEqualTo(composerBounds.left));
      expect(sessionPanelBounds.overlaps(composerBounds), isFalse);
      await tester.tap(
        find.byKey(const ValueKey('session-runtime-codex-session-2')),
      );
      await tester.pumpAndSettle();
      expect(core.activeSessionId, 'session-2');
      expect(find.textContaining('Fixture Pro · High'), findsOneWidget);
      expect(find.byKey(const ValueKey('session-sidebar')), findsOneWidget);
    },
  );

  testWidgets(
    'creation and model menus dismiss on outside click while sessions stay open',
    (tester) async {
      final core = RichFakeCore()..historyCount = 0;
      await _pumpApp(tester, core: core, desktop: FakeDesktopBridge());
      await _expand(tester);
      final composer = find.byKey(const ValueKey('zommi-composer'));

      await _openNewChatMenu(tester);
      await tester.pump();
      expect(find.text('New agent'), findsOneWidget);
      await tester.tapAt(
        tester.getBottomRight(composer) - const Offset(10, 10),
      );
      await tester.pumpAndSettle();
      expect(find.text('New agent'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('model-summary')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('model-settings-panel')),
        findsOneWidget,
      );
      final settingsButtonBounds = tester.getRect(
        find.byKey(const ValueKey('model-summary')),
      );
      final settingsPanelBounds = tester.getRect(
        find.byKey(const ValueKey('model-settings-panel')),
      );
      expect(settingsPanelBounds.left, closeTo(settingsButtonBounds.left, 0.1));
      expect(
        settingsPanelBounds.top,
        closeTo(settingsButtonBounds.bottom + 6, 0.1),
      );
      await tester.tap(composer);
      await tester.pump();
      expect(find.byKey(const ValueKey('model-settings-panel')), findsNothing);

      if (find.byKey(const ValueKey('session-sidebar')).evaluate().isEmpty) {
        await tester.tap(find.byKey(const ValueKey('toggle-sessions')));
        await tester.pumpAndSettle();
      }
      expect(find.byKey(const ValueKey('session-sidebar')), findsOneWidget);
      final composerBounds = tester.getRect(composer);
      await tester.tapAt(
        Offset(composerBounds.right - 12, composerBounds.center.dy),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('session-sidebar')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('toggle-sessions')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('session-sidebar')), findsNothing);
    },
  );

  testWidgets(
    'separate workspace and model settings apply per-chat Hermes values',
    (tester) async {
      const hermes = RuntimeTarget(
        id: 'runtime-hermes',
        runtimeId: 'hermes',
        adapterId: 'hermes-gateway',
        displayName: 'Hermes',
        protocolName: 'Gateway',
        executablePath: '/usr/bin/hermes',
        executionHost: {
          'id': 'native:linux',
          'kind': 'native',
          'displayName': 'Linux',
        },
        capabilityHints: RichFakeCore.capabilities,
      );
      final core = RichFakeCore()
        ..historyCount = 0
        ..activeTargetId = hermes.id
        ..discoveredTargets.add(hermes)
        ..missingWorkspaces.add('/workspace/missing');
      final desktop = FakeDesktopBridge()
        ..nextWorkspaceDirectory = '/workspace/new';
      await _pumpApp(tester, core: core, desktop: desktop);
      await _expand(tester);

      await tester.tap(find.byKey(const ValueKey('model-summary')));
      await tester.pumpAndSettle();
      final settings = find.byKey(const ValueKey('model-settings-panel'));
      expect(settings, findsOneWidget);
      expect(find.text('Model settings'), findsOneWidget);
      expect(find.text('Session settings'), findsNothing);
      expect(find.byKey(const ValueKey('settings-workspace')), findsNothing);
      expect(find.byKey(const ValueKey('settings-model')), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-profile')), findsOneWidget);
      expect(tester.getSize(settings).width, 286);
      expect(tester.getSize(settings).height, lessThan(390));

      final workspace = find.byKey(const ValueKey('workspace-summary'));
      final model = find.byKey(const ValueKey('model-summary'));
      expect(tester.getCenter(workspace).dy, tester.getCenter(model).dy);
      expect(
        tester.getRect(workspace).left,
        greaterThan(tester.getRect(model).right),
      );
      await tester.tap(workspace);
      await tester.pumpAndSettle();
      expect(settings, findsNothing);
      expect(find.byKey(const ValueKey('workspace-panel')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('workspace-path')),
        '/workspace/missing',
      );
      await tester.tap(find.byKey(const ValueKey('apply-workspace')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Folder does not exist'), findsOneWidget);
      expect(core.lastCwd, '/workspace/missing');
      expect(find.byKey(const ValueKey('workspace-panel')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('browse-workspace')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('workspace-path')))
            .controller
            ?.text,
        '/workspace/new',
      );
      expect(core.lastCwd, '/workspace/missing');
      await tester.tap(find.byKey(const ValueKey('apply-workspace')));
      await tester.pumpAndSettle();
      expect(core.lastCwd, '/workspace/new');
      expect(find.byKey(const ValueKey('workspace-panel')), findsNothing);
      expect(
        find.descendant(of: workspace, matching: find.text('new')),
        findsOneWidget,
      );
      expect(settings, findsNothing);
      await tester.tap(model);
      await tester.pumpAndSettle();
      expect(settings, findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('settings-profile')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('profile-list')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('profile-coder')));
      await tester.pumpAndSettle();
      expect(core.lastProfile, 'coder');
      expect(core.activeSessionId, 'hermes-coder-session');
      expect(find.text('coder'), findsWidgets);
    },
  );

  testWidgets('runtime list shows Hermes ACP and Gateway once each', (
    tester,
  ) async {
    const acp = RuntimeTarget(
      id: 'runtime-hermes-acp',
      runtimeId: 'hermes',
      adapterId: 'hermes-acp',
      displayName: 'Hermes',
      protocolName: 'ACP',
      capabilityHints: RichFakeCore.capabilities,
      executablePath: '/usr/bin/hermes',
      executionHost: {
        'id': 'native:linux',
        'kind': 'native',
        'displayName': 'Linux',
      },
    );
    const gateway = RuntimeTarget(
      id: 'runtime-hermes-gateway',
      runtimeId: 'hermes',
      adapterId: 'hermes-gateway',
      displayName: 'Hermes',
      protocolName: 'Gateway',
      capabilityHints: RichFakeCore.capabilities,
      executablePath: '/usr/bin/hermes',
      executionHost: {
        'id': 'native:linux',
        'kind': 'native',
        'displayName': 'Linux',
      },
    );
    final core = RichFakeCore()..historyCount = 0;
    core.discoveredTargets.addAll(const [acp, gateway, acp, gateway]);
    await _pumpApp(tester, core: core, desktop: FakeDesktopBridge());
    await _expand(tester);

    await _openNewChatMenu(tester);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('create-session-runtime-hermes-acp')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('create-session-runtime-hermes-gateway')),
      findsOneWidget,
    );
    expect(find.text('ACP · Linux'), findsOneWidget);
    expect(find.text('Gateway · Linux'), findsOneWidget);
  });

  testWidgets('Hermes model selector survives a runtime round trip', (
    tester,
  ) async {
    const hermes = RuntimeTarget(
      id: 'runtime-hermes',
      runtimeId: 'hermes',
      adapterId: 'hermes-gateway',
      displayName: 'Hermes',
      protocolName: 'Hermes Gateway',
      executablePath: '/usr/bin/hermes',
      executionHost: {
        'id': 'native:linux',
        'kind': 'native',
        'displayName': 'Linux',
      },
      capabilityHints: RichFakeCore.capabilities,
    );
    final core = RichFakeCore()
      ..historyCount = 0
      ..activeTargetId = hermes.id
      ..discoveredTargets.add(hermes)
      ..modelCatalogByRuntime[hermes.id] = RichFakeCore.models;
    await _pumpApp(tester, core: core, desktop: FakeDesktopBridge());
    await _expand(tester);
    expect(find.byKey(const ValueKey('model-summary')), findsOneWidget);

    await _openNewChatMenu(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('create-session-runtime-pi')));
    await tester.pumpAndSettle();
    core.modelCatalogByRuntime[hermes.id] = const [];
    await tester.tap(
      find.byKey(const ValueKey('session-runtime-hermes-session-1')),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('model-summary')), findsOneWidget);
    expect(find.textContaining('Fixture Pro'), findsOneWidget);
  });

  testWidgets('maximized window stays maximized when shown again', (
    tester,
  ) async {
    final core = RichFakeCore()..historyCount = 0;
    final desktop = FakeDesktopBridge();
    await _pumpApp(tester, core: core, desktop: desktop);
    await _expand(tester);
    desktop.calls.clear();
    final transcript = tester.element(find.byType(TranscriptPane));

    await tester.tap(find.byTooltip('Maximize Zommi'));
    await tester.pumpAndSettle();
    expect(desktop.calls, contains('toggleMaximized'));
    expect(
      identical(tester.element(find.byType(TranscriptPane)), transcript),
      isTrue,
    );
    expect(find.byKey(const ValueKey('surface-transition')), findsNothing);

    desktop.emit(const DesktopInvocation(kind: DesktopInvocationKind.open));
    await tester.pumpAndSettle();
    expect(desktop.calls, containsAllInOrder(['toggleMaximized', 'showPanel']));
    expect(
      desktop.calls.where((call) => call == 'toggleMaximized'),
      hasLength(1),
    );
    expect(desktop.calls, isNot(contains('surface:true:false')));
    expect(
      identical(tester.element(find.byType(TranscriptPane)), transcript),
      isTrue,
    );
  });

  testWidgets('gear opens app appearance settings and saves live choices', (
    tester,
  ) async {
    final core = RichFakeCore()..historyCount = 0;
    final desktop = FakeDesktopBridge();
    await _pumpApp(tester, core: core, desktop: desktop);

    expect(find.byKey(const ValueKey('expand-zommi')), findsNothing);
    final gear = find.byKey(const ValueKey('app-settings'));
    final gearBounds = tester.getRect(gear);
    await tester.tap(gear);
    await tester.pumpAndSettle();

    final panel = find.byKey(const ValueKey('app-settings-panel'));
    final panelBounds = tester.getRect(panel);
    expect(panelBounds.right, closeTo(gearBounds.right, 0.1));
    expect(panelBounds.top, closeTo(gearBounds.bottom + 6, 0.1));
    expect(
      find.byKey(const ValueKey('chat-font-size-control')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('theme-color-control')), findsOneWidget);

    expect(find.text('Medium'), findsNothing);
    for (final (label, size) in [('Large', 15.0), ('XL', 17.0)]) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('zommi-composer')))
            .style
            ?.fontSize,
        size,
      );
    }
    await tester.tap(find.text('Default'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('zommi-composer')))
          .style
          ?.fontSize,
      14,
    );
    expect(
      Theme.of(tester.element(find.byType(ZommiShell)))
          .extension<ZommiVisualSettings>()
          ?.chatFontSize,
      14,
    );

    await tester.tap(find.byKey(const ValueKey('theme-color-ocean')));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(ZommiShell)))
          .extension<ZommiVisualSettings>()
          ?.themeColor,
      ZommiThemeColor.ocean,
    );

    await tester.tap(gear);
    await tester.pumpAndSettle();
    expect(panel, findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('zommi-composer')),
      'larger chat type',
    );
    await tester.tap(find.byKey(const ValueKey('send-message')));
    await tester.pump();
    expect(
      tester
          .widgetList<MarkdownBody>(
            find.byWidgetPredicate((widget) => widget is MarkdownBody),
          )
          .map((body) => body.styleSheet?.p?.fontSize),
      contains(14),
    );
  });

  testWidgets(
    'composer and message typography share the configured font, size, and weight',
    (tester) async {
      final core = RichFakeCore()..historyCount = 0;
      final desktop = FakeDesktopBridge();
      await _pumpApp(tester, core: core, desktop: desktop);
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
            'text': '# Compact heading\nReadable body\n\n[Open site](https://example.com/item?q=1)',
            'itemId': 'answer',
          },
        ),
      );
      await tester.pump();

      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('zommi-composer')),
      );
      expect(field.style?.fontSize, 14);
      expect(field.style?.fontWeight, FontWeight.w400);
      expect(field.style?.fontFamily, codexUiFontFamily);
      expect(field.textAlignVertical, TextAlignVertical.center);
      final markdown = tester.widgetList<MarkdownBody>(
        find.byWidgetPredicate((widget) => widget is MarkdownBody),
      );
      expect(markdown, isNotEmpty);
      final bodySizes = markdown
          .map((body) => body.styleSheet?.p?.fontSize)
          .whereType<double>()
          .toSet();
      expect(bodySizes, <double>{14});
      expect(bodySizes, {field.style?.fontSize});
      expect(
        markdown.map((body) => body.styleSheet?.p?.fontWeight),
        everyElement(FontWeight.w400),
      );
      expect(
        markdown.map((body) => body.styleSheet?.p?.fontWeight),
        isNot(contains(FontWeight.bold)),
      );
      expect(userMessageFontSize, assistantMessageFontSize);
      expect(userMessageFontSize, topBarAndChatFontSize);
      expect(codexUiFontFamily, 'Segoe UI');
      expect(
        markdown.map((body) => body.styleSheet?.p?.fontFamily),
        contains(codexUiFontFamily),
      );
      expect(
        Theme.of(tester.element(find.byType(ZommiShell)))
            .textTheme
            .bodyMedium
            ?.fontFamily,
        codexUiFontFamily,
      );
      for (final body in markdown) {
        expect(body.styleSheet?.strong?.fontFamily, codexUiFontFamily);
        expect(body.styleSheet?.listBullet?.fontFamily, codexUiFontFamily);
        expect(body.styleSheet?.tableBody?.fontFamily, codexUiFontFamily);
      }
      final userBox = tester.widget<Container>(
        find.byWidgetPredicate(
          (widget) =>
              widget is Container &&
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'user-message-',
              ),
        ),
      );
      final assistantBox = find.byKey(const ValueKey('assistant-answer'));
      expect(userMessageBoxWidth, 416 * 1.2);
      expect(assistantMessageBoxWidth, 496 * 1.2);
      expect(
        userBox.constraints?.maxWidth,
        responsiveUserMessageBoxWidth(conversationContentMaxWidth),
      );
      expect(
        tester.getSize(assistantBox).width,
        lessThan(responsiveAssistantMessageBoxWidth(1000)),
      );
      const linkUrl = 'https://example.com/item?q=1';
      final link = find.byKey(const ValueKey('markdown-link-$linkUrl'));
      expect(link, findsOneWidget);
      expect(find.byTooltip(linkUrl), findsOneWidget);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(link));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(linkUrl), findsOneWidget);
      await tester.tap(link);
      await tester.pump();
      expect(desktop.openedUrl, Uri.parse(linkUrl));
      expect(
        tester
            .widget<TextButton>(
              find.descendant(
                of: find.byKey(const ValueKey('model-summary')),
                matching: find.byType(TextButton),
              ),
            )
            .style
            ?.textStyle
            ?.resolve(const <WidgetState>{})
            ?.fontFamily,
        codexUiFontFamily,
      );
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
    expect(find.byKey(const ValueKey('zommi-orb')), findsNothing);
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
    final distinct = distinctTranscriptBlocks(blocks);
    expect(
      distinct.where((block) => block.kind == TranscriptKind.assistant),
      hasLength(1),
    );
    expect(distinct.first.text, 'same answer');
    expect(
      distinct.where((block) => block.kind == TranscriptKind.thinking),
      isEmpty,
    );
    expect(distinct.last, blocks.last);
  });

  test('folding activity does not look like new transcript content', () {
    final block = TranscriptBlock(
      id: 'command-1',
      kind: TranscriptKind.tool,
      title: 'Command',
      text: 'output',
      preview: '12345678901234567890EXTRA',
      expanded: false,
    );
    final turn = ConversationTurn(
      id: 'turn-1',
      userText: 'run',
      blocks: [block],
    );
    final before = transcriptContentRevision([turn]);
    block.expanded = true;
    expect(transcriptContentRevision([turn]), before);
    expect(activityBlockTitle(block), 'Command · 12345678901234567890...');
  });

  testWidgets(
    'advanced runtime setup uses supported choices and a file picker only',
    (tester) async {
      final core = RichFakeCore()..historyCount = 0;
      final desktop = FakeDesktopBridge()
        ..nextRuntimeExecutable = '/custom/codex';
      await _pumpApp(tester, core: core, desktop: desktop);
      await _expand(tester);
      await _openNewChatMenu(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-runtime-setup')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('runtime-panel')), findsNothing);
      expect(find.byKey(const ValueKey('runtime-setup-panel')), findsOneWidget);
      // Asset decoding is real I/O; pumpAndSettle alone can capture the sidebar
      // before its logos load when this golden runs in isolation.
      await tester.runAsync(
        () => precacheImage(
          const AssetImage('assets/runtime_icons/codex.png'),
          tester.element(find.byType(ZommiApp)),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byKey(const ValueKey('runtime-setup-panel')),
        matchesGoldenFile(platformGoldenPath('runtime_setup_panel.png')),
      );
      expect(
        find.byKey(const ValueKey('runtime-override-locator')),
        findsNothing,
      );
      expect(find.text('OpenClaw · Direct Gateway'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('runtime-setup-panel')),
          matching: find.byType(DropdownButtonFormField<String>),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('runtime-setup-panel')),
          matching: find.byType(TextField),
        ),
        findsNothing,
      );
      final choose = find.byKey(const ValueKey('select-runtime-executable'));
      await tester.ensureVisible(choose);
      await tester.tap(choose);
      await tester.pumpAndSettle();
      expect(desktop.calls, contains('selectRuntimeExecutable'));
      expect(find.text('/custom/codex'), findsOneWidget);
      final save = find.byKey(const ValueKey('save-runtime-override'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(
        core.configuredOverrides.any(
          (value) => value['executablePath'] == '/custom/codex',
        ),
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('close-runtime-setup')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('runtime-setup-panel')), findsNothing);
    },
  );

  testWidgets(
    'WSL setup accepts Linux paths without opening a Windows picker',
    (tester) async {
      final core = RichFakeCore()..historyCount = 0;
      final desktop = FakeDesktopBridge();
      await _pumpApp(tester, core: core, desktop: desktop);
      await _openNewChatMenu(tester);
      await tester.tap(find.byKey(const ValueKey('open-runtime-setup')));
      await tester.pumpAndSettle();
      final host = find.byKey(const ValueKey('runtime-setup-host-wsl:ubuntu'));
      await tester.ensureVisible(host);
      await tester.tap(host);
      await tester.pumpAndSettle();
      final field = find.byKey(
        const ValueKey('runtime-wsl-path-codex-app-server-wsl:ubuntu'),
      );
      for (final path in [
        '~/.hermes/bin/codex',
        '/.hermes/bin/codex',
        '/home/agent/My Tools/codex',
      ]) {
        await tester.ensureVisible(field);
        await tester.enterText(field, path);
        await tester.pump();
        final save = find.byKey(const ValueKey('save-runtime-override'));
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(core.configuredOverrides.last['executablePath'], path);
        expect(
          (core.configuredOverrides.last['executionHost'] as Map)['id'],
          'wsl:ubuntu',
        );
        expect(tester.widget<TextFormField>(field).controller!.text, isEmpty);
      }
      expect(desktop.calls, isNot(contains('selectRuntimeExecutable')));
      expect(tester.takeException(), isNull);
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
    expect(find.byKey(const ValueKey('core-status')), findsNothing);
    await _openNewChatMenu(tester);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('runtime-sign-in-runtime-codex')),
    );
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
    await tester.pump(const Duration(milliseconds: 50));
    expect(desktop.calls, contains('startDragging'));
  });

  testWidgets('dragging across the custom titlebar starts native movement', (
    tester,
  ) async {
    final core = RichFakeCore()..historyCount = 0;
    final desktop = FakeDesktopBridge();
    await _pumpApp(tester, core: core, desktop: desktop);
    final titlebar = find.byKey(const ValueKey('window-drag-region'));
    final bounds = tester.getRect(titlebar);
    final gesture = await tester.startGesture(
      Offset(bounds.left + 8, bounds.center.dy),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(48, 0));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 50));
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
            'preview': '12345678901234567890EXTRA',
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
            'kind': 'thinking',
            'lifecycle': 'completed',
            'title': 'Thinking',
            'text': 'Comparing the selected rows.',
            'itemId': 'thinking-c',
          },
        ),
      );
      core.emit(
        _event(
          6,
          'item.update',
          turnId: 'session-1-live-turn',
          payload: const {
            'kind': 'tool',
            'lifecycle': 'completed',
            'title': 'Read',
            'text': 'README.md',
            'itemId': 'tool-2',
          },
        ),
      );
      core.emit(
        _event(
          7,
          'item.update',
          turnId: 'session-1-live-turn',
          payload: const {
            'kind': 'assistant',
            'lifecycle': 'delta',
            'title': 'Codex',
            'text': '## Result',
            'itemId': 'answer-stream',
          },
        ),
      );
      core.emit(
        _event(
          8,
          'item.update',
          turnId: 'session-1-live-turn',
          payload: const {
            'kind': 'assistant',
            'lifecycle': 'completed',
            'title': 'Codex',
            'text': '## Result\n\n- first\n- second\n\n```text\ncopy me\n```',
            'replace': true,
            'itemId': 'answer-terminal',
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

      final thinkingCards = find.byWidgetPredicate(
        (widget) =>
            widget is Container &&
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'activity-section-',
            ),
      );
      expect(thinkingCards, findsOneWidget);
      final thinkingCard = thinkingCards.at(0);
      expect(find.byKey(const ValueKey('activity-tool-1')), findsNothing);
      expect(find.byType(AnimatedCrossFade), findsNothing);
      expect(
        find.descendant(
          of: thinkingCard,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget.key is ValueKey<String> &&
                (widget.key! as ValueKey<String>).value.startsWith(
                  'thinking-fold-',
                ),
          ),
        ),
        findsOneWidget,
      );
      expect(
        tester.getSize(thinkingCard).width,
        responsiveAssistantMessageBoxWidth(1000),
      );
      await tester.ensureVisible(thinkingCard);
      await tester.pump(const Duration(milliseconds: 200));
      await expectLater(
        thinkingCard,
        matchesGoldenFile(platformGoldenPath('thinking_tools_collapsed.png')),
      );

      await tester.tap(
        find.descendant(
          of: thinkingCard,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget.key is ValueKey<String> &&
                (widget.key! as ValueKey<String>).value.startsWith(
                  'thinking-toggle-',
                ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final toolCard = find.byKey(const ValueKey('activity-tool-1'));
      expect(toolCard, findsOneWidget);
      expect(
        find.descendant(of: toolCard, matching: find.byType(AnimatedSize)),
        findsOneWidget,
      );
      expect(find.text('Command · 12345678901234567890...'), findsOneWidget);
      expect(find.text('Reading the selected table.'), findsOneWidget);
      expect(find.text('Comparing the selected rows.'), findsOneWidget);
      final thinkingMarkdown = find
          .descendant(of: thinkingCard, matching: find.byType(CopyableMarkdown))
          .first;
      expect(
        tester
            .getTopLeft(
              find.descendant(
                of: thinkingMarkdown,
                matching: find.byWidgetPredicate(
                  (widget) => widget is MarkdownBody,
                ),
              ),
            )
            .dx,
        closeTo(tester.getTopLeft(thinkingMarkdown).dx, .1),
      );
      final timeline = [
        find.byKey(const ValueKey('activity-thinking-a')),
        toolCard,
        find.byKey(const ValueKey('activity-thinking-c')),
        find.byKey(const ValueKey('activity-tool-2')),
      ];
      expect(timeline, everyElement(findsOneWidget));
      final timelineTops = timeline
          .map((finder) => tester.getTopLeft(finder).dy)
          .toList(growable: false);
      expect(timelineTops, orderedEquals([...timelineTops]..sort()));
      await expectLater(
        thinkingCard,
        matchesGoldenFile(platformGoldenPath('thinking_tools_expanded.png')),
      );
      expect(
        find.byKey(const ValueKey('assistant-answer-stream')),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Container &&
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith('assistant-'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('artifact-html-1')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('artifact-image-artifact-1')),
        findsOneWidget,
      );
      expect(find.byTooltip('Copy code'), findsNothing);
      expect(find.byTooltip('Copy response'), findsNothing);
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
      expect(viewer, findsNothing);
      expect(
        desktop.calls.where((call) => call.startsWith('document:')),
        hasLength(1),
      );
      expect(find.byKey(const ValueKey('zommi-composer')), findsOneWidget);

      core.emit(
        _event(
          9,
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
          10,
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
          11,
          'turn.completed',
          turnId: 'session-1-live-turn',
          payload: const {'status': 'completed'},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('stop-turn')), findsNothing);
      expect(find.byKey(const ValueKey('core-status')), findsNothing);
      expect(find.byTooltip('Copy response'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('Copy response'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Copy response'));
      await tester.pump();
      expect(
        desktop.copiedText,
        '## Result\n\n- first\n- second\n\n```text\ncopy me\n```',
      );
      await tester.pump(const Duration(seconds: 1));
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
          final latestGlyph = find.byKey(
            const ValueKey('scroll-to-latest-glyph'),
          );
          expect(tester.widget<IconButton>(latest).onPressed, isNotNull);
          expect(
            tester.getCenter(latest).dx,
            closeTo(tester.getCenter(find.byType(TranscriptPane)).dx, 0.01),
          );
          expect(
            tester.getCenter(latestGlyph).dx,
            closeTo(tester.getCenter(latest).dx, 0.01),
          );
          expect(
            tester.getCenter(latestGlyph).dy,
            closeTo(tester.getCenter(latest).dy, 0.01),
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

  testWidgets('background work never replaces the taskbar chat with an orb', (
    tester,
  ) async {
    final core = RichFakeCore()..historyCount = 0;
    await _pumpApp(tester, core: core, desktop: FakeDesktopBridge());

    core.emit(
      _event(
        1,
        'turn.started',
        runtimeTargetId: 'runtime-pi',
        sessionId: 'pi-background',
        turnId: 'background-turn',
        payload: const {'status': 'inProgress'},
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('zommi-orb')), findsNothing);
    expect(find.byKey(const ValueKey('zommi-composer')), findsOneWidget);

    core.emit(
      _event(
        2,
        'turn.completed',
        runtimeTargetId: 'runtime-pi',
        sessionId: 'pi-background',
        turnId: 'background-turn',
        payload: const {'status': 'completed'},
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('zommi-orb')), findsNothing);
    expect(find.byKey(const ValueKey('zommi-composer')), findsOneWidget);
  });

  testWidgets('growing the window does not auto-scroll the transcript', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(normalWindowSize);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final core = RichFakeCore()..historyCount = 50;
    await tester.pumpWidget(ZommiApp(core: core, desktop: FakeDesktopBridge()));
    await tester.pumpAndSettle();
    final transcript = find.byKey(const ValueKey('zommi-transcript'));
    await tester.drag(transcript, const Offset(0, 1800));
    await tester.pumpAndSettle();
    final position = tester.widget<ListView>(transcript).controller!.position;
    expect(position.maxScrollExtent - position.pixels, greaterThan(36));
    final before = position.pixels;
    final pane = tester.element(find.byType(TranscriptPane));

    await tester.binding.setSurfaceSize(largeWindowSize);
    await tester.pumpAndSettle();

    expect(
      identical(tester.element(find.byType(TranscriptPane)), pane),
      isTrue,
    );
    expect(position.pixels, closeTo(before, 0.01));
  });

  testWidgets('short message boxes stay close to their content width', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(normalWindowSize);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final core = RichFakeCore()..historyCount = 1;
    await tester.pumpWidget(ZommiApp(core: core, desktop: FakeDesktopBridge()));
    await tester.pumpAndSettle();
    final assistant = find.descendant(
      of: find.byKey(const ValueKey('assistant-session-1-answer-1')),
      matching: find.byType(RichText),
    );
    final user = find.byKey(const ValueKey('user-message-session-1-turn-1'));
    final normalAssistantWidth = tester.getSize(assistant).width;
    final normalUserWidth = tester.getSize(user).width;

    await tester.binding.setSurfaceSize(largeWindowSize);
    await tester.pumpAndSettle();

    final largeAssistantWidth = tester.getSize(assistant).width;
    final largeUserWidth = tester.getSize(user).width;
    expect(
      normalAssistantWidth,
      lessThan(responsiveAssistantMessageBoxWidth(normalWindowSize.width)),
    );
    expect(
      normalUserWidth,
      lessThan(responsiveUserMessageBoxWidth(normalWindowSize.width)),
    );
    expect(largeAssistantWidth, closeTo(normalAssistantWidth, 0.1));
    expect(largeUserWidth, closeTo(normalUserWidth, 0.1));
  });

  testWidgets('large windows center transcript and composer in one column', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(normalWindowSize);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final core = RichFakeCore()..historyCount = 1;
    await tester.pumpWidget(ZommiApp(core: core, desktop: FakeDesktopBridge()));
    await tester.pumpAndSettle();
    final sidebar = find.byKey(const ValueKey('session-sidebar'));
    final normalSidebarWidth = tester.getSize(sidebar).width;
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, greaterThan(normalSidebarWidth));

    final composer = tester.getRect(
      find.byKey(const ValueKey('message-composer-shell')),
    );
    final assistant = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey('assistant-session-1-answer-1')),
        matching: find.byType(RichText),
      ),
    );
    final user = tester.getRect(
      find.byKey(const ValueKey('user-message-session-1-turn-1')),
    );
    expect(composer.width, 864);
    expect(assistant.left, greaterThanOrEqualTo(composer.left));
    expect(assistant.right, lessThanOrEqualTo(composer.right));
    expect(user.left, greaterThanOrEqualTo(composer.left));
    expect(user.right, lessThanOrEqualTo(composer.right));
    expect(find.byKey(const ValueKey('core-status')), findsNothing);
  });

  testWidgets('tables use both panel margins and scroll after resizing', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final core = RichFakeCore()..historyCount = 1;
    final history = await core.readSession(
      runtimeTargetId: 'runtime-codex',
      sessionId: 'session-1',
    );
    final turn = ((history['thread'] as Map)['turns'] as List).single as Map;
    final text = List.filled(
      20,
      'Prose keeps its readable line width.',
    ).join(' ');
    ((turn['items'] as List).last as Map)['text'] =
        '$text\n\n'
        '| Reference | Description | Reference |\n| --- | --- | --- |\n'
        '| [Left source](https://example.com/left) | ${'A' * 70} | '
        '[Right source](https://example.com/wide) |';
    core.historyBySession['runtime-codex\u0000session-1'] = history;
    final desktop = FakeDesktopBridge();
    await tester.pumpWidget(ZommiApp(core: core, desktop: desktop));
    await tester.pumpAndSettle();
    final composer = tester.getRect(
      find.byKey(const ValueKey('message-composer-shell')),
    );
    final prose = tester.getRect(
      find.byWidgetPredicate(
        (widget) => widget is RichText && widget.text.toPlainText() == text,
      ),
    );
    final scroll = find.byWidgetPredicate(
      (widget) =>
          widget is SingleChildScrollView &&
          widget.scrollDirection == Axis.horizontal,
    );
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: scroll, matching: find.byType(Scrollable)),
        )
        .position;
    final table = tester.getRect(scroll);
    expect(prose.width, lessThanOrEqualTo(composer.width - 26));
    expect(prose.left, closeTo(composer.left + 13, .01));
    expect(table.left, lessThan(composer.left));
    expect(table.right, greaterThan(composer.right));
    expect(table.center.dx, closeTo(composer.center.dx, .01));
    expect(table.right, lessThan(1800 - 24));
    expect(position.maxScrollExtent, 0);
    final leftLink = find.byKey(
      const ValueKey('markdown-link-https://example.com/left'),
    );
    expect(tester.getCenter(leftLink).dx, lessThan(composer.left));
    await tester.tap(leftLink);
    await tester.pump();
    expect(desktop.openedUrl.toString(), 'https://example.com/left');
    final link = find.byKey(
      const ValueKey('markdown-link-https://example.com/wide'),
    );
    expect(tester.getCenter(link).dx, greaterThan(composer.right));
    await tester.tap(link);
    await tester.pump();
    expect(desktop.openedUrl.toString(), 'https://example.com/wide');

    await tester.binding.setSurfaceSize(const Size(1100, 900));
    await tester.pumpAndSettle();
    expect(position.maxScrollExtent, greaterThan(0));
    final narrowComposer = tester.getRect(
      find.byKey(const ValueKey('message-composer-shell')),
    );
    expect(tester.getRect(scroll).left, closeTo(narrowComposer.left + 13, .01));
    expect(tester.getRect(scroll).right, lessThan(1100 - 24));
    await tester.drag(scroll, const Offset(-1000, 0));
    await tester.pumpAndSettle();
    expect(tester.getRect(scroll).contains(tester.getCenter(link)), isTrue);
    expect(tester.takeException(), isNull);
  });

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
      await tester.pump(sessionSidebarDuration);
      expect(
        find.bySemanticsLabel('Secondary chat, Codex, running session'),
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
        find.bySemanticsLabel('Secondary chat, Codex, unread session'),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('session-runtime-codex-session-2')),
      );
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
    ZommiApp(
      core: core,
      desktop: desktop,
      artifactLoader: artifactLoader,
      clock: () => DateTime(2026, 9, 14, 14, 32),
    ),
  );
  await tester.pumpAndSettle();
  // Keep the full-width transcript fixture; sidebar behavior has its own tests.
  await tester.tap(find.byKey(const ValueKey('toggle-sessions')));
  await tester.pumpAndSettle();
}

Future<void> _expand(WidgetTester tester) async {
  await tester.pumpAndSettle();
}

Future<void> _selectImageFromComposer(
  WidgetTester tester,
  FakeDesktopBridge desktop,
) async {
  desktop.nextContext = desktop.nextImage;
  await tester.tap(find.byKey(const ValueKey('select-content')));
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
  String runtimeTargetId = 'runtime-codex',
  String sessionId = 'session-1',
  String? turnId,
  required Map<String, Object?> payload,
}) => CoreEvent(
  name: name,
  sequence: sequence,
  runtimeTargetId: runtimeTargetId,
  sessionId: sessionId,
  turnId: turnId,
  clientOperationId: 'flutter:test',
  payload: payload,
);

Future<void> _openNewChatMenu(WidgetTester tester) async {
  if (find.byKey(const ValueKey('session-sidebar')).evaluate().isEmpty) {
    await tester.tap(find.byKey(const ValueKey('toggle-sessions')));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const ValueKey('new-session')));
  await tester.pumpAndSettle();
}
