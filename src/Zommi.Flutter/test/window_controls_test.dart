import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_manager/window_manager.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'test_support.dart';

void main() {
  testWidgets('double-clicking the top bar maximizes and restores', (
    tester,
  ) async {
    final desktop = FakeDesktopBridge();
    await tester.pumpWidget(
      ZommiApp(core: RichFakeCore()..historyCount = 0, desktop: desktop),
    );
    await tester.pumpAndSettle();
    final header = tester.getRect(
      find.byKey(const ValueKey('window-drag-region')),
    );
    final blankSpace = Offset(header.center.dx, header.top + 6);
    for (final label in ['Restore Zommi', 'Maximize Zommi']) {
      await tester.tapAt(blankSpace);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(blankSpace);
      await tester.pumpAndSettle();
      expect(find.byTooltip(label), findsOneWidget);
    }
    expect(
      desktop.calls.where((call) => call == 'toggleMaximized'),
      hasLength(2),
    );
    expect(desktop.calls, isNot(contains('startDragging')));
    // Clicking a title-bar control must not also maximize the window.
    await tester.tap(find.byTooltip('App settings'));
    await tester.pumpAndSettle();
    expect(find.text('App settings'), findsOneWidget);
    expect(
      desktop.calls.where((call) => call == 'toggleMaximized'),
      hasLength(2),
    );
  });

  testWidgets('each corner starts the corresponding native resize', (
    tester,
  ) async {
    const channel = MethodChannel('window_manager');
    final resizes = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'startResizing') {
        resizes.add((call.arguments as Map)['resizeEdge'] as String);
        return true;
      }
      return false;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(
      ZommiApp(
        core: RichFakeCore()..historyCount = 0,
        desktop: FakeDesktopBridge(),
      ),
    );
    await tester.pumpAndSettle();
    final bounds = tester.getRect(find.byKey(const ValueKey('zommi-surface')));
    for (final (point, delta) in [
      (bounds.topLeft + const Offset(8, 8), const Offset(-40, -40)),
      (bounds.topRight + const Offset(-8, 8), const Offset(40, -40)),
      (bounds.bottomLeft + const Offset(8, -8), const Offset(-40, 40)),
      (bounds.bottomRight + const Offset(-8, -8), const Offset(40, 40)),
    ]) {
      await tester.dragFrom(point, delta);
      await tester.pump();
    }
    expect(resizes, ['topLeft', 'topRight', 'bottomLeft', 'bottomRight']);
    await tester.tap(find.byTooltip('Maximize Zommi'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DragToResizeArea>(find.byType(DragToResizeArea))
          .enableResizeEdges,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('system maximize and restore events update the header', (
    tester,
  ) async {
    final desktop = FakeDesktopBridge();
    await tester.pumpWidget(
      ZommiApp(core: RichFakeCore()..historyCount = 0, desktop: desktop),
    );
    await tester.pumpAndSettle();
    desktop.calls.clear();
    for (final maximized in [true, false]) {
      desktop.emit(
        DesktopInvocation(
          kind: DesktopInvocationKind.windowState,
          maximized: maximized,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byTooltip(maximized ? 'Restore Zommi' : 'Maximize Zommi'),
        findsOneWidget,
      );
      final edges = tester
          .widget<DragToResizeArea>(find.byType(DragToResizeArea))
          .enableResizeEdges!;
      expect(edges.length, maximized ? 0 : 4);
    }
    expect(desktop.calls, isEmpty);
  });
}
