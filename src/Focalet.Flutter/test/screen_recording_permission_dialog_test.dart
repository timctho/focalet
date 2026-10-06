import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focalet_flutter/desktop/capture_permissions.dart';
import 'package:focalet_flutter/desktop/desktop_bridge.dart';
import 'package:focalet_flutter/focalet_app.dart';

import 'test_support.dart';

void main() {
  Future<FakeDesktopBridge> showApp(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(640, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final desktop = FakeDesktopBridge()
      ..supportsCapturePermissions = true
      ..grantPermissionOnRequest = false;
    await tester.pumpWidget(FocaletApp(core: RichFakeCore(), desktop: desktop));
    await tester.pumpAndSettle();
    return desktop;
  }

  testWidgets(
    'Select explains access before any OS request; cancel leaves capture untouched',
    (tester) async {
      final desktop = await showApp(tester);
      await tester.tap(find.byKey(const ValueKey('select-content')));
      await tester.pumpAndSettle();
      expect(find.text('Allow screenshots'), findsOneWidget);
      expect(find.textContaining('turn on Focalet'), findsOneWidget);
      expect(find.textContaining('Quit & Reopen'), findsOneWidget);
      expect(desktop.permissionRequests, isEmpty);
      expect(desktop.calls, isNot(contains('selectPointerContext')));
      expect(tester.takeException(), isNull);

      // Repeated shortcut invocations must not stack consent dialogs.
      desktop.emit(
        const DesktopInvocation(kind: DesktopInvocationKind.selectContent),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('screen-recording-permission-dialog')),
        findsOneWidget,
      );
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(desktop.permissionRequests, isEmpty);
      expect(desktop.calls, isNot(contains('selectPointerContext')));
      expect(find.byKey(const ValueKey('operation-warning')), findsNothing);
    },
  );

  testWidgets(
    'shortcut shows guidance; explicit action opens settings; return rechecks without capturing',
    (tester) async {
      final desktop = await showApp(tester);
      desktop.emit(
        const DesktopInvocation(kind: DesktopInvocationKind.selectContent),
      );
      await tester.pumpAndSettle();
      expect(desktop.calls, contains('showPanel'));
      await tester.tap(find.text('Open System Settings'));
      await tester.pumpAndSettle();
      expect(desktop.permissionRequests, ['screenRecording']);
      expect(desktop.calls, isNot(contains('selectPointerContext')));
      await tester.tap(find.text('Check again'));
      await tester.pumpAndSettle();
      expect(find.text('Allow screenshots'), findsOneWidget);
      expect(find.textContaining('quit and reopen Focalet'), findsOneWidget);
      expect(desktop.permissionRequests, ['screenRecording']);
      expect(tester.takeException(), isNull);

      desktop.permissionStatus = const CapturePermissionStatus(
        accessibility: false,
        screenRecording: true,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Screenshots are ready'), findsOneWidget);
      expect(desktop.calls, isNot(contains('selectPointerContext')));
      await tester.tap(find.text('Start selecting'));
      await tester.pumpAndSettle();
      expect(
        desktop.calls.where((call) => call == 'selectPointerContext'),
        hasLength(1),
      );
      expect(
        find.byKey(const ValueKey('screen-recording-permission-dialog')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'already granted screen access selects directly without requesting Accessibility',
    (tester) async {
      final desktop = await showApp(tester);
      desktop.permissionStatus = const CapturePermissionStatus(
        accessibility: false,
        screenRecording: true,
      );
      await tester.tap(find.byKey(const ValueKey('select-content')));
      await tester.pumpAndSettle();
      expect(desktop.calls, contains('selectPointerContext'));
      expect(desktop.permissionRequests, isEmpty);
      expect(
        find.byKey(const ValueKey('screen-recording-permission-dialog')),
        findsNothing,
      );
    },
  );
}
