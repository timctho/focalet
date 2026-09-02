import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/zommi_app.dart';

void main() {
  test('surface bloom has symmetric exact endpoints and layers', () {
    expect(
      surfaceTransitionSize(
        const Size(compactOrbSize, compactOrbSize),
        const Size(expandedPanelWidth, expandedPanelHeight),
        0,
      ),
      const Size(compactOrbSize, compactOrbSize),
    );
    expect(
      surfaceTransitionSize(
        const Size(compactOrbSize, compactOrbSize),
        const Size(expandedPanelWidth, expandedPanelHeight),
        1,
      ),
      const Size(expandedPanelWidth, expandedPanelHeight),
    );
    final forward = surfaceTransitionSize(
      compactWindowSize,
      normalWindowSize,
      0.35,
    );
    final reverse = surfaceTransitionSize(
      normalWindowSize,
      compactWindowSize,
      0.65,
    );
    expect(forward.width, closeTo(reverse.width, 0.001));
    expect(forward.height, closeTo(reverse.height, 0.001));
    expect(
      surfaceTransitionCompactness(compactWindowSize, normalWindowSize, 0.35),
      closeTo(
        surfaceTransitionCompactness(normalWindowSize, compactWindowSize, 0.65),
        0.001,
      ),
    );
    final start = surfaceTransitionVisuals(
      compactWindowSize,
      normalWindowSize,
      0,
    );
    final end = surfaceTransitionVisuals(
      compactWindowSize,
      normalWindowSize,
      1,
    );
    expect(start.orbOpacity, 1);
    expect(start.orbScale, 1);
    expect(start.panelOpacity, 0);
    expect(end.orbOpacity, 0);
    expect(end.orbScale, 1);
    expect(end.panelOpacity, 1);
    for (final progress in <double>[0.1, 0.25, 0.5, 0.75, 0.9]) {
      final forward = surfaceTransitionVisuals(
        compactWindowSize,
        normalWindowSize,
        progress,
      );
      final reverse = surfaceTransitionVisuals(
        normalWindowSize,
        compactWindowSize,
        1 - progress,
      );
      expect(forward.orbOpacity, closeTo(reverse.orbOpacity, 0.000001));
      expect(forward.orbScale, closeTo(reverse.orbScale, 0.000001));
      expect(forward.panelOpacity, closeTo(reverse.panelOpacity, 0.000001));
      expect(forward.panelScale, closeTo(reverse.panelScale, 0.000001));
    }
  });

  test('replacement orb instances share one animation phase', () {
    final instant = DateTime.fromMicrosecondsSinceEpoch(3_850_000);
    expect(synchronizedOrbPhase(instant), closeTo(0.75, 0.000001));
    expect(
      synchronizedOrbPhase(instant.add(const Duration(milliseconds: 1400))),
      closeTo(0.75, 0.000001),
    );
  });

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
    expect(find.byType(ZommiOrb), findsNothing);
    expect(find.byKey(const ValueKey('zommi-composer')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('zommi-surface'))),
      const Size(expandedPanelWidth, expandedPanelHeight),
    );
    final composer = tester.widget<TextField>(
      find.byKey(const ValueKey('zommi-composer')),
    );
    expect(composer.focusNode?.hasFocus, isTrue);
    expect(find.text('Codex 9.8.7 ready'), findsOneWidget);
  });

  testWidgets('composer remains editable while Rust starts the Codex turn', (
    tester,
  ) async {
    await _setDesktopSurface(tester);
    final pending = Completer<TurnReceipt>();
    final core = FakeCoreBridge(turn: pending.future);
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

    pending.complete(
      const TurnReceipt(
        accepted: true,
        runtimeTargetId: 'runtime-codex',
        sessionId: 'thread-codex',
        turnId: 'turn-codex',
        clientOperationId: 'client:test',
      ),
    );
    await tester.pump();
    expect(find.bySemanticsLabel('Exact agent session bound'), findsOneWidget);
    expect(find.text('draft while processing'), findsOneWidget);
  });

  testWidgets('stop during startup reaches the exact runtime turn', (
    tester,
  ) async {
    await _setDesktopSurface(tester);
    final pending = Completer<TurnReceipt>();
    final core = FakeCoreBridge(turn: pending.future);
    await tester.pumpWidget(ZommiApp(core: core));
    await tester.pump();
    await _expand(tester);
    await tester.enterText(
      find.byKey(const ValueKey('zommi-composer')),
      'cancel immediately',
    );
    await tester.tap(find.byKey(const ValueKey('send-message')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('stop-turn')));
    await tester.pump();
    expect(core.interruptedIdentity, isNull);
    expect(find.byIcon(Icons.hourglass_top_rounded), findsOneWidget);

    pending.complete(
      const TurnReceipt(
        accepted: true,
        runtimeTargetId: 'runtime-codex',
        sessionId: 'thread-codex',
        turnId: 'exact-runtime-turn',
        clientOperationId: 'client:test',
      ),
    );
    await tester.pumpAndSettle();
    expect(core.interruptedIdentity, (
      'runtime-codex',
      'thread-codex',
      'exact-runtime-turn',
    ));
  });

  testWidgets('stream events render and stop targets the exact active turn', (
    tester,
  ) async {
    await _setDesktopSurface(tester);
    final core = FakeCoreBridge();
    await tester.pumpWidget(ZommiApp(core: core));
    await tester.pump();
    await _expand(tester);

    await tester.enterText(
      find.byKey(const ValueKey('zommi-composer')),
      'keep working',
    );
    await tester.tap(find.byKey(const ValueKey('send-message')));
    await tester.pump();
    core.emit(
      const CoreEvent(
        name: 'turn.started',
        sequence: 1,
        runtimeTargetId: 'runtime-codex',
        sessionId: 'thread-codex',
        turnId: 'turn-codex',
        clientOperationId: 'client:test',
        payload: {'status': 'inProgress'},
      ),
    );
    core.emit(
      const CoreEvent(
        name: 'item.update',
        sequence: 2,
        runtimeTargetId: 'runtime-codex',
        sessionId: 'thread-codex',
        turnId: 'turn-codex',
        clientOperationId: 'client:test',
        payload: {
          'kind': 'assistant',
          'lifecycle': 'delta',
          'title': 'Codex',
          'text': 'streamed answer',
          'itemId': 'agent-1',
        },
      ),
    );
    await tester.pump();

    expect(find.text('streamed answer'), findsOneWidget);
    expect(find.byKey(const ValueKey('stop-turn')), findsOneWidget);
    expect(find.byKey(const ValueKey('send-message')), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('zommi-composer')),
      'draft while streaming',
    );
    expect(find.text('draft while streaming'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('stop-turn')));
    await tester.pump();
    expect(core.interruptedIdentity, (
      'runtime-codex',
      'thread-codex',
      'turn-codex',
    ));

    core.emit(
      const CoreEvent(
        name: 'turn.completed',
        sequence: 3,
        runtimeTargetId: 'runtime-codex',
        sessionId: 'thread-codex',
        turnId: 'turn-codex',
        clientOperationId: 'client:test',
        payload: {'status': 'interrupted'},
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('stop-turn')), findsNothing);
    expect(find.text('Codex turn stopped'), findsOneWidget);
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

  testWidgets('hover collapse waits 500 ms and returns to the anchored orb', (
    tester,
  ) async {
    await _setDesktopSurface(tester);
    await tester.pumpWidget(ZommiApp(core: FakeCoreBridge()));
    await tester.pump();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('zommi-surface'))),
    );
    await tester.pumpAndSettle();
    await mouse.moveTo(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 499));
    expect(
      tester.getSize(find.byKey(const ValueKey('zommi-surface'))),
      const Size(expandedPanelWidth, expandedPanelHeight),
    );
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const ValueKey('zommi-surface'))),
      const Size(compactOrbSize, compactOrbSize),
    );
  });

  testWidgets('reduced motion freezes the working orb', (tester) async {
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(
      tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );
    await _setDesktopSurface(tester);
    final core = FakeCoreBridge();
    await tester.pumpWidget(ZommiApp(core: core));
    await tester.pump();
    core.emit(
      const CoreEvent(
        name: 'turn.started',
        sequence: 1,
        runtimeTargetId: 'runtime-codex',
        sessionId: 'thread-codex',
        turnId: 'turn-codex',
        payload: {'status': 'inProgress'},
      ),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(find.byKey(const ValueKey('zommi-orb-canvas')), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('compact orb matches the migration UX baseline', (tester) async {
    await _setDesktopSurface(tester);
    await tester.pumpWidget(ZommiApp(core: FakeCoreBridge()));
    await tester.pump();
    await expectLater(
      find.byType(ZommiShell),
      matchesGoldenFile('goldens/zommi_shell_compact.png'),
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
  FakeCoreBridge({Future<TurnReceipt>? turn})
    : _turn =
          turn ??
          Future<TurnReceipt>.value(
            const TurnReceipt(
              accepted: true,
              runtimeTargetId: 'runtime-codex',
              sessionId: 'thread-codex',
              turnId: 'turn-codex',
              clientOperationId: 'client:test',
            ),
          );

  final Future<TurnReceipt> _turn;
  final StreamController<CoreEvent> _events =
      StreamController<CoreEvent>.broadcast(sync: true);
  String? lastMessage;
  (String, String, String)? interruptedIdentity;

  @override
  Stream<CoreEvent> get events => _events.stream;

  void emit(CoreEvent event) => _events.add(event);

  @override
  Future<String> buildContextHandoff({
    required String message,
    List<Map<String, Object?>> snapshots = const [],
    int imageCount = 0,
  }) {
    lastMessage = message;
    return Future<String>.value('prepared handoff');
  }

  @override
  Future<void> close() => _events.close();

  @override
  Future<RuntimeConnection> connectRuntime({
    required String runtimeTargetId,
    String? preferredSessionId,
    String? cwd,
  }) async => const RuntimeConnection(
    runtimeTargetId: 'runtime-codex',
    sessionId: 'thread-codex',
    protocolVersion: 1,
    runtimeVersion: '9.8.7',
    models: [],
    sessions: [],
    capabilities: [],
  );

  @override
  Future<RuntimeConnection> createSession({
    required String runtimeTargetId,
    String? model,
    String? effort,
  }) => connectRuntime(runtimeTargetId: runtimeTargetId);

  @override
  Future<RuntimeDiscovery> discoverRuntimeTargets({
    String? lastSelectedTargetId,
  }) async => const RuntimeDiscovery(
    targets: [
      RuntimeTarget(
        id: 'runtime-codex',
        runtimeId: 'codex',
        adapterId: 'codex-app-server',
        displayName: 'Codex',
        protocolName: 'Codex app-server',
        executablePath: '/bin/codex',
        executionHost: {'id': 'native:linux'},
      ),
    ],
    selectedTargetId: 'runtime-codex',
  );

  @override
  Future<CoreStatus> initialize() async => const CoreStatus(
    version: '0.1.0',
    protocolVersion: coreProtocolVersion,
    capabilities: ['context.handoff.v1'],
  );

  @override
  Future<void> interruptTurn({
    required String runtimeTargetId,
    required String sessionId,
    required String turnId,
  }) async {
    interruptedIdentity = (runtimeTargetId, sessionId, turnId);
  }

  @override
  Future<List<Map<String, Object?>>> listSessions({
    required String runtimeTargetId,
  }) async => const [];

  @override
  Future<RuntimeConnection> openSession({
    required String runtimeTargetId,
    required String sessionId,
  }) => connectRuntime(
    runtimeTargetId: runtimeTargetId,
    preferredSessionId: sessionId,
  );

  @override
  Future<Map<String, Object?>> readSession({
    required String runtimeTargetId,
    required String sessionId,
  }) async => <String, Object?>{
    'thread': <String, Object?>{'id': sessionId},
  };

  @override
  Future<void> resolveApproval({
    required String runtimeTargetId,
    required String sessionId,
    required String approvalId,
    String? optionId,
  }) async {}

  @override
  Future<void> resolveQuestion({
    required String runtimeTargetId,
    required String sessionId,
    required String questionId,
    required Map<String, Object?> answer,
  }) async {}

  @override
  Future<void> steerTurn({
    required String runtimeTargetId,
    required String sessionId,
    required String turnId,
    required String message,
    List<String> images = const [],
  }) async {}

  @override
  Future<TurnReceipt> startTurn({
    required String runtimeTargetId,
    required String sessionId,
    required String message,
    List<Map<String, Object?>> snapshots = const [],
    List<String> images = const [],
    String? clientOperationId,
    String? model,
    String? effort,
  }) {
    lastMessage = message;
    return _turn;
  }
}
