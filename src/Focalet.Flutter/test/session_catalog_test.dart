import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focalet_flutter/state/focalet_controller.dart';
import 'package:focalet_flutter/widgets/overlay_panels.dart';
import 'package:focalet_flutter/focalet_app.dart';

import 'test_support.dart';
import 'session_runtime_test.dart' show hermes, multiRuntimeCore;

final savedHermesChats = [
  {
    'id': 'hermes-old',
    'title': 'Earlier Hermes work',
    'updatedAt': DateTime.now()
        .toUtc()
        .subtract(const Duration(days: 8))
        .toIso8601String(),
  },
  {
    'id': 'hermes-recent',
    'title': 'Recent Hermes work',
    'updatedAt': DateTime.now()
        .toUtc()
        .subtract(const Duration(days: 1))
        .toIso8601String(),
  },
];

void main() {
  testWidgets(
    'catalog loading stays in the header without moving or covering sessions',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(640, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final core = multiRuntimeCore();
      await tester.pumpWidget(
        FocaletApp(core: core, desktop: FakeDesktopBridge()),
      );
      await tester.pumpAndSettle();
      final first = find
          .descendant(
            of: find.byKey(const ValueKey('session-list')),
            matching: find.byType(ListTile),
          )
          .first;
      final controller = tester
          .widget<SessionSidebar>(find.byType(SessionSidebar))
          .controller;
      await controller.switchSession('session-2');
      await tester.pumpAndSettle();
      final before = tester.getRect(first);
      final gate = Completer<void>();
      core.catalogGates[hermes.id] = gate.future;
      final refresh = controller.refreshSessionCatalog(force: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      final progress = find.byKey(const ValueKey('session-catalog-loading'));
      final progressBounds = tester.getRect(progress);
      expect(
        progressBounds.center.dy,
        closeTo(tester.getRect(find.text('Agents')).center.dy, .1),
      );
      expect(progressBounds.bottom, lessThan(before.top - 8));
      expect(tester.getRect(first), before);
      await tester.tap(first);
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.takeException(), isNull);
      expect(controller.activeSessionId, 'session-1');
      expect(tester.getRect(first), before);
      gate.complete();
      await refresh;
      await tester.pumpAndSettle();
      expect(progress, findsNothing);
      expect(tester.getRect(first), before);
    },
  );

  testWidgets('catalog and new chat share one header spinner', (tester) async {
    final core = multiRuntimeCore();
    await tester.pumpWidget(
      FocaletApp(core: core, desktop: FakeDesktopBridge()),
    );
    await tester.pumpAndSettle();
    final controller = tester
        .widget<SessionSidebar>(find.byType(SessionSidebar))
        .controller;
    final gate = Completer<void>();
    core.catalogGates[hermes.id] = gate.future;
    final refresh = controller.refreshSessionCatalog(force: true);
    final createGate = Completer<void>();
    core.createSessionGate = createGate.future;
    final create = controller.createSession(runtimeTargetId: hermes.id);
    await tester.pump();
    expect(controller.sessionBusy, isTrue);
    expect(controller.sessionCatalogLoading, isTrue);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('session-sidebar')),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('new-session')),
        matching: find.byIcon(Icons.add_rounded),
      ),
      findsOneWidget,
    );
    createGate.complete();
    await create;
    gate.complete();
    await refresh;
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('session-catalog-loading')), findsNothing);
  });

  testWidgets(
    'sidebar opens with 20 summaries and adds 20 at each scroll to the bottom',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(640, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final now = DateTime.now().toUtc();
      final core = RichFakeCore()
        ..discoveredTargets.removeWhere(
          (target) => target.id != 'runtime-codex',
        )
        ..sessionsByRuntime['runtime-codex'] = [
          for (var i = 1; i <= 65; i++)
            {
              'id': 'session-$i',
              'title': 'Saved chat $i',
              'updatedAt': now.subtract(Duration(hours: i)).toIso8601String(),
            },
        ];
      await tester.pumpWidget(
        FocaletApp(core: core, desktop: FakeDesktopBridge()),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('session-sidebar')), findsOneWidget);
      final list = find.byKey(const ValueKey('session-list'));
      int count() =>
          (tester.widget<ListView>(list).childrenDelegate
                  as SliverChildBuilderDelegate)
              .childCount!;
      expect(count(), 20);
      expect(find.byKey(const ValueKey('load-older-sessions')), findsNothing);
      final reads = core.catalogRequests.length;
      final historyReads = core.readSessionCount;
      await tester.drag(list, const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(count(), 20);
      for (final expectedCount in [40, 60, 65]) {
        await tester.drag(list, const Offset(0, -3000));
        await tester.pumpAndSettle();
        expect(count(), expectedCount);
        await tester.drag(list, const Offset(0, 200));
        await tester.pumpAndSettle();
        expect(count(), expectedCount);
      }
      expect(core.catalogRequests, hasLength(reads));
      expect(core.readSessionCount, historyReads);
      expect(core.openedSessions, isEmpty);
      expect(core.createdSessions, isEmpty);
    },
  );

  testWidgets('saved Hermes chats appear at startup without creating a chat', (
    tester,
  ) async {
    final core = multiRuntimeCore()
      ..sessionsByRuntime[hermes.id] = savedHermesChats;
    await tester.pumpWidget(
      FocaletApp(core: core, desktop: FakeDesktopBridge()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Earlier Hermes work'), findsNothing);
    expect(find.text('Recent Hermes work'), findsOneWidget);
    expect(find.byKey(const ValueKey('load-older-sessions')), findsNothing);
    await tester.drag(
      find.byKey(const ValueKey('session-list')),
      const Offset(0, -300),
    );
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
    expect(core.activeTargetId, hermes.id);
    expect(core.activeSessionId, 'hermes-recent');
    expect(core.openedSessions, isEmpty);
    expect(core.createdSessions, isEmpty);
  });

  test(
    'slow catalog loading preserves the active chat and allows sending',
    () async {
      final gate = Completer<void>();
      final core = multiRuntimeCore()
        ..catalogGates[hermes.id] = gate.future
        ..sessionsByRuntime[hermes.id] = savedHermesChats;
      final controller = FocaletController(
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

  test(
    'failed catalogs retry only through an explicit catalog refresh',
    () async {
      final core = multiRuntimeCore()
        ..catalogFailures.add(hermes.id)
        ..sessionsByRuntime[hermes.id] = savedHermesChats;
      final controller = FocaletController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      await Future<void>.delayed(Duration.zero);
      final requests = [...core.catalogRequests];
      core.catalogFailures.clear();
      await controller.refreshRuntimes();
      await Future<void>.delayed(Duration.zero);
      expect(core.catalogRequests, requests);
      await controller.refreshSessionCatalog(force: true);
      expect(
        controller.sessions.where(
          (session) => session.runtimeTargetId == hermes.id,
        ),
        hasLength(2),
      );
      expect(core.createdSessions, isEmpty);
      expect(core.activeTargetId, 'runtime-codex');
    },
  );

  test(
    'late catalog replies are ignored after the controller closes',
    () async {
      final gate = Completer<void>();
      final core = multiRuntimeCore()
        ..catalogGates[hermes.id] = gate.future
        ..sessionsByRuntime[hermes.id] = savedHermesChats;
      final controller = FocaletController(
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

  test(
    'catalog refresh finds saved chats after discovering a runtime',
    () async {
      final core = RichFakeCore()..historyCount = 0;
      final controller = FocaletController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      await Future<void>.delayed(Duration.zero);
      core.discoveredTargets.add(hermes);
      core.sessionsByRuntime[hermes.id] = savedHermesChats;
      await controller.refreshRuntimes();
      expect(core.catalogRequests, isNot(contains(hermes.id)));
      await controller.refreshSessionCatalog(force: true);
      expect(
        controller.sessions.where(
          (session) => session.runtimeTargetId == hermes.id,
        ),
        hasLength(2),
      );
      expect(core.createdSessions, isEmpty);
      expect(controller.activeRuntime?.id, 'runtime-codex');
    },
  );
}
