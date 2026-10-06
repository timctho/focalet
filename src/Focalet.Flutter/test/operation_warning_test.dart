import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focalet_flutter/desktop/desktop_bridge.dart';
import 'package:focalet_flutter/state/focalet_models.dart';
import 'package:focalet_flutter/focalet_app.dart';

import 'test_support.dart';

void main() {
  for (final width in [760.0, 1440.0]) {
    testWidgets('dismissible error matches composer at width $width', (
      tester,
    ) async {
      final desktop = FakeDesktopBridge();
      await tester.binding.setSurfaceSize(Size(width, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        FocaletApp(core: RichFakeCore(), desktop: desktop),
      );
      await tester.pumpAndSettle();
      final composer = find.byKey(const ValueKey('focalet-composer'));
      await tester.enterText(composer, 'keep this draft');
      for (final sidebarOpen in [true, false]) {
        if (!sidebarOpen) {
          await tester.tap(find.byKey(const ValueKey('toggle-sessions')));
          await tester.pumpAndSettle();
        }
        desktop.emit(
          const DesktopInvocation(
            kind: DesktopInvocationKind.status,
            message: 'Something failed. You can retry.',
            warning: true,
          ),
        );
        await tester.pumpAndSettle();
        final banner = find.byKey(const ValueKey('operation-warning'));
        final warningRect = tester.getRect(banner);
        final inputRect = tester.getRect(
          find.byKey(const ValueKey('message-composer-shell')),
        );
        expect(warningRect.left, closeTo(inputRect.left, 0.1));
        expect(warningRect.right, closeTo(inputRect.right, 0.1));
        await tester.tap(
          find.byKey(const ValueKey('dismiss-operation-warning')),
        );
        await tester.pumpAndSettle();
        expect(banner, findsNothing);
        expect(
          tester.widget<TextField>(composer).controller!.text,
          'keep this draft',
        );
      }
    });
  }

  Future<void> showApp(
    WidgetTester tester,
    RichFakeCore core,
    FakeDesktopBridge desktop,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(FocaletApp(core: core, desktop: desktop));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'failed startup is visible and settings expose Mac capture permissions',
    (tester) async {
      final core = RichFakeCore()
        ..connectErrorCode = 'session-not-found'
        ..connectErrorMessage = 'The selected chat no longer exists.';
      final desktop = FakeDesktopBridge()..supportsCapturePermissions = true;
      await showApp(tester, core, desktop);
      expect(find.byKey(const ValueKey('operation-warning')), findsOneWidget);
      expect(
        find.textContaining('The selected chat no longer exists.'),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('App settings'));
      await tester.pumpAndSettle();
      expect(find.text('Screen Recording · images'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('allow-screenRecording')));
      await tester.pumpAndSettle();
      expect(find.text('Allow screenshots'), findsOneWidget);
      expect(desktop.permissionRequests, isEmpty);
      await tester.tap(find.text('Open System Settings'));
      await tester.pumpAndSettle();
      expect(desktop.permissionRequests, ['screenRecording']);
    },
  );

  testWidgets(
    'capture failure is visible and a subsequent successful capture clears it',
    (tester) async {
      final desktop = FakeDesktopBridge();
      await showApp(tester, RichFakeCore(), desktop);
      final selection = Completer<Never>();
      desktop.selectionGate = selection.future;
      await tester.tap(find.byKey(const ValueKey('select-content')));
      await tester.pump();
      selection.completeError(
        StateError('Allow Screen Recording for Focalet.'),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Allow Screen Recording for Focalet.'),
        findsOneWidget,
      );
      expect(desktop.calls, contains('showPanel'));
      desktop.selectionGate = null;
      desktop.nextContext = ContextAttachment(
        id: 'selection',
        token: '',
        previewText: 'Selected context',
        snapshot: {'application': 'TextEdit'},
      );
      await tester.tap(find.byKey(const ValueKey('select-content')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('operation-warning')), findsNothing);
    },
  );
}
