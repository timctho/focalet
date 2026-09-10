import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'test_support.dart';
import 'session_runtime_test.dart' show hermes, multiRuntimeCore;

const savedHermesChats = [
  {
    'id': 'hermes-old',
    'title': 'Earlier Hermes work',
    'updatedAt': '2026-09-01T00:00:00Z',
  },
  {
    'id': 'hermes-recent',
    'title': 'Recent Hermes work',
    'updatedAt': '2026-09-09T00:00:00Z',
  },
];

void main() {
  testWidgets('saved Hermes chats appear at startup without creating a chat', (
    tester,
  ) async {
    final core = multiRuntimeCore()
      ..sessionsByRuntime[hermes.id] = savedHermesChats;
    await tester.pumpWidget(ZommiApp(core: core, desktop: FakeDesktopBridge()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('toggle-sessions')));
    await tester.pumpAndSettle();
    expect(find.text('Earlier Hermes work'), findsOneWidget);
    expect(find.text('Recent Hermes work'), findsOneWidget);
    expect(core.createdSessions, isEmpty);
    expect(core.openedSessions, isEmpty);
    expect(core.connectCount, 1);
    expect(core.activeTargetId, 'runtime-codex');
    expect(core.activeSessionId, 'session-1');
    expect(
      tester.getTopLeft(find.text('Recent Hermes work')).dy,
      lessThan(tester.getTopLeft(find.text('Earlier Hermes work')).dy),
    );
    await tester.tap(
      find.byKey(const ValueKey('session-runtime-hermes-hermes-recent')),
    );
    await tester.pumpAndSettle();
    expect(core.openedSessions.last, (hermes.id, 'hermes-recent'));
    expect(core.createdSessions, isEmpty);
  });

  test(
    'slow catalog loading preserves the active chat and allows sending',
    () async {
      final gate = Completer<void>();
      final core = multiRuntimeCore()
        ..catalogGates[hermes.id] = gate.future
        ..sessionsByRuntime[hermes.id] = savedHermesChats;
      final controller = ZommiController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      expect(controller.starting, isFalse);
      expect(controller.sessionCatalogLoading, isTrue);
      controller.setModel('fixture-mini');
      await controller.setWorkspace('/work/current');
      final settings = controller.activeSessionSettings;
      await controller.submit('Keep using this chat');
      expect(core.lastMessage, contains('Keep using this chat'));
      await controller.refreshSessionCatalog();
      expect(core.catalogRequests.where((id) => id == hermes.id), hasLength(1));
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(controller.sessionCatalogLoading, isFalse);
      expect(controller.activeRuntime?.id, 'runtime-codex');
      expect(controller.activeSessionId, 'session-1');
      expect(controller.selectedModel, settings.model);
      expect(controller.selectedWorkspace, settings.workspace);
      expect(
        controller.sessions.where(
          (session) => session.runtimeTargetId == hermes.id,
        ),
        hasLength(2),
      );
    },
  );

  testWidgets('failed catalogs can retry without hiding other chats', (
    tester,
  ) async {
    final core = multiRuntimeCore()
      ..catalogFailures.add(hermes.id)
      ..sessionsByRuntime[hermes.id] = savedHermesChats;
    await tester.pumpWidget(ZommiApp(core: core, desktop: FakeDesktopBridge()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('toggle-sessions')));
    await tester.pumpAndSettle();
    expect(find.text('Hermes chats could not be loaded'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('session-runtime-codex-session-1')),
      findsOneWidget,
    );
    core.catalogFailures.clear();
    await tester.tap(find.byKey(const ValueKey('retry-session-catalog')));
    await tester.pumpAndSettle();
    expect(find.text('Hermes chats could not be loaded'), findsNothing);
    expect(find.text('Recent Hermes work'), findsOneWidget);
    expect(core.createdSessions, isEmpty);
    expect(core.activeTargetId, 'runtime-codex');
  });

  test(
    'late catalog replies are ignored after the controller closes',
    () async {
      final gate = Completer<void>();
      final core = multiRuntimeCore()
        ..catalogGates[hermes.id] = gate.future
        ..sessionsByRuntime[hermes.id] = savedHermesChats;
      final controller = ZommiController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      await controller.initialize();
      await controller.close();
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(
        controller.sessions.where(
          (session) => session.runtimeTargetId == hermes.id,
        ),
        isEmpty,
      );
    },
  );

  test('refresh discovers saved chats for a newly available runtime', () async {
    final core = RichFakeCore()..historyCount = 0;
    final controller = ZommiController(
      core: core,
      desktop: FakeDesktopBridge(),
    );
    addTearDown(controller.close);
    await controller.initialize();
    await Future<void>.delayed(Duration.zero);
    core.discoveredTargets.add(hermes);
    core.sessionsByRuntime[hermes.id] = savedHermesChats;
    await controller.refreshRuntimes();
    await Future<void>.delayed(Duration.zero);
    expect(
      controller.sessions.where(
        (session) => session.runtimeTargetId == hermes.id,
      ),
      hasLength(2),
    );
    expect(core.createdSessions, isEmpty);
    expect(controller.activeRuntime?.id, 'runtime-codex');
  });
}
