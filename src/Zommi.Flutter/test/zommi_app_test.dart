import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'golden_support.dart';

void main() {
  testWidgets('taskbar shell starts expanded and never renders an orb', (
    tester,
  ) async {
    await _setDesktopSurface(tester);
    await tester.pumpWidget(ZommiApp(core: FakeCoreBridge()));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('zommi-orb')), findsNothing);
    expect(find.bySemanticsLabel('ZommiOrb'), findsNothing);
    expect(find.byKey(const ValueKey('zommi-composer')), findsOneWidget);
    expect(find.text('Point, ask, keep moving.'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('zommi-surface'))),
      const Size(900, 760),
    );
    expect(find.byKey(const ValueKey('core-status')), findsNothing);
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
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('zommi-transcript')),
        matching: find.text('compare this'),
      ),
      findsOneWidget,
    );

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
    // The runtime stays active until completion, including its sidebar spinner.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
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
    expect(find.byTooltip('Queue message (Enter)'), findsNothing);
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
    expect(find.byKey(const ValueKey('send-message')), findsOneWidget);
    expect(find.byKey(const ValueKey('core-status')), findsNothing);
  });

  testWidgets('expanded shell matches the migration UX baseline', (
    tester,
  ) async {
    await _setDesktopSurface(tester);
    await tester.pumpWidget(ZommiApp(core: FakeCoreBridge()));
    await tester.pump();
    await _expand(tester);
    await tester.runAsync(
      () => precacheImage(
        const AssetImage('assets/runtime_icons/codex.png'),
        tester.element(find.byType(ZommiShell)),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(ZommiShell),
      matchesGoldenFile(platformGoldenPath('zommi_shell_expanded.png')),
    );
  });

  testWidgets(
    'working state stays in the taskbar window without orb fallback',
    (tester) async {
      await _setDesktopSurface(tester);
      final core = FakeCoreBridge();
      await tester.pumpWidget(ZommiApp(core: core));
      await tester.pumpAndSettle();
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
      await tester.pump();

      expect(find.byKey(const ValueKey('zommi-orb')), findsNothing);
      expect(find.byKey(const ValueKey('zommi-composer')), findsOneWidget);
      expect(find.byKey(const ValueKey('stop-turn')), findsOneWidget);
    },
  );
}

Future<void> _setDesktopSurface(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(900, 760));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

Future<void> _expand(WidgetTester tester) async {
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
    String? cwd,
    String? profile,
  }) => connectRuntime(runtimeTargetId: runtimeTargetId);

  @override
  Future<RuntimeConnection> configureSession({
    required String runtimeTargetId,
    required String sessionId,
    String? cwd,
    String? profile,
    String? model,
    String? effort,
  }) => connectRuntime(
    runtimeTargetId: runtimeTargetId,
    preferredSessionId: sessionId,
    cwd: cwd,
  );

  @override
  Future<RuntimeDiscovery> discoverRuntimeTargets({
    String? lastSelectedTargetId,
    bool force = false,
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
    String? cwd,
    String? profile,
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
    String? cwd,
    String? profile,
  }) {
    lastMessage = message;
    return _turn;
  }
}
