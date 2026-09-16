import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/theme/app_preferences.dart';
import 'package:zommi_flutter/widgets/thinking_flow_background.dart';
import 'package:zommi_flutter/widgets/transcript_view.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'test_support.dart';

Future<Uint8List> pixels(WidgetTester tester, Finder finder) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(finder);
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }))!;
}

void main() {
  testWidgets(
    'last thinking glows through completed items and response streaming',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final core = RichFakeCore()..historyCount = 0;
      await tester.pumpWidget(
        ZommiApp(core: core, desktop: FakeDesktopBridge()),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('zommi-composer')),
        'Check the flow',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      var sequence = 0;
      void emit(
        String kind,
        String id,
        String text, {
        bool completed = false,
      }) => core.emit(
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
          },
        ),
      );
      emit('thinking', 'r1', 'First step', completed: true);
      emit('tool', 't1', 'Read files', completed: true);
      emit('assistant', 'empty', '', completed: true);
      emit('thinking', 'r2', 'Next step', completed: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      final groups = find.byType(ThinkingActivityGroup);
      expect(groups, findsOneWidget);
      final group = tester.widget<ThinkingActivityGroup>(groups);
      expect(group.activities.map((block) => block.id), ['r1', 't1', 'r2']);
      expect(find.byType(ThinkingFlowBackground), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('thinking-toggle-${group.id}')));
      await tester.pump();
      expect(find.text('First step'), findsOneWidget);
      expect(
        find.text('Read files'),
        findsNothing,
      ); // Tools keep their own fold.
      expect(find.text('Next step'), findsOneWidget);

      emit('commentary', 'reply', 'Progress update');
      await tester.pump();
      expect(find.byType(ThinkingFlowBackground), findsOneWidget);
      emit('thinking', 'r3', 'Verify results');
      await tester.pump();
      expect(groups, findsNWidgets(2));
      expect(
        find.descendant(
          of: groups.first,
          matching: find.byType(ThinkingFlowBackground),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: groups.last,
          matching: find.byType(ThinkingFlowBackground),
        ),
        findsOneWidget,
      );
      expect(
        tester.getBottomLeft(groups.first).dy,
        lessThan(tester.getTopLeft(find.text('Progress update')).dy),
      );
      expect(
        tester.getBottomLeft(find.text('Progress update')).dy,
        lessThan(tester.getTopLeft(groups.last).dy),
      );
      emit('thinking', 'r3', 'Verify results', completed: true);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ThinkingFlowBackground), findsOneWidget);
      emit('assistant', 'answer', 'The result is');
      await tester.pump();
      expect(find.byType(ThinkingFlowBackground), findsOneWidget);
      emit('assistant', 'answer', ' ready.', completed: true);
      await tester.pump();
      expect(find.byType(ThinkingFlowBackground), findsOneWidget);
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
      expect(find.byType(ThinkingFlowBackground), findsNothing);
      expect(
        find.descendant(
          of: groups,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  for (final status in ['completed', 'interrupted', 'failed', 'unknown']) {
    testWidgets('flow stops when the turn is $status', (tester) async {
      final core = RichFakeCore()..historyCount = 0;
      await tester.pumpWidget(
        ZommiApp(core: core, desktop: FakeDesktopBridge()),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('zommi-composer')),
        'Run',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      core.emit(
        const CoreEvent(
          name: 'item.update',
          sequence: 1,
          runtimeTargetId: 'runtime-codex',
          sessionId: 'session-1',
          turnId: 'session-1-live-turn',
          payload: {
            'kind': 'thinking',
            'itemId': 'r1',
            'text': 'Working',
            'lifecycle': 'completed',
          },
        ),
      );
      await tester.pump();
      expect(find.byType(ThinkingFlowBackground), findsOneWidget);
      core.emit(
        CoreEvent(
          name: 'turn.completed',
          sequence: 2,
          runtimeTargetId: 'runtime-codex',
          sessionId: 'session-1',
          turnId: 'session-1-live-turn',
          payload: {'status': status},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ThinkingFlowBackground), findsNothing);
      expect(find.byKey(const ValueKey('send-message')), findsOneWidget);
      expect(find.byKey(const ValueKey('stop-turn')), findsNothing);
    });
  }

  for (final (reduceMotion, tickers) in [
    (false, true),
    (true, true),
    (false, false),
  ]) {
    testWidgets(
      'flow pixels respect reduced motion $reduceMotion and tickers $tickers',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduceMotion),
              child: TickerMode(
                enabled: tickers,
                child: const SizedBox(
                  width: 500,
                  height: 40,
                  child: ThinkingFlowBackground(),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final boundary = find.descendant(
          of: find.byType(ThinkingFlowBackground),
          matching: find.byType(RepaintBoundary),
        );
        final before = await pixels(tester, boundary);
        await tester.pump(const Duration(milliseconds: 900));
        final after = await pixels(tester, boundary);
        expect(listEquals(before, after), reduceMotion || !tickers);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        expect(tester.binding.hasScheduledFrame, isFalse);
      },
    );
  }

  testWidgets('render the active thinking signal', (tester) async {
    final directory = Platform.environment['ZOMMI_THINKING_PREVIEW_DIR'];
    if (directory == null) return;
    await tester.binding.setSurfaceSize(const Size(1400, 680));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await (FontLoader(codexUiFontFamily)..addFont(
            File('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf')
                .readAsBytes()
                .then(ByteData.sublistView),
          ))
          .load();
      await (FontLoader('MaterialIcons')..addFont(
            File(
              '/home/example/.local/share/flutter-toolchains/flutter-3.47.2/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
      await Directory(directory).create(recursive: true);
    });
    final core = RichFakeCore()..historyCount = 0;
    final screen = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: screen,
        child: ZommiApp(
          core: core,
          desktop: FakeDesktopBridge(),
          initialPreferences: const AppPreferences(themeMode: ThemeMode.dark),
          clock: () => DateTime(2026, 9, 14, 14, 32),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => precacheImage(
        const AssetImage('assets/runtime_icons/codex.png'),
        tester.element(find.byType(ZommiShell)),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('zommi-composer')),
      'Make the message panels wider and use a gentle, low-contrast pastel glow while the agent is working.',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    core.emit(
      const CoreEvent(
        name: 'item.update',
        sequence: 1,
        runtimeTargetId: 'runtime-codex',
        sessionId: 'session-1',
        turnId: 'session-1-live-turn',
        payload: {
          'kind': 'thinking',
          'itemId': 'reason',
          'text': 'Reviewing the current changes',
          'lifecycle': 'delta',
        },
      ),
    );
    core.emit(
      const CoreEvent(
        name: 'item.update',
        sequence: 2,
        runtimeTargetId: 'runtime-codex',
        sessionId: 'session-1',
        turnId: 'session-1-live-turn',
        payload: {
          'kind': 'tool',
          'itemId': 'tool',
          'text': 'Read source',
          'lifecycle': 'completed',
        },
      ),
    );
    core.emit(
      const CoreEvent(
        name: 'item.update',
        sequence: 3,
        runtimeTargetId: 'runtime-codex',
        sessionId: 'session-1',
        turnId: 'session-1-live-turn',
        payload: {
          'kind': 'thinking',
          'itemId': 'reason-next',
          'text': 'Verifying the result',
          'lifecycle': 'delta',
        },
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.byKey(const ValueKey('zommi-composer')),
      'Enter will queue this follow-up',
    );
    await tester.pump();
    final first = await pixels(tester, find.byKey(screen));
    await tester.runAsync(
      () => File('$directory/thinking-dark.png').writeAsBytes(first),
    );
    for (var frame = 0; frame < 72; frame++) {
      await tester.pump(const Duration(milliseconds: 166));
      final data = await pixels(tester, find.byKey(screen));
      await tester.runAsync(
        () =>
            File('$directory/frame-${frame.toString().padLeft(2, '0')}.png')
                .writeAsBytes(data),
      );
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
