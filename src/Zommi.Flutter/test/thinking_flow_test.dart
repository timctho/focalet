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

Future<Uint8List> pixels(
  WidgetTester tester,
  Finder finder, {
  ui.ImageByteFormat format = ui.ImageByteFormat.png,
}) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(finder);
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: format);
    image.dispose();
    return data!.buffer.asUint8List();
  }))!;
}

// Locate the cool highlight around the edge, independent of its intensity.
// A changing tint without spatial motion must not satisfy this regression.
Offset coolHighlightPosition(Uint8List rgba, int width) {
  var weight = 0;
  var positionX = 0;
  var positionY = 0;
  for (var y = 0; y < rgba.length ~/ (width * 4); y++) {
    for (var x = 0; x < width; x++) {
      final offset = (y * width + x) * 4;
      // Exclude the warm light and faint stationary outline from the signal.
      final coolness =
          (rgba[offset + 2] + rgba[offset + 1] - 2 * rgba[offset] - 12).clamp(
            0,
            255,
          );
      weight += coolness;
      positionX += x * coolness;
      positionY += y * coolness;
    }
  }
  expect(weight, greaterThan(0));
  return Offset(positionX / weight, positionY / weight);
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
      final activeEdge = find.descendant(
        of: find.byType(ThinkingFlowBackground),
        matching: find.byType(RepaintBoundary),
      );
      final before = await pixels(tester, activeEdge);
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        listEquals(before, await pixels(tester, activeEdge)),
        isFalse,
        reason: 'Keep moving with no running items until the response ends.',
      );
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

  for (final brightness in Brightness.values) {
    for (final height in [40, 240]) {
      testWidgets(
        'lights chase clockwise with trailing tails in $brightness at height $height',
        (tester) async {
          const width = 500;
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(
                colorScheme: ColorScheme.fromSeed(
                  seedColor: const Color(0xff8d9ca8),
                  brightness: brightness,
                ),
              ),
              home: Center(
                child: SizedBox(
                  width: width.toDouble(),
                  height: height.toDouble(),
                  child: const ThinkingFlowBackground(),
                ),
              ),
            ),
          );
          await tester.pump();
          final boundary = find.descendant(
            of: find.byType(ThinkingFlowBackground),
            matching: find.byType(RepaintBoundary),
          );
          await tester.pump(const Duration(milliseconds: 1000));
          final before = await pixels(
            tester,
            boundary,
            format: ui.ImageByteFormat.rawRgba,
          );
          await tester.pump(const Duration(milliseconds: 500));
          final after = await pixels(
            tester,
            boundary,
            format: ui.ImageByteFormat.rawRgba,
          );
          for (final warm in [false, true]) {
            // The top travels right and the opposite bottom light travels left.
            List<int> edgeSignal(Uint8List rgba) => List.generate(width, (x) {
              var signal = 0;
              for (var row = 0; row < 6; row++) {
                final y = warm ? height - 1 - row : row;
                final offset = (y * width + x) * 4;
                signal +=
                    (warm
                            ? rgba[offset] +
                                  rgba[offset + 2] -
                                  2 * rgba[offset + 1] -
                                  12
                            : rgba[offset + 2] +
                                  rgba[offset + 1] -
                                  2 * rgba[offset] -
                                  12)
                        .clamp(0, 255);
              }
              return signal;
            });
            double center(List<int> signal) {
              var total = 0;
              var weighted = 0;
              for (var x = 0; x < width; x++) {
                total += signal[x];
                weighted += x * signal[x];
              }
              expect(total, greaterThan(0));
              return weighted / total;
            }

            final first = edgeSignal(before);
            final second = edgeSignal(after);
            final direction = warm ? -1 : 1;
            expect(
              (center(second) - center(first)) * direction,
              greaterThan(40),
              reason: 'Both lights must travel clockwise.',
            );
            var peak = 0;
            for (var x = 1; x < width; x++) {
              if (second[x] > second[peak]) peak = x;
            }
            expect(
              second[peak - direction * 60],
              greaterThan(second[peak + direction * 60] + 20),
              reason: 'The light must trail behind its direction of travel.',
            );
          }
          // Crossing the repeat boundary must continue through the same corner.
          await tester.pump(const Duration(milliseconds: 4484));
          final last = await pixels(
            tester,
            boundary,
            format: ui.ImageByteFormat.rawRgba,
          );
          await tester.pump(const Duration(milliseconds: 32));
          final next = await pixels(
            tester,
            boundary,
            format: ui.ImageByteFormat.rawRgba,
          );
          expect(
            (coolHighlightPosition(next, width) -
                    coolHighlightPosition(last, width))
                .distance,
            lessThan(15),
          );
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        },
      );

      testWidgets(
        'flow visibly travels with a still center in $brightness at height $height',
        (tester) async {
          const width = 500;
          final scheme =
              ColorScheme.fromSeed(
                seedColor: const Color(0xff8d9ca8),
                brightness: brightness,
              ).copyWith(
                surfaceContainerLow: brightness == Brightness.dark
                    ? const Color(0xff282828)
                    : const Color(0xfff9f9f9),
              );
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(colorScheme: scheme),
              home: Center(
                child: SizedBox(
                  width: width.toDouble(),
                  height: height.toDouble(),
                  child: const ThinkingFlowBackground(),
                ),
              ),
            ),
          );
          await tester.pump();
          final boundary = find.descendant(
            of: find.byType(ThinkingFlowBackground),
            matching: find.byType(RepaintBoundary),
          );
          await tester.pump(const Duration(milliseconds: 200));
          final before = await pixels(
            tester,
            boundary,
            format: ui.ImageByteFormat.rawRgba,
          );
          await tester.pump(const Duration(milliseconds: 600));
          final after = await pixels(
            tester,
            boundary,
            format: ui.ImageByteFormat.rawRgba,
          );
          expect(
            (coolHighlightPosition(after, width) -
                    coolHighlightPosition(before, width))
                .distance,
            greaterThan(50),
            reason: 'The light should visibly move, not only change color.',
          );
          var largestEdgeChange = 0;
          for (var index = 0; index < width * 6 * 4; index++) {
            final change = (after[index] - before[index]).abs();
            if (change > largestEdgeChange) largestEdgeChange = change;
          }
          expect(largestEdgeChange, greaterThan(24));
          // Keep the reading area opaque and stationary, including when open.
          for (var y = 12; y < height - 12; y++) {
            final start = (y * width + 12) * 4;
            final end = (y * width + width - 12) * 4;
            expect(after.sublist(start, end), before.sublist(start, end));
          }
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        },
      );
    }
  }

  testWidgets('render the active thinking signal', (tester) async {
    final directory = Platform.environment['ZOMMI_THINKING_PREVIEW_DIR'];
    if (directory == null) return;
    final theme =
        Platform.environment['ZOMMI_THINKING_PREVIEW_THEME'] == 'light'
        ? ThemeMode.light
        : ThemeMode.dark;
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
          initialPreferences: AppPreferences(themeMode: theme),
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
      () => File('$directory/thinking-${theme.name}.png').writeAsBytes(first),
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
    final group = tester.widget<ThinkingActivityGroup>(
      find.byType(ThinkingActivityGroup),
    );
    await tester.tap(find.byKey(ValueKey('thinking-toggle-${group.id}')));
    await tester.pump();
    for (var frame = 0; frame < 36; frame++) {
      await tester.pump(const Duration(milliseconds: 166));
      final data = await pixels(tester, find.byKey(screen));
      await tester.runAsync(
        () =>
            File('$directory/expanded-${frame.toString().padLeft(2, '0')}.png')
                .writeAsBytes(data),
      );
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
