import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/zommi_app.dart';

void main() {
  testWidgets('quiet orb expands into the anchored composer on hover', (
    tester,
  ) async {
    await _setDesktopSurface(tester);
    final core = FakeCoreBridge();
    await tester.pumpWidget(ZommiApp(core: core));
    await tester.pump();

    expect(find.bySemanticsLabel('ZommiOrb'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('zommi-surface'))),
      const Size(compactOrbSize, compactOrbSize),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('zommi-surface'))),
    );
    await tester.pumpAndSettle();

    expect(find.text('Point, ask, keep moving.'), findsOneWidget);
    expect(find.byKey(const ValueKey('zommi-composer')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('zommi-surface'))),
      const Size(expandedPanelWidth, expandedPanelHeight),
    );
    final composer = tester.widget<TextField>(
      find.byKey(const ValueKey('zommi-composer')),
    );
    expect(composer.focusNode?.hasFocus, isTrue);
    expect(find.text('Rust core 0.1.0 ready'), findsOneWidget);
  });

  testWidgets('composer remains editable while Rust prepares the handoff', (
    tester,
  ) async {
    await _setDesktopSurface(tester);
    final pending = Completer<String>();
    final core = FakeCoreBridge(handoff: pending.future);
    await tester.pumpWidget(ZommiApp(core: core));
    await tester.pump();
    await _expand(tester);

    final composer = find.byKey(const ValueKey('zommi-composer'));
    await tester.enterText(composer, 'compare this');
    await tester.tap(find.byKey(const ValueKey('send-message')));
    await tester.pump();
    expect(core.lastMessage, 'compare this');
    expect(find.text('compare this'), findsOneWidget);

    await tester.enterText(composer, 'draft while processing');
    final field = tester.widget<TextField>(composer);
    expect(field.enabled, isNot(false));
    expect(find.text('draft while processing'), findsOneWidget);

    pending.complete('prepared handoff');
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Core handoff prepared'), findsOneWidget);
    expect(find.text('draft while processing'), findsOneWidget);
  });

  testWidgets('expanded shell matches the migration UX baseline', (
    tester,
  ) async {
    await _setDesktopSurface(tester);
    await tester.pumpWidget(ZommiApp(core: FakeCoreBridge()));
    await tester.pump();
    await _expand(tester);
    await expectLater(
      find.byType(ZommiShell),
      matchesGoldenFile('goldens/zommi_shell_expanded.png'),
    );
  });
}

Future<void> _setDesktopSurface(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(900, 760));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

Future<void> _expand(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(mouse.removePointer);
  await mouse.addPointer(location: Offset.zero);
  await mouse.moveTo(
    tester.getCenter(find.byKey(const ValueKey('zommi-surface'))),
  );
  await tester.pumpAndSettle();
}

final class FakeCoreBridge implements CoreBridge {
  FakeCoreBridge({Future<String>? handoff})
    : _handoff = handoff ?? Future<String>.value('prepared handoff');

  final Future<String> _handoff;
  String? lastMessage;

  @override
  Future<String> buildContextHandoff({
    required String message,
    List<Map<String, Object?>> snapshots = const [],
    int imageCount = 0,
  }) {
    lastMessage = message;
    return _handoff;
  }

  @override
  Future<void> close() async {}

  @override
  Future<CoreStatus> initialize() async => const CoreStatus(
    version: '0.1.0',
    protocolVersion: coreProtocolVersion,
    capabilities: ['context.handoff.v1'],
  );
}
