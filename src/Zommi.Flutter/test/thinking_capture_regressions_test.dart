import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/state/history_mapper.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/theme/app_preferences.dart';
import 'package:zommi_flutter/widgets/content_views.dart';
import 'package:zommi_flutter/widgets/transcript_view.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'test_support.dart';

void main() {
  testWidgets('expanded live runtime events keep settings and Stop responsive', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(normalWindowSize);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final core = RichFakeCore()..historyCount = 0;
    await tester.pumpWidget(ZommiApp(core: core, desktop: FakeDesktopBridge()));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('zommi-composer')),
      'Inspect while streaming',
    );
    await tester.tap(find.byKey(const ValueKey('send-message')));
    await tester.pump();
    var sequence = 0;
    void emit(String name, Map<String, Object?> payload) => core.emit(
      CoreEvent(
        name: name,
        sequence: ++sequence,
        runtimeTargetId: 'runtime-codex',
        sessionId: 'session-1',
        turnId: 'session-1-live-turn',
        clientOperationId: 'flutter:test',
        payload: payload,
      ),
    );
    emit('turn.started', {'status': 'inProgress'});
    for (var index = 0; index < 50; index++) {
      emit('item.update', {
        'kind': 'thinking',
        'lifecycle': 'completed',
        'itemId': 'history-$index',
        'text': 'Completed investigation step $index.',
      });
    }
    emit('item.update', {
      'kind': 'thinking',
      'lifecycle': 'delta',
      'itemId': 'live-reasoning',
      'text': 'Starting live inspection.',
    });
    await tester.pump();
    final group = tester.widget<ThinkingActivityGroup>(
      find.byType(ThinkingActivityGroup),
    );
    final toggle = find.byKey(ValueKey('thinking-toggle-${group.turn.id}'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('thinking-activity-list')),
      findsOneWidget,
    );
    for (var delta = 0; delta < 60; delta++) {
      emit('item.update', {
        'kind': 'thinking',
        'lifecycle': 'delta',
        'itemId': 'live-reasoning',
        'replace': true,
        'text':
            'Live step $delta.\n\n${'Checking **stream state** and retaining full context. ' * 20}',
      });
      await tester.pump(const Duration(milliseconds: 16));
      if (delta == 20) {
        await tester.tap(find.byKey(const ValueKey('app-settings')));
        await tester.pump();
        expect(
          find.byKey(const ValueKey('app-settings-panel')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('app-settings')));
        await tester.pump();
      }
    }
    expect(
      tester
          .widgetList<MarkdownBody>(find.byType(MarkdownBody))
          .any((body) => body.data.contains('Live step 59.')),
      isTrue,
    );
    await tester.tap(find.byKey(const ValueKey('stop-turn')));
    await tester.pump();
    expect(core.interrupted, (
      'runtime-codex',
      'session-1',
      'session-1-live-turn',
    ));
    expect(tester.takeException(), isNull);
  });

  test('overlap matches exhaustive reference without quadratic snapshots', () {
    final random = Random(42);
    String text() => List.generate(
      random.nextInt(80),
      (_) => 'abc'[random.nextInt(3)],
    ).join();
    for (var sample = 0; sample < 2000; sample++) {
      final current = text();
      final incoming = text();
      var expected = min(current.length, incoming.length);
      while (!current.endsWith(incoming.substring(0, expected))) {
        expected--;
      }
      expect(suffixPrefixOverlap(current, incoming), expected);
    }
    final repeated = 'a' * 100000;
    final clock = Stopwatch()..start();
    expect(suffixPrefixOverlap('${repeated}b', '${repeated}c'), 0);
    expect(clock.elapsed, lessThan(const Duration(seconds: 1)));
  });

  testWidgets('empty reasoning stays hidden until content arrives', (
    tester,
  ) async {
    final controller = ZommiController(
      core: RichFakeCore(),
      desktop: FakeDesktopBridge(),
    );
    addTearDown(controller.close);
    final empty = TranscriptBlock(
      id: 'empty',
      kind: TranscriptKind.thinking,
      title: 'Thinking',
      text: ' \n ',
    );
    final turn = ConversationTurn(
      id: 'turn',
      userText: 'Inspect',
      blocks: [empty],
    );
    await _pumpTurn(tester, controller, turn);
    expect(find.byType(ThinkingActivityGroup), findsNothing);
    empty.text = 'Visible reasoning';
    controller.setTurnActivityExpanded(turn, true);
    await tester.pump();
    expect(find.byType(ThinkingActivityGroup), findsOneWidget);
    expect(find.text('Visible reasoning'), findsOneWidget);
    empty.lifecycle = TranscriptLifecycle.completed;
    empty.text = '';
    controller.setTurnActivityExpanded(turn, true);
    await tester.pump();
    expect(find.byType(ThinkingActivityGroup), findsNothing);
  });

  testWidgets('large running activity stays lazy and responds during updates', (
    tester,
  ) async {
    final controller = ZommiController(
      core: RichFakeCore(),
      desktop: FakeDesktopBridge(),
    );
    addTearDown(controller.close);
    final turn = ConversationTurn(
      id: 'long-turn',
      userText: 'Inspect',
      blocks: List.generate(
        2000,
        (index) => TranscriptBlock(
          id: 'step-$index',
          kind: TranscriptKind.thinking,
          title: 'Step $index',
          text: 'Reasoning **$index** with a [link](https://example.test).',
          lifecycle: index == 1999
              ? TranscriptLifecycle.delta
              : TranscriptLifecycle.completed,
        ),
      ),
    );
    await _pumpTurn(tester, controller, turn);
    expect(find.byType(MarkdownBody), findsOneWidget);
    final clock = Stopwatch()..start();
    await tester.tap(find.byKey(const ValueKey('thinking-toggle-long-turn')));
    await tester.pump();
    expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
    expect(find.byType(MarkdownBody).evaluate().length, lessThan(25));
    final activityList = find.byKey(const ValueKey('thinking-activity-list'));
    expect(activityList, findsOneWidget);
    expect(find.byKey(const ValueKey('activity-step-1999')), findsOneWidget);
    for (var delta = 0; delta < 40; delta++) {
      turn.blocks.last.text = 'Live update $delta';
      controller.setTurnActivityExpanded(turn, true);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.text('Live update 39'), findsOneWidget);
    expect(find.byType(MarkdownBody).evaluate().length, lessThan(25));
    await tester.tap(find.byKey(const ValueKey('thinking-toggle-long-turn')));
    await tester.pump();
    expect(activityList, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unchanged markdown reuses its parsed widget across rebuilds', (
    tester,
  ) async {
    Future<void> copy(String value) async {}
    Future<void> open(String value) async {}
    Widget view(String text) => MaterialApp(
      home: Scaffold(
        body: CopyableMarkdown(text: text, onCopy: copy, onOpenLink: open),
      ),
    );
    await tester.pumpWidget(view('**Stable** reasoning'));
    final original = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    final originalElement = tester.element(find.byType(MarkdownBody));
    final selection = tester.element(find.byType(SelectionArea));
    await tester.pumpWidget(view('**Stable** reasoning'));
    expect(
      tester.widget<MarkdownBody>(find.byType(MarkdownBody)),
      same(original),
    );
    await tester.pumpWidget(view('**New** reasoning'));
    expect(
      tester.widget<MarkdownBody>(find.byType(MarkdownBody)).data,
      '**New** reasoning',
    );
    expect(tester.element(find.byType(MarkdownBody)), same(originalElement));
    expect(tester.element(find.byType(SelectionArea)), same(selection));
  });

  testWidgets('Maximize applies native state and restores Wide or Standard', (
    tester,
  ) async {
    final desktop = FakeDesktopBridge();
    await tester.binding.setSurfaceSize(normalWindowSize);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ZommiApp(core: RichFakeCore()..historyCount = 0, desktop: desktop),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('app-settings')));
    await tester.pumpAndSettle();
    expect(find.text('Maximize'), findsNothing);
    final maxLabel = tester.widget<Text>(find.text('Max'));
    expect(maxLabel.maxLines, 1);
    expect(maxLabel.softWrap, isFalse);
    await tester.tap(find.text('Max'));
    await tester.pumpAndSettle();
    expect(desktop.calls, contains('maximize'));
    expect(desktop.surfaceAnimations.last, isTrue);
    final selector = tester.widget<SegmentedButton<WindowSizeSetting>>(
      find.byKey(const ValueKey('window-size-control')),
    );
    expect(selector.selected, {WindowSizeSetting.maximized});
    await tester.tap(find.text('Wide'));
    await tester.pumpAndSettle();
    expect(desktop.calls.last, 'surface:true:true');
    expect(desktop.surfaceAnimations.last, isTrue);
    await tester.tap(find.text('Standard'));
    await tester.pumpAndSettle();
    expect(desktop.calls.last, 'surface:true:false');
    expect(desktop.surfaceAnimations.last, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed native maximize keeps the applied and persisted mode', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(normalWindowSize);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final desktop = FakeDesktopBridge();
    final preferences = _RecordingPreferencesStore();
    await tester.pumpWidget(
      ZommiApp(
        core: RichFakeCore()..historyCount = 0,
        desktop: desktop,
        preferencesStore: preferences,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('app-settings')));
    await tester.pumpAndSettle();
    final nativeResize = Completer<void>();
    desktop.surfaceGate = nativeResize.future;
    await tester.tap(find.text('Max'));
    await tester.pump();
    nativeResize.completeError(StateError('native resize rejected'));
    await tester.pumpAndSettle();
    final selector = tester.widget<SegmentedButton<WindowSizeSetting>>(
      find.byKey(const ValueKey('window-size-control')),
    );
    expect(selector.selected, {WindowSizeSetting.standard});
    expect(preferences.saved, isEmpty);
    expect(tester.takeException(), isNull);
  });

  test('window preferences migrate old Wide and persist native Maximize', () {
    expect(
      AppPreferences.fromJson({'largeWindow': true}).windowSize,
      WindowSizeSetting.wide,
    );
    const preferences = AppPreferences(windowSize: WindowSizeSetting.maximized);
    expect(AppPreferences.fromJson(preferences.toJson()), preferences);
  });

  test(
    'capture feedback never focuses before its source snapshot completes',
    () async {
      final desktop = FakeDesktopBridge();
      final controller = ZommiController(
        core: RichFakeCore(),
        desktop: desktop,
      );
      await controller.initialize();
      desktop.calls.clear();
      desktop.emit(
        const DesktopInvocation(kind: DesktopInvocationKind.captureStarted),
      );
      await Future<void>.delayed(Duration.zero);
      expect(desktop.calls, ['showPanelInactive']);
      expect(controller.attachments, isEmpty);
      desktop.emit(
        DesktopInvocation(
          kind: DesktopInvocationKind.context,
          attachment: ContextAttachment(
            id: 'capture',
            token: '',
            snapshot: {'application': 'Source'},
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.attachments.single.snapshot?['application'], 'Source');
      expect(desktop.calls, ['showPanelInactive', 'showPanel']);
      await controller.close();
    },
  );

  testWidgets(
    'native presentation distinguishes inactive feedback from focus',
    (tester) async {
      const channel = MethodChannel('zommi/window_animation');
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      expect(
        await presentNativePanel(focus: false, platformIsWindows: true),
        isTrue,
      );
      expect(await presentNativePanel(platformIsWindows: true), isTrue);
      expect(calls.map((call) => call.method), [
        'presentPanel',
        'presentPanel',
      ]);
      expect(calls.map((call) => call.arguments), [
        {'focus': false},
        {'focus': true},
      ]);
    },
  );

  test('interactive selection has its own time budget and timed-out workers recover', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zommi-selector-timeout-',
    );
    final executable = File('${directory.path}/capture');
    await executable.writeAsString('''#!/usr/bin/env python3
import json, os, sys, time
for line in sys.stdin:
    request = json.loads(line)
    if request['method'] in ('selectContext', 'capture'):
        time.sleep(0.15)
    print(json.dumps({'type': 'response', 'id': request['id'], 'ok': True, 'result': {'pid': os.getpid()}}), flush=True)
    if request['method'] == 'shutdown':
        break
''');
    await Process.run('chmod', ['+x', executable.path]);
    final client = ProcessNativeCaptureClient(
      executable.path,
      captureTimeout: const Duration(milliseconds: 80),
      selectionTimeout: const Duration(seconds: 2),
    );
    addTearDown(() async {
      await client.close();
      await directory.delete(recursive: true);
    });
    final selected = await client.request('selectContext');
    expect(selected['pid'], isA<int>());
    await expectLater(
      client.request('capture'),
      throwsA(isA<TimeoutException>()),
    );
    Map<String, Object?>? restarted;
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline) && restarted == null) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      try {
        restarted = await client.request('ping');
      } on Object {
        // The old helper may still be exiting; wait for a fresh worker.
      }
    }
    expect(restarted?['pid'], isA<int>());
    expect(restarted?['pid'], isNot(selected['pid']));
  }, skip: Platform.isWindows);

  test(
    'native host startup is single-flight and ready does not finish capture',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'zommi-capture-test-',
      );
      final executable = File('${directory.path}/capture');
      await executable.writeAsString('''#!/usr/bin/env python3
import json, os, sys, time
for line in sys.stdin:
    request = json.loads(line)
    if request['method'] == 'capture' and request['params'].get('reportReady'):
        print(json.dumps({'type': 'captureReady', 'id': request['id']}), flush=True)
        time.sleep(0.1)
    print(json.dumps({'type': 'response', 'id': request['id'], 'ok': True, 'result': {'pid': os.getpid()}}), flush=True)
    if request['method'] == 'shutdown':
        break
''');
      await Process.run('chmod', ['+x', executable.path]);
      final client = ProcessNativeCaptureClient(executable.path);
      addTearDown(() async {
        await client.close();
        await directory.delete(recursive: true);
      });
      final ready = Completer<void>();
      var completed = false;
      final ping = client.request('ping');
      final capture = client.request('capture', onReady: ready.complete).then((
        value,
      ) {
        completed = true;
        return value;
      });
      await ready.future.timeout(const Duration(seconds: 5));
      expect(completed, isFalse);
      expect((await ping)['pid'], (await capture)['pid']);
    },
    skip: Platform.isWindows,
  );
}

Future<void> _pumpTurn(
  WidgetTester tester,
  ZommiController controller,
  ConversationTurn turn,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: AnimatedBuilder(
            animation: controller,
            builder: (_, _) => ConversationTurnView(
              turn: turn,
              viewportWidth: 720,
              runtimeName: 'Agent',
              controller: controller,
              onAttachmentEnter: (attachment, anchor) {},
              onAttachmentExit: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

final class _RecordingPreferencesStore implements AppPreferencesStore {
  final List<AppPreferences> saved = [];

  @override
  Future<AppPreferences> load() async => const AppPreferences();

  @override
  Future<void> save(AppPreferences preferences) async => saved.add(preferences);
}
