import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'test_support.dart';

void main() {
  testWidgets(
    'Stop remains centered when a multiline draft accompanies a running turn',
    (tester) async {
      final core = RichFakeCore()..historyCount = 0;
      await tester.pumpWidget(
        ZommiApp(core: core, desktop: FakeDesktopBridge()),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('zommi-composer')),
        'First line\nSecond line\nThird line',
      );
      core.emit(
        const CoreEvent(
          name: 'turn.started',
          sequence: 1,
          runtimeTargetId: 'runtime-codex',
          sessionId: 'session-1',
          turnId: 'running',
          payload: {'status': 'inProgress'},
        ),
      );
      await tester.pump();
      final center = tester
          .getCenter(find.byKey(const ValueKey('message-composer-shell')))
          .dy;
      expect(
        tester.getCenter(find.byKey(const ValueKey('stop-turn'))).dy,
        center,
      );
      expect(
        tester.getCenter(find.byKey(const ValueKey('select-content'))).dy,
        center,
      );
      await tester.tap(find.byKey(const ValueKey('stop-turn')));
      await tester.pump();
      expect(core.interrupted, ('runtime-codex', 'session-1', 'running'));
    },
  );

  testWidgets('reduced motion shows and hides the sidebar without sliding', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(
      ZommiApp(
        core: RichFakeCore()..historyCount = 0,
        desktop: FakeDesktopBridge(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('toggle-sessions')));
    await tester.pump();
    expect(find.byKey(const ValueKey('session-sidebar')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('toggle-sessions')));
    await tester.pump();
    expect(find.byKey(const ValueKey('session-sidebar')), findsNothing);
  });

  for (final size in [
    const Size(640, 500),
    const Size(720, 620),
    const Size(920, 760),
  ]) {
    testWidgets(
      'sidebar stays open until toggled and keeps controls usable at $size',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final core = RichFakeCore()..historyCount = 0;
        await tester.pumpWidget(
          ZommiApp(core: core, desktop: FakeDesktopBridge()),
        );
        await tester.pumpAndSettle();
        final toggle = find.byKey(const ValueKey('toggle-sessions'));
        final sidebar = find.byKey(const ValueKey('session-sidebar'));
        final slide = find.byKey(const ValueKey('session-sidebar-slide'));
        final shell = find.byKey(const ValueKey('message-composer-shell'));
        final field = find.byKey(const ValueKey('zommi-composer'));
        final fullComposer = tester.getRect(shell);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(tester.getCenter(toggle));
        await tester.pump(const Duration(seconds: 1));
        expect(sidebar, findsNothing);
        expect(find.byKey(const ValueKey('shortcut-status')), findsNothing);
        expect(find.textContaining('Alt+'), findsNothing);
        await tester.tap(toggle);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 90));
        final openingWidth = tester.getSize(slide).width;
        expect(openingWidth, greaterThan(0));
        await tester.pumpAndSettle();
        expect(tester.getSize(slide).width, greaterThan(openingWidth));
        expect(tester.getRect(sidebar).left, 0);
        expect(
          tester.getRect(sidebar).right,
          lessThan(tester.getRect(shell).left),
        );
        await mouse.moveTo(tester.getCenter(field));
        await tester.pump(const Duration(seconds: 1));
        await tester.enterText(field, 'First line\nSecond line\nThird line');
        await tester.pumpAndSettle();
        expect(sidebar, findsOneWidget);
        for (final key in ['select-content', 'send-message']) {
          expect(
            tester.getCenter(find.byKey(ValueKey(key))).dy,
            tester.getCenter(shell).dy,
          );
        }
        await tester.tap(find.byKey(const ValueKey('workspace-summary')));
        await tester.pumpAndSettle();
        final workspace = tester.getRect(
          find.byKey(const ValueKey('workspace-panel')),
        );
        expect(workspace.left, greaterThanOrEqualTo(0));
        expect(workspace.right, lessThanOrEqualTo(size.width));
        expect(workspace.bottom, lessThanOrEqualTo(size.height));
        await tester.tap(find.byTooltip('Close workspace'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('workspace-panel')), findsNothing);
        expect(sidebar, findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('session-session-2')));
        await tester.pumpAndSettle();
        expect(core.activeSessionId, 'session-2');
        expect(sidebar, findsOneWidget);
        expect(
          tester.widget<TextField>(field).controller!.text,
          contains('First line'),
        );
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(sidebar, findsNothing);
        expect(tester.getRect(shell).width, fullComposer.width);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Escape closes the sidebar and keyboard activation toggles it', (
    tester,
  ) async {
    await tester.pumpWidget(
      ZommiApp(
        core: RichFakeCore()..historyCount = 0,
        desktop: FakeDesktopBridge(),
      ),
    );
    await tester.pumpAndSettle();
    final button = find.descendant(
      of: find.byKey(const ValueKey('toggle-sessions')),
      matching: find.byType(IconButton),
    );
    final focus = Focus.of(
      tester.element(find.descendant(of: button, matching: find.byType(Icon))),
    );
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('session-sidebar')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('session-sidebar')), findsNothing);
  });

  test('shortcut and button share one pending picker; cancellation keeps existing content', () async {
    final pending = Completer<ContextAttachment?>();
    final desktop = FakeDesktopBridge()..selectionGate = pending.future;
    final core = RichFakeCore()..historyCount = 0;
    final controller = ZommiController(core: core, desktop: desktop);
    addTearDown(controller.close);
    await controller.initialize();
    controller.addAttachment(
      ContextAttachment(
        id: 'existing',
        token: '',
        snapshot: {
          'selection': ['Keep me'],
        },
      ),
    );
    desktop.emit(
      const DesktopInvocation(kind: DesktopInvocationKind.selectContent),
    );
    desktop.emit(
      const DesktopInvocation(kind: DesktopInvocationKind.selectContent),
    );
    await controller.addPointerContext();
    expect(controller.selectingContent, isTrue);
    expect(
      desktop.calls.where((call) => call == 'selectPointerContext'),
      hasLength(1),
    );
    await controller.submit('Do not send before confirmation');
    expect(core.lastMessage, isNull);
    pending.complete(null);
    await Future<void>.delayed(Duration.zero);
    expect(controller.selectingContent, isFalse);
    expect(controller.attachments.single.id, 'existing');
    expect(desktop.calls.last, 'showPanel');
    desktop.selectionGate = null;
    desktop.nextSelections = [
      for (final id in ['a', 'b'])
        ContextAttachment(
          id: id,
          token: '',
          snapshot: {
            'selection': [id],
          },
        ),
    ];
    desktop.emit(
      const DesktopInvocation(kind: DesktopInvocationKind.selectContent),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.attachments.map((item) => item.id), [
      'existing',
      'a',
      'b',
    ]);
  });
}
