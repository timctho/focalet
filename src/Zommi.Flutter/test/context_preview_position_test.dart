import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/widgets/context_preview_layout.dart';
import 'package:zommi_flutter/widgets/overlay_panels.dart';
import 'package:zommi_flutter/widgets/transcript_view.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'test_support.dart';

void main() {
  testWidgets(
    'context thumbnail opens an image with captured text folded in Details',
    (tester) async {
      await tester.binding.setSurfaceSize(normalWindowSize);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final desktop = FakeDesktopBridge();
      await tester.pumpWidget(
        ZommiApp(core: RichFakeCore()..historyCount = 0, desktop: desktop),
      );
      await tester.pumpAndSettle();
      desktop.emit(
        DesktopInvocation(
          kind: DesktopInvocationKind.context,
          attachment: ContextAttachment(
            id: 'click-context',
            token: '',
            snapshot: const {
              'windowTitle': 'Selected chart',
              'selection': ['The complete selected chart details'],
            },
            imageDataUrl:
                'data:image/png;base64,'
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('inline-image-click-context')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('context-preview')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('context-preview-image-frame')),
        findsOneWidget,
      );
      expect(find.byType(SelectableText), findsNothing);
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('context-preview-text')),
        findsOneWidget,
      );
      final detail = tester.widget<SelectableText>(
        find.byKey(const ValueKey('context-preview-text')),
      );
      expect(detail.data, contains('The complete selected chart details'));
      expect(find.text('Adjust'), findsNothing);
    },
  );

  for (final placement in [
    ('right', const Rect.fromLTWH(20, 100, 60, 24), const Offset(88, 100)),
    ('left', const Rect.fromLTWH(560, 100, 60, 24), const Offset(172, 100)),
    ('above', const Rect.fromLTWH(280, 400, 60, 24), const Offset(252, 192)),
    ('below', const Rect.fromLTWH(280, 20, 60, 24), const Offset(252, 52)),
  ]) {
    test('context preview flips ${placement.$1} within viewport bounds', () {
      final layout = ContextPreviewLayout(anchorRect: placement.$2);
      const viewport = Size(640, 500);
      const preview = Size(380, 200);
      final constraints = layout.getConstraintsForChild(
        BoxConstraints.tight(viewport),
      );
      expect(constraints.constrain(preview), preview);
      expect(layout.getPositionForChild(viewport, preview), placement.$3);
    });
  }

  testWidgets(
    'image preview scrolls without overflowing limited anchor space',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 640,
              height: 450,
              child: CustomSingleChildLayout(
                delegate: ContextPreviewLayout(
                  anchorRect: const Rect.fromLTWH(280, 220, 60, 24),
                ),
                child: ContextPreviewPanel(
                  attachment: ContextAttachment(
                    id: 'constrained-image',
                    token: '[image]',
                    previewText: 'Details remain accessible below the image',
                    snapshot: {},
                    imageDataUrl:
                        'data:image/png;base64,'
                        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
                  ),
                  onClose: () {},
                  onPointerEnter: () {},
                  onPointerExit: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final scroll = find.descendant(
        of: find.byType(ContextPreviewPanel),
        matching: find.byType(SingleChildScrollView),
      );
      await tester.drag(scroll, const Offset(0, -180));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      await tester.drag(scroll, const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('context-preview-text')).hitTestable(),
        findsOneWidget,
      );
    },
  );

  for (final size in [
    const Size(640, 500),
    normalWindowSize,
    const Size(1440, 900),
  ]) {
    testWidgets('composer context preview stays beside its chip at $size', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final desktop = FakeDesktopBridge();
      await tester.pumpWidget(
        ZommiApp(core: RichFakeCore()..historyCount = 0, desktop: desktop),
      );
      await tester.pumpAndSettle();
      desktop.emit(
        DesktopInvocation(
          kind: DesktopInvocationKind.context,
          attachment: _attachment,
        ),
      );
      await tester.pumpAndSettle();
      final chip = find.byKey(
        const ValueKey('inline-attachment-hover-context'),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(chip));
      await tester.pump();
      final preview = find.byKey(const ValueKey('context-preview'));
      expect(preview, findsOneWidget);
      _expectAdjacent(tester, chip, preview);

      final original = tester.getRect(preview);
      await mouse.moveTo(tester.getCenter(preview));
      await tester.pump(const Duration(milliseconds: 400));
      expect(preview, findsOneWidget);
      expect(tester.getRect(preview), original);
      await mouse.moveTo(const Offset(-10, -10));
      await tester.pump(const Duration(milliseconds: 400));
      expect(preview, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'sent context preview follows resize and dismisses on source scroll',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final desktop = FakeDesktopBridge();
      await tester.pumpWidget(
        ZommiApp(core: RichFakeCore()..historyCount = 0, desktop: desktop),
      );
      await tester.pumpAndSettle();
      desktop.emit(
        DesktopInvocation(
          kind: DesktopInvocationKind.context,
          attachment: _attachment,
        ),
      );
      await tester.pumpAndSettle();
      final composer = tester
          .widget<TextField>(find.byKey(const ValueKey('zommi-composer')))
          .controller!;
      final text = '${composer.text}Explain this context';
      composer.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send-message')));
      await tester.pump();
      final chip = find.byKey(
        const ValueKey('sent-inline-attachment-hover-context'),
      );
      expect(chip, findsOneWidget);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(chip));
      await tester.pump();
      final preview = find.byKey(const ValueKey('context-preview'));
      _expectAdjacent(tester, chip, preview);
      await tester.binding.setSurfaceSize(normalWindowSize);
      await tester.pump();
      await tester.pump();
      _expectAdjacent(tester, chip, preview);
      ScrollStartNotification(
        metrics: FixedScrollMetrics(
          minScrollExtent: 0,
          maxScrollExtent: 100,
          pixels: 0,
          viewportDimension: 300,
          axisDirection: AxisDirection.down,
          devicePixelRatio: 1,
        ),
        context: tester.element(find.byType(TranscriptPane)),
      ).dispatch(tester.element(find.byType(TranscriptPane)));
      await tester.pump();
      await tester.pump();
      expect(preview, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('approval dialog dismisses a context preview', (tester) async {
    await tester.binding.setSurfaceSize(normalWindowSize);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final desktop = FakeDesktopBridge();
    final core = RichFakeCore()..historyCount = 0;
    await tester.pumpWidget(ZommiApp(core: core, desktop: desktop));
    await tester.pumpAndSettle();
    desktop.emit(
      DesktopInvocation(
        kind: DesktopInvocationKind.context,
        attachment: _attachment,
      ),
    );
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(
        find.byKey(const ValueKey('inline-attachment-hover-context')),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('context-preview')), findsOneWidget);
    core.emit(
      const CoreEvent(
        name: 'approval.requested',
        sequence: 1,
        runtimeTargetId: 'runtime-codex',
        sessionId: 'session-1',
        payload: {
          'approvalId': 'preview-approval',
          'toolCall': {'title': 'Run command'},
          'options': [
            {'optionId': 'deny', 'name': 'Deny', 'kind': 'reject'},
          ],
        },
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('approval-title')), findsOneWidget);
    expect(find.byKey(const ValueKey('context-preview')), findsNothing);
  });
}

final _attachment = ContextAttachment(
  id: 'hover-context',
  token: '[context]',
  previewText: List.filled(
    30,
    'Context detail under the original pointer',
  ).join('\n'),
  snapshot: const {'application': 'Browser', 'windowTitle': 'Preview fixture'},
);

void _expectAdjacent(WidgetTester tester, Finder chip, Finder preview) {
  final anchorBounds = tester.getRect(chip);
  final previewBounds = tester.getRect(preview);
  final surfaceBounds = tester.getRect(
    find.byKey(const ValueKey('zommi-surface')),
  );
  final horizontalGap = math.max(
    0.0,
    math.max(
      previewBounds.left - anchorBounds.right,
      anchorBounds.left - previewBounds.right,
    ),
  );
  final verticalGap = math.max(
    0.0,
    math.max(
      previewBounds.top - anchorBounds.bottom,
      anchorBounds.top - previewBounds.bottom,
    ),
  );
  expect(anchorBounds.overlaps(previewBounds), isFalse);
  expect(
    math.sqrt(horizontalGap * horizontalGap + verticalGap * verticalGap),
    inInclusiveRange(6, 12),
    reason: 'The preview must remain immediately beside the hovered context',
  );
  expect(previewBounds.left, greaterThanOrEqualTo(surfaceBounds.left));
  expect(previewBounds.top, greaterThanOrEqualTo(surfaceBounds.top));
  expect(previewBounds.right, lessThanOrEqualTo(surfaceBounds.right));
  expect(previewBounds.bottom, lessThanOrEqualTo(surfaceBounds.bottom));
}
