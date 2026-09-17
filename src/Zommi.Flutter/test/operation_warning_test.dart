import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'test_support.dart';

void main() {
  Future<void> showApp(
    WidgetTester tester,
    RichFakeCore core,
    FakeDesktopBridge desktop,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ZommiApp(core: core, desktop: desktop));
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
      selection.completeError(StateError('Allow Screen Recording for Zommi.'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Allow Screen Recording for Zommi.'),
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
