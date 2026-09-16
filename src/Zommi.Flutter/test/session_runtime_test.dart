import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/widgets/runtime_logo.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'test_support.dart';

const hermes = RuntimeTarget(
  id: 'runtime-hermes',
  runtimeId: 'hermes',
  adapterId: 'hermes-gateway',
  displayName: 'Hermes',
  protocolName: 'Hermes Gateway',
  executablePath: '/usr/bin/hermes',
  executionHost: {
    'id': 'native:linux',
    'kind': 'native',
    'displayName': 'Linux',
  },
  capabilityHints: RichFakeCore.capabilities,
);

RichFakeCore multiRuntimeCore() => RichFakeCore()
  ..historyCount = 0
  ..discoveredTargets.add(hermes)
  ..modelCatalogByRuntime[hermes.id] = [
    {
      'model': 'hermes-model',
      'displayName': 'Hermes model',
      'isDefault': true,
      'supportedReasoningEfforts': ['low', 'high'],
    },
  ];

void main() {
  test(
    'sessions sort by recency across runtimes and timestamp formats',
    () async {
      final core = multiRuntimeCore()
        ..sessionsByRuntime['runtime-codex'] = [
          {'id': 'session-2', 'updatedAt': '2026-09-01T08:00:00Z'},
          {
            'id': 'session-1',
            'updatedAt':
                DateTime.utc(2026, 9, 3).millisecondsSinceEpoch ~/ 1000,
          },
        ]
        ..sessionsByRuntime[hermes.id] = [
          {'id': 'session-2', 'updatedAt': 'unknown'},
          {
            'id': 'session-1',
            'updatedAt': DateTime.utc(2026, 9, 2).millisecondsSinceEpoch,
          },
        ];
      final controller = ZommiController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      await controller.selectRuntime(hermes.id);
      List<(String, String)> order() => controller.sessions
          .map((session) => (session.runtimeTargetId, session.id))
          .toList();
      final initialOrder = [
        ('runtime-codex', 'session-1'),
        (hermes.id, 'session-1'),
        ('runtime-codex', 'session-2'),
        (hermes.id, 'session-2'),
      ];
      expect(order(), initialOrder);
      await controller.switchSession(
        'session-2',
        runtimeTargetId: 'runtime-codex',
      );
      expect(
        order(),
        initialOrder,
        reason: 'Opening an older chat is not a new response',
      );
      core.emit(
        const CoreEvent(
          name: 'item.update',
          sequence: 1,
          runtimeTargetId: 'runtime-hermes',
          sessionId: 'session-2',
          turnId: 'hermes-reply',
          payload: {
            'kind': 'assistant',
            'text': 'New response',
            'lifecycle': 'streaming',
          },
        ),
      );
      expect(order().first, (hermes.id, 'session-2'));
      core.emit(
        const CoreEvent(
          name: 'turn.completed',
          sequence: 2,
          runtimeTargetId: 'runtime-hermes',
          sessionId: 'session-2',
          turnId: 'hermes-reply',
          payload: {'status': 'completed'},
        ),
      );
      await controller.switchSession('session-1', runtimeTargetId: hermes.id);
      expect(order().first, (
        hermes.id,
        'session-2',
      ), reason: 'Stale provider timestamps cannot undo a new reply');
      await controller.createSession(runtimeTargetId: 'runtime-codex');
      expect(order().first, ('runtime-codex', 'created-session'));
    },
  );

  test(
    'missing and equal response times retain their existing order',
    () async {
      final core = multiRuntimeCore()
        ..sessionsByRuntime['runtime-codex'] = [
          {'id': 'session-1', 'updatedAt': 'not-a-date'},
          {'id': 'session-2', 'updatedAt': '2026-09-01T00:00:00Z'},
          {
            'id': 'session-3',
            'updatedAt':
                DateTime.utc(2026, 9, 1).millisecondsSinceEpoch ~/ 1000,
          },
        ];
      final controller = ZommiController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      expect(controller.sessions.map((session) => session.id), [
        'session-2',
        'session-3',
        'session-1',
      ]);
      await controller.switchSession('session-3');
      expect(controller.sessions.map((session) => session.id), [
        'session-2',
        'session-3',
        'session-1',
      ]);
    },
  );

  test(
    'new chats bind their runtime and restore independent settings',
    () async {
      final core = multiRuntimeCore();
      final controller = ZommiController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      controller.setModel('fixture-mini');
      controller.setEffort('medium');
      await controller.setWorkspace('/work/codex');
      await controller.createSession();
      expect(core.createdSessions.last, {
        'runtimeTargetId': 'runtime-codex',
        'model': 'fixture-mini',
        'effort': 'medium',
        'cwd': '/work/codex',
        'profile': null,
      });

      controller.updateComposerValue(
        const TextEditingValue(text: 'Codex draft'),
      );
      await controller.createSession(runtimeTargetId: hermes.id);
      expect(core.createdSessions.last, {
        'runtimeTargetId': hermes.id,
        'model': null,
        'effort': null,
        'cwd': null,
        'profile': null,
      });
      expect(controller.activeRuntime?.id, hermes.id);
      expect(
        controller.sessions.where((s) => s.id == 'created-session'),
        hasLength(2),
      );
      expect(controller.selectedWorkspace, '/workspace/hermes');
      controller.setModel('hermes-model');
      controller.setEffort('low');
      await controller.setWorkspace('/work/hermes');
      controller.updateComposerValue(
        const TextEditingValue(text: 'Hermes draft'),
      );

      await controller.switchSession(
        'created-session',
        runtimeTargetId: 'runtime-codex',
      );
      expect(core.openedSessions.last, ('runtime-codex', 'created-session'));
      expect(controller.activeRuntime?.id, 'runtime-codex');
      expect(controller.selectedModel, 'fixture-mini');
      expect(controller.selectedEffort, 'medium');
      expect(controller.selectedWorkspace, '/work/codex');
      expect(controller.selectedProfile, isEmpty);

      await controller.switchSession(
        'created-session',
        runtimeTargetId: hermes.id,
      );
      expect(core.openedSessions.last, (hermes.id, 'created-session'));
      expect(controller.selectedModel, 'hermes-model');
      expect(controller.selectedEffort, 'low');
      expect(controller.selectedWorkspace, '/work/hermes');
      expect(controller.models.single['model'], 'hermes-model');
    },
  );

  test(
    'background activity and unread state use runtime plus session identity',
    () async {
      final core = multiRuntimeCore();
      final controller = ZommiController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      await controller.switchSession('session-2');
      core.emit(
        const CoreEvent(
          name: 'turn.started',
          sequence: 1,
          runtimeTargetId: 'runtime-codex',
          sessionId: 'session-2',
          turnId: 'codex-running',
          payload: {},
        ),
      );
      await controller.createSession(runtimeTargetId: hermes.id);
      await controller.switchSession('session-2', runtimeTargetId: hermes.id);
      expect(
        controller.presenceFor('session-2', runtimeTargetId: 'runtime-codex'),
        SessionPresence.running,
      );
      expect(
        controller.presenceFor('session-2', runtimeTargetId: hermes.id),
        SessionPresence.active,
      );
      core.emit(
        const CoreEvent(
          name: 'turn.completed',
          sequence: 2,
          runtimeTargetId: 'runtime-codex',
          sessionId: 'session-2',
          turnId: 'codex-running',
          payload: {'status': 'completed'},
        ),
      );
      expect(
        controller.presenceFor('session-2', runtimeTargetId: 'runtime-codex'),
        SessionPresence.unread,
      );
      expect(
        controller.presenceFor('session-2', runtimeTargetId: hermes.id),
        SessionPresence.active,
      );
      await controller.switchSession(
        'session-2',
        runtimeTargetId: 'runtime-codex',
      );
      expect(
        controller.presenceFor('session-2', runtimeTargetId: 'runtime-codex'),
        SessionPresence.active,
      );
      expect(
        controller.presenceFor('session-2', runtimeTargetId: hermes.id),
        SessionPresence.done,
      );
      expect(
        controller.sessions.where((s) => s.id == 'session-2'),
        hasLength(2),
      );
    },
  );

  test(
    'failed create or switch keeps the original chat and its settings',
    () async {
      final core = multiRuntimeCore();
      final controller = ZommiController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      await controller.setWorkspace('/work/original');
      final sessionsBefore = List.of(controller.sessions);
      core.createSessionFails = true;
      await controller.createSession(runtimeTargetId: hermes.id);
      expect(controller.activeRuntime?.id, 'runtime-codex');
      expect(controller.activeSessionId, 'session-1');
      expect(controller.selectedWorkspace, '/work/original');
      expect(controller.sessions, sessionsBefore);
      expect(controller.statusWarning, isTrue);
      expect(controller.sessionBusy, isFalse);
      core.openSessionFails = true;
      await controller.switchSession('session-2', runtimeTargetId: hermes.id);
      expect(controller.activeRuntime?.id, 'runtime-codex');
      expect(controller.activeSessionId, 'session-1');
      expect(controller.selectedWorkspace, '/work/original');
      expect(controller.sessions, sessionsBefore);
    },
  );

  test('pending creation rejects duplicate actions and messages to the previous chat', () async {
    final core = multiRuntimeCore();
    final controller = ZommiController(
      core: core,
      desktop: FakeDesktopBridge(),
    );
    addTearDown(controller.close);
    await controller.initialize();
    final gate = Completer<void>();
    core.createSessionGate = gate.future;
    final creating = controller.createSession();
    await controller.createSession(runtimeTargetId: hermes.id);
    await controller.switchSession('session-2');
    await controller.selectRuntime(hermes.id);
    await controller.submit('Do not route during switching');
    expect(core.createdSessions, hasLength(1));
    expect(core.openedSessions, isEmpty);
    expect(core.lastMessage, isNull);
    expect(controller.activeSessionId, 'session-1');
    gate.complete();
    await creating;
    expect(controller.activeSessionId, 'created-session');
    expect(controller.sessionBusy, isFalse);
  });

  test(
    'Agents remains reachable from a runtime without session navigation',
    () async {
      final core = multiRuntimeCore();
      final controller = ZommiController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      await controller.selectRuntime('runtime-claude');
      expect(controller.sessionNavigationSupported, isTrue);
      expect(controller.sessionCreationSupported, isTrue);
      expect(controller.modelSelectionSupported, isFalse);
      expect(controller.capabilities, ['turn.stream.v1']);
      await controller.switchSession(
        'session-1',
        runtimeTargetId: 'runtime-codex',
      );
      expect(controller.modelSelectionSupported, isTrue);
    },
  );

  for (final size in [const Size(640, 500), const Size(920, 760)]) {
    testWidgets('runtime dropdown creates and switches mixed chats at $size', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final core = multiRuntimeCore();
      await tester.pumpWidget(
        ZommiApp(core: core, desktop: FakeDesktopBridge()),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('runtime-summary')), findsNothing);
      expect(find.bySemanticsLabel('Choose agent runtime'), findsNothing);
      await tester.pumpAndSettle();
      final add = find.byKey(const ValueKey('new-session'));
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.text('New agent'), findsOneWidget);
      expect(core.createdSessions, isEmpty);
      final choice = find.byKey(
        const ValueKey('create-session-runtime-hermes'),
      );
      final bounds = tester.getRect(choice);
      expect(bounds.left, greaterThanOrEqualTo(0));
      expect(bounds.right, lessThanOrEqualTo(size.width));
      expect(bounds.bottom, lessThanOrEqualTo(size.height));
      expect(
        tester
            .widget<MenuItemButton>(
              find.byKey(const ValueKey('create-session-runtime-claude')),
            )
            .onPressed,
        isNull,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('New agent'), findsNothing);
      expect(find.byKey(const ValueKey('session-sidebar')), findsOneWidget);
      expect(core.createdSessions, isEmpty);
      await tester.tap(add);
      await tester.pumpAndSettle();
      await tester.tap(choice);
      await tester.pumpAndSettle();
      expect(core.activeTargetId, hermes.id);
      expect(core.activeSessionId, 'created-session');
      expect(find.byKey(const ValueKey('session-sidebar')), findsOneWidget);
      final original = find.byKey(
        const ValueKey('session-runtime-codex-session-1'),
      );
      expect(original, findsOneWidget);
      final logo = find.byKey(
        const ValueKey('session-runtime-runtime-codex-session-1'),
      );
      expect(tester.widget<RuntimeLogo>(logo).runtimeId, 'codex');
      final workspace = find.byKey(
        const ValueKey('session-workspace-runtime-codex-session-1'),
      );
      final title = find.byKey(
        const ValueKey('session-title-runtime-codex-session-1'),
      );
      expect(
        tester.getCenter(workspace).dy,
        lessThan(tester.getCenter(logo).dy),
      );
      expect(
        tester.getCenter(title).dy,
        greaterThan(tester.getCenter(logo).dy),
      );
      expect(tester.getRect(logo).right, lessThan(tester.getRect(title).left));
      await tester.tap(original);
      await tester.pumpAndSettle();
      expect(core.openedSessions.last, ('runtime-codex', 'session-1'));
      expect(
        find.byKey(const ValueKey('session-runtime-hermes-created-session')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'refresh keeps the menu open through detection, failure, and retry',
    (tester) async {
      final core = RichFakeCore()..historyCount = 0;
      await tester.pumpWidget(
        ZommiApp(core: core, desktop: FakeDesktopBridge()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('new-session')));
      await tester.pumpAndSettle();
      final gate = Completer<void>();
      core.discoveryGate = gate.future;
      core.discoveryFails = true;
      final refresh = find.byKey(const ValueKey('refresh-runtimes'));
      await tester.tap(refresh);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('New agent'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('runtime-discovery-progress')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('create-session-runtime-codex')),
        findsOneWidget,
      );
      gate.complete();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('runtime-discovery-error')),
        findsOneWidget,
      );
      expect(find.text('New agent'), findsOneWidget);

      final retryGate = Completer<void>();
      core.discoveryGate = retryGate.future;
      core.discoveryFails = false;
      await tester.tap(refresh);
      await tester.pump();
      core.discoveredTargets.add(hermes);
      retryGate.complete();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('runtime-discovery-error')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('runtime-discovery-progress')),
        findsNothing,
      );
      expect(find.text('4 available'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('create-session-runtime-hermes')),
      );
      await tester.pumpAndSettle();
      expect(find.text('New agent'), findsNothing);
      expect(core.activeTargetId, hermes.id);
      expect(core.createdSessions, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'model list fits short catalogs and scrolls long catalogs in a small window',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(640, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final count in [1, 30]) {
        final core = RichFakeCore()
          ..historyCount = 0
          ..modelCatalogByRuntime['runtime-codex'] = [
            for (var i = 0; i < count; i++)
              {
                'model': 'model-$i',
                'displayName': 'Model $i',
                'isDefault': i == 0,
              },
          ];
        await tester.pumpWidget(
          ZommiApp(
            key: ValueKey(count),
            core: core,
            desktop: FakeDesktopBridge(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('model-summary')));
        await tester.pumpAndSettle();
        final panel = find.byKey(const ValueKey('model-settings-panel'));
        final last = find.byKey(ValueKey('model-model-${count - 1}'));
        if (count == 1) {
          expect(
            tester.getBottomRight(panel).dy - tester.getBottomRight(last).dy,
            lessThan(14),
          );
        } else {
          await tester.scrollUntilVisible(
            last,
            200,
            scrollable: find.descendant(
              of: find.byKey(const ValueKey('model-list')),
              matching: find.byType(Scrollable),
            ),
          );
          await tester.tap(last);
          await tester.pumpAndSettle();
          expect(find.textContaining('Model 29'), findsWidgets);
        }
        expect(tester.getRect(panel).bottom, lessThanOrEqualTo(500));
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('right window controls call minimize and close separately', (
    tester,
  ) async {
    final desktop = FakeDesktopBridge();
    await tester.pumpWidget(
      ZommiApp(core: multiRuntimeCore(), desktop: desktop),
    );
    await tester.pumpAndSettle();
    final settings = find.byKey(const ValueKey('app-settings'));
    final minimize = find.byKey(const ValueKey('hide-zommi'));
    final close = find.byKey(const ValueKey('close-zommi'));
    expect(
      tester.getCenter(settings).dx,
      lessThan(tester.getCenter(minimize).dx),
    );
    expect(tester.getCenter(minimize).dx, lessThan(tester.getCenter(close).dx));
    await tester.tap(minimize);
    await tester.tap(close);
    expect(desktop.calls.where((c) => c == 'hide' || c == 'closeWindow'), [
      'hide',
      'closeWindow',
    ]);
  });
}
