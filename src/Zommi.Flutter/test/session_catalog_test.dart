import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/zommi_app.dart';

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
        ZommiApp(core: core, desktop: FakeDesktopBridge()),
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
    await tester.pumpWidget(ZommiApp(core: core, desktop: FakeDesktopBridge()));
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

  test(
    'failed catalogs retry only through an explicit catalog refresh',
    () async {
      final core = multiRuntimeCore()
        ..catalogFailures.add(hermes.id)
        ..sessionsByRuntime[hermes.id] = savedHermesChats;
      final controller = ZommiController(
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

  test(
    'catalog refresh finds saved chats after discovering a runtime',
    () async {
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
