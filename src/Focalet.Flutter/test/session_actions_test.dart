import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focalet_flutter/state/session_catalog_store.dart';
import 'package:focalet_flutter/state/sqlite_session_catalog_store.dart';
import 'package:focalet_flutter/state/focalet_controller.dart';
import 'package:focalet_flutter/state/focalet_models.dart';
import 'package:focalet_flutter/widgets/overlay_panels.dart';

import 'test_support.dart';

void main() {
  test('pin and custom title survive provider refresh and restart; metadata deletion stays deleted', () async {
    final directory = await Directory.systemTemp.createTemp(
      'focalet-session-actions-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final store = SqliteSessionCatalogStore('${directory.path}/catalog.sqlite');
    final core = RichFakeCore()..historyCount = 2;
    final desktop = FakeDesktopBridge();
    final controller = FocaletController(
      core: core,
      desktop: desktop,
      sessionCatalogStore: store,
      catalogStartupDelay: const Duration(days: 1),
    );
    addTearDown(controller.close);
    await controller.initialize();
    final source = controller.sessions.firstWhere((s) => s.id == 'session-1');
    controller.renameSession(source, 'Pinned project');
    controller.setSessionPinned(source, true);
    controller.sessions.add(
      SessionSummary(
        id: source.id,
        title: 'Other',
        runtimeTargetId: 'runtime-other',
        updatedAt: '2099-01-01T00:00:00Z',
      ),
    );
    await controller.refreshSessionCatalog(force: true);
    expect(controller.visibleSessions.first.id, source.id);
    expect(controller.visibleSessions.first.title, 'Pinned project');
    core.historyCount = 3;
    await controller.copySession(source);
    expect(desktop.copiedText, contains('history user 1'));
    expect(desktop.copiedText, contains('history user 2'));
    expect(desktop.copiedText, contains('history user 3'));
    final requests = (core.createdSessions.length, core.openedSessions.length);
    await controller.close();
    final restartedCore = RichFakeCore()..historyCount = 2;
    final restarted = FocaletController(
      core: restartedCore,
      desktop: FakeDesktopBridge(),
      sessionCatalogStore: store,
      catalogStartupDelay: const Duration(days: 1),
    );
    addTearDown(restarted.close);
    await restarted.initialize();
    final restored = restarted.sessions.firstWhere(
      (s) => s.id == source.id && s.runtimeTargetId == source.runtimeTargetId,
    );
    expect(restored.pinned, isTrue);
    expect(restored.title, 'Pinned project');
    expect(restored.customTitle, 'Pinned project');
    final before = (
      restartedCore.createdSessions.length,
      restartedCore.openedSessions.length,
      restartedCore.readSessionCount,
    );
    restarted.deleteSessionMetadata(restored);
    expect(restarted.activeSessionId, isNull);
    expect(
      restarted.sessions.any(
        (s) => s.id == source.id && s.runtimeTargetId == 'runtime-other',
      ),
      isTrue,
    );
    expect((
      restartedCore.createdSessions.length,
      restartedCore.openedSessions.length,
      restartedCore.readSessionCount,
    ), before);
    await restarted.refreshSessionCatalog(force: true);
    expect(
      restarted.sessions.where(
        (s) => s.id == source.id && s.runtimeTargetId == source.runtimeTargetId,
      ),
      isEmpty,
    );
    await restarted.close();
    final again = FocaletController(
      core: RichFakeCore(),
      desktop: FakeDesktopBridge(),
      sessionCatalogStore: store,
      catalogStartupDelay: const Duration(days: 1),
    );
    addTearDown(again.close);
    await again.initialize();
    expect(again.activeSessionId, isNull);
    expect(
      again.sessions.where(
        (s) => s.id == source.id && s.runtimeTargetId == source.runtimeTargetId,
      ),
      isEmpty,
    );
    expect(requests, (0, 0));
    await again.close();
  });

  test(
    'pinned and renamed metadata outlive retention; unpin restores expiry',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'focalet-pinned-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final now = DateTime.utc(2026, 9, 13);
      final store = SqliteSessionCatalogStore(
        '${directory.path}/catalog.sqlite',
        clock: () => now,
      );
      const pinned = SessionSummary(
        id: 'pinned',
        title: 'Pinned',
        runtimeTargetId: 'codex',
        updatedAt: '2020-01-01',
        pinned: true,
      );
      const renamed = SessionSummary(
        id: 'renamed',
        title: 'My title',
        customTitle: 'My title',
        runtimeTargetId: 'codex',
        updatedAt: '2020-01-01',
      );
      await store.save(
        const SessionCatalogSnapshot(sessions: [pinned, renamed]),
      );
      expect((await store.load()).sessions, hasLength(2));
      await store.save(
        SessionCatalogSnapshot(
          sessions: [pinned.copyWith(pinned: false), renamed],
        ),
      );
      expect((await store.load()).sessions.map((s) => s.id), ['renamed']);
    },
  );

  testWidgets('right click targets the clicked chat without switching it', (
    tester,
  ) async {
    final core = RichFakeCore()..historyCount = 0;
    final controller = FocaletController(
      core: core,
      desktop: FakeDesktopBridge(),
    );
    await controller.initialize();
    addTearDown(controller.close);
    controller.sessions.add(
      const SessionSummary(
        id: 'other',
        title: 'Other chat',
        runtimeTargetId: 'runtime-codex',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 260,
            child: ListenableBuilder(
              listenable: controller,
              builder: (_, _) => SessionSidebar(controller: controller),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('session-runtime-codex-other'));
    await tester.tap(row, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    for (final action in ['pin', 'rename', 'copy', 'duplicate', 'delete']) {
      expect(find.byKey(ValueKey('session-action-$action')), findsOneWidget);
    }
    expect(controller.activeSessionId, 'session-1');
    await tester.tap(find.byKey(const ValueKey('session-action-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('session-rename-input')),
      'Renamed chat',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Renamed chat'), findsOneWidget);
    await tester.tap(row, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('session-action-pin')));
    await tester.pumpAndSettle();
    expect(controller.visibleSessions.first.id, 'other');
    expect(controller.activeSessionId, 'session-1');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
