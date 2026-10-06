import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focalet_flutter/core/core_bridge.dart';
import 'package:focalet_flutter/state/session_catalog_store.dart';
import 'package:focalet_flutter/state/sqlite_session_catalog_store.dart';
import 'package:focalet_flutter/state/focalet_controller.dart';
import 'package:focalet_flutter/state/focalet_models.dart';
import 'package:focalet_flutter/focalet_app.dart';

import 'session_runtime_test.dart' show hermes, multiRuntimeCore;
import 'test_support.dart';

final now = DateTime.utc(2026, 9, 10, 12);
const saved = SessionSummary(
  id: 'session-1',
  runtimeTargetId: 'runtime-hermes',
  title: 'Saved Hermes work',
  cwd: '/work/hermes',
  updatedAt: '2026-09-10T11:59:00Z',
);

final class MemoryCatalogStore implements SessionCatalogStore {
  MemoryCatalogStore([this.snapshot = const SessionCatalogSnapshot()]);
  SessionCatalogSnapshot snapshot;
  bool failWrites = false;

  @override
  Future<SessionCatalogSnapshot> load() async => snapshot;

  @override
  Future<void> save(SessionCatalogSnapshot snapshot) async {
    if (failWrites) throw const FileSystemException('Disk unavailable');
    this.snapshot = snapshot;
  }
}

SessionCatalogSnapshot cached({
  DateTime? activity,
  DateTime? synced,
  DateTime? attempted,
  DateTime? used,
}) => SessionCatalogSnapshot(
  runtimes: [hermes],
  sessions: [saved.copyWith(updatedAt: activity?.toIso8601String())],
  syncedAt: {hermes.id: synced ?? now},
  attemptedAt: {hermes.id: ?attempted},
  usedAt: {hermes.id: ?used},
);

void main() {
  test(
    'file cache round trips scoped metadata and excludes runtime secrets',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'focalet-catalog-cache-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/session-catalog.json';
      final store = FileSessionCatalogStore(path);
      final runtime = RuntimeTarget(
        id: hermes.id,
        runtimeId: hermes.runtimeId,
        adapterId: hermes.adapterId,
        displayName: hermes.displayName,
        protocolName: hermes.protocolName,
        executablePath: '/private/runtime',
        executionHost: const {'token': 'host-secret'},
        endpoint: 'https://user:password@example.test?token=endpoint-secret',
      );
      await store.save(
        SessionCatalogSnapshot(
          runtimes: [runtime],
          sessions: [
            saved,
            SessionSummary(
              id: saved.id,
              runtimeTargetId: 'runtime-codex',
              title: 'Codex same ID',
            ),
          ],
          syncedAt: {runtime.id: now},
        ),
      );
      final text = await File(path).readAsString();
      for (final excluded in [
        'host-secret',
        'endpoint-secret',
        'password',
        '/private/runtime',
      ]) {
        expect(text, isNot(contains(excluded)));
      }
      final restored = await FileSessionCatalogStore(path).load();
      expect(restored.sessions, hasLength(2));
      expect(restored.sessions.first.cwd, saved.cwd);
      expect(restored.syncedAt[hermes.id], now);
      expect(restored.runtimes.single.status, 'unavailable');
      expect(restored.runtimes.single.executablePath, isEmpty);
    },
  );

  test('serialized replacement and corrupt primary recovery retain a complete snapshot', () async {
    final directory = await Directory.systemTemp.createTemp(
      'focalet-catalog-recovery-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/catalog.json';
    final store = FileSessionCatalogStore(path);
    await Future.wait([
      for (var index = 0; index < 4; index++)
        store.save(
          SessionCatalogSnapshot(
            sessions: [saved.copyWith(title: 'Revision $index')],
          ),
        ),
    ]);
    expect((await store.load()).sessions.single.title, 'Revision 3');
    await File(path).writeAsString('{interrupted');
    expect((await store.load()).sessions.single.title, 'Revision 2');
    await store.save(cached());
    await File(path).writeAsString('{interrupted again');
    expect((await store.load()).sessions.single.title, 'Revision 2');
    await File('$path.backup').writeAsString(jsonEncode({'schemaVersion': 99}));
    expect((await store.load()).sessions, isEmpty);
    await store.save(cached());
    expect((await store.load()).sessions.single.title, saved.title);
  });

  testWidgets(
    'cached rows and logos appear before runtime initialization completes',
    (tester) async {
      final gate = Completer<void>();
      final core = multiRuntimeCore()..initializeGate = gate.future;
      final store = MemoryCatalogStore(
        cached(
          synced: DateTime.now().toUtc(),
          activity: DateTime.now().toUtc(),
        ),
      );
      await tester.pumpWidget(
        FocaletApp(
          core: core,
          desktop: FakeDesktopBridge(),
          sessionCatalogStore: store,
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(saved.title), findsOneWidget);
      expect(
        find.byKey(const ValueKey('session-runtime-runtime-hermes-session-1')),
        findsOneWidget,
      );
      expect(core.connectCount, 0);
      expect(core.catalogRequests, isEmpty);
      gate.complete();
      await tester.pumpAndSettle();
      expect(core.catalogRequests.where((id) => id == hermes.id), isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  test(
    'cold import survives a real file restart with no background runtime reads',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'focalet-catalog-restart-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/catalog.json';
      final first = multiRuntimeCore()
        ..sessionsByRuntime[hermes.id] = [
          {
            'id': saved.id,
            'title': saved.title,
            'cwd': saved.cwd,
            'updatedAt': saved.updatedAt,
          },
        ];
      final controller = FocaletController(
        core: first,
        desktop: FakeDesktopBridge(),
        sessionCatalogStore: SqliteSessionCatalogStore(path, clock: () => now),
        clock: () => now,
      );
      await controller.initialize();
      await Future<void>.delayed(Duration.zero);
      await controller.close();
      expect(first.catalogRequests, contains(hermes.id));
      final second = multiRuntimeCore();
      final restarted = FocaletController(
        core: second,
        desktop: FakeDesktopBridge(),
        sessionCatalogStore: SqliteSessionCatalogStore(path, clock: () => now),
        clock: () => now,
      );
      addTearDown(restarted.close);
      await restarted.initialize();
      await restarted.refreshSessionCatalog();
      expect(second.catalogRequests, isEmpty);
      expect(second.connectCount, 1);
      expect(
        restarted.sessions.any((session) => session.title == saved.title),
        isTrue,
      );
      expect(second.createdSessions, isEmpty);
      await restarted.switchSession(saved.id, runtimeTargetId: hermes.id);
      expect(restarted.activeRuntime?.id, hermes.id);
      expect(restarted.activeSessionId, saved.id);
      expect(second.openedSessions, isEmpty);
      expect(second.createdSessions, isEmpty);
    },
  );

  test(
    'recent runtimes expire sooner and explicit refresh bypasses freshness',
    () async {
      for (final recent in [false, true]) {
        final core = multiRuntimeCore();
        final store = MemoryCatalogStore(
          cached(
            synced: now.subtract(const Duration(minutes: 20)),
            used: recent ? now : null,
          ),
        );
        final controller = FocaletController(
          core: core,
          desktop: FakeDesktopBridge(),
          sessionCatalogStore: store,
          clock: () => now,
        );
        await controller.initialize();
        await Future<void>.delayed(Duration.zero);
        expect(core.catalogRequests.contains(hermes.id), recent);
        final previous = core.catalogRequests
            .where((id) => id == hermes.id)
            .length;
        await controller.refreshSessionCatalog(force: true);
        expect(
          core.catalogRequests.where((id) => id == hermes.id),
          hasLength(previous + 1),
        );
        await controller.close();
      }
    },
  );

  test(
    'failed refresh retains offline metadata and persists retry cooldown',
    () async {
      final store = MemoryCatalogStore(
        cached(synced: now.subtract(const Duration(days: 1))),
      );
      final core = multiRuntimeCore()..catalogFailures.add(hermes.id);
      final controller = FocaletController(
        core: core,
        desktop: FakeDesktopBridge(),
        sessionCatalogStore: store,
        clock: () => now,
      );
      await controller.initialize();
      await Future<void>.delayed(Duration.zero);
      expect(controller.sessionCatalogError, contains('Hermes'));
      expect(
        controller.sessions.any((session) => session.title == saved.title),
        isTrue,
      );
      await controller.close();
      final second = multiRuntimeCore();
      final restarted = FocaletController(
        core: second,
        desktop: FakeDesktopBridge(),
        sessionCatalogStore: store,
        clock: () => now,
      );
      await restarted.initialize();
      expect(second.catalogRequests, isEmpty);
      await restarted.refreshSessionCatalog(force: true);
      expect(second.catalogRequests, contains(hermes.id));
      await restarted.close();
      final unavailable = RichFakeCore()..historyCount = 0;
      final offline = FocaletController(
        core: unavailable,
        desktop: FakeDesktopBridge(),
        sessionCatalogStore: store,
        clock: () => now,
      );
      addTearDown(offline.close);
      await offline.initialize();
      final summary = offline.sessions.firstWhere(
        (session) => session.runtimeTargetId == hermes.id,
      );
      expect(offline.runtimeForSession(summary)?.runtimeId, 'hermes');
      expect(summary.title, saved.title);
      expect(unavailable.catalogRequests, isNot(contains(hermes.id)));
    },
  );

  testWidgets(
    'startup defers uncached runtimes and disposal cancels the timer',
    (tester) async {
      final core = multiRuntimeCore();
      await tester.pumpWidget(
        FocaletApp(
          core: core,
          desktop: FakeDesktopBridge(),
          catalogStartupDelay: const Duration(seconds: 5),
        ),
      );
      await tester.pumpAndSettle();
      expect(core.catalogRequests, isEmpty);
      await tester.pump(const Duration(seconds: 4));
      expect(core.catalogRequests, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      expect(core.catalogRequests, isEmpty);
    },
  );

  test('overlapping refreshes share two workers and prioritize recently used runtimes', () async {
    final core = RichFakeCore()..historyCount = 0;
    core.discoveredTargets.removeWhere(
      (target) => target.id != 'runtime-codex',
    );
    RuntimeTarget target(int i) => RuntimeTarget(
      id: 'runtime-$i',
      runtimeId: 'hermes',
      adapterId: 'hermes-gateway',
      displayName: 'Hermes $i',
      protocolName: 'Hermes Gateway',
      executablePath: '/hermes/$i',
      executionHost: const {},
      capabilityHints: const ['session.list.v1'],
    );
    core.discoveredTargets.addAll([for (var i = 0; i < 4; i++) target(i)]);
    final gates = {for (var i = 0; i < 5; i++) 'runtime-$i': Completer<void>()};
    core.catalogGates.addAll(
      gates.map((id, gate) => MapEntry(id, gate.future)),
    );
    final controller = FocaletController(
      core: core,
      desktop: FakeDesktopBridge(),
      clock: () => now,
      sessionCatalogStore: MemoryCatalogStore(
        SessionCatalogSnapshot(usedAt: {'runtime-2': now}),
      ),
    );
    await controller.initialize();
    expect(core.catalogRequests, ['runtime-2', 'runtime-0']);
    core.discoveredTargets.add(target(4));
    await controller.refreshRuntimes();
    unawaited(controller.refreshSessionCatalog(force: true));
    expect(core.catalogRequests, hasLength(2));
    gates['runtime-0']!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(core.catalogRequests, ['runtime-2', 'runtime-0', 'runtime-1']);
    await controller.close();
    for (final gate in gates.values) {
      if (!gate.isCompleted) gate.complete();
    }
    await Future<void>.delayed(Duration.zero);
    expect(core.catalogRequests, hasLength(3));
  });

  test('new chat title, workspace and reply recency persist without transcript content', () async {
    final core = multiRuntimeCore()..sessionsByRuntime[hermes.id] = [];
    final store = MemoryCatalogStore();
    var time = now;
    final controller = FocaletController(
      core: core,
      desktop: FakeDesktopBridge(),
      sessionCatalogStore: store,
      clock: () => time,
    );
    await controller.initialize();
    await controller.createSession(runtimeTargetId: hermes.id);
    await controller.setWorkspace('/work/new');
    await controller.submit('New task title');
    time = now.add(const Duration(minutes: 1));
    core.emit(
      const CoreEvent(
        name: 'item.update',
        sequence: 1,
        runtimeTargetId: 'runtime-hermes',
        sessionId: 'created-session',
        turnId: 'created-session-live-turn',
        payload: {
          'kind': 'assistant',
          'text': 'Private full reply',
          'lifecycle': 'streaming',
        },
      ),
    );
    core.emit(
      const CoreEvent(
        name: 'turn.completed',
        sequence: 2,
        runtimeTargetId: 'runtime-hermes',
        sessionId: 'created-session',
        turnId: 'created-session-live-turn',
        payload: {'status': 'completed'},
      ),
    );
    await controller.close();
    final summary = store.snapshot.sessions.firstWhere(
      (session) =>
          session.runtimeTargetId == hermes.id &&
          session.id == core.activeSessionId,
    );
    expect(summary.cwd, '/work/new');
    expect(summary.activityTime, time);
    expect(summary.title, 'New task title');
    final decoded = store.snapshot.toJson();
    expect(decoded.containsKey('turns'), isFalse);
    expect(decoded.containsKey('messages'), isFalse);
    expect(jsonEncode(decoded), isNot(contains('Private full reply')));
    final restarted = FocaletController(
      core: multiRuntimeCore(),
      desktop: FakeDesktopBridge(),
      sessionCatalogStore: store,
      clock: () => time,
    );
    await restarted.initialize();
    expect(restarted.sessions.first.id, 'created-session');
    expect(restarted.sessions.first.title, 'New task title');
    expect(
      restarted.presenceFor('created-session', runtimeTargetId: hermes.id),
      SessionPresence.done,
    );
    await restarted.close();
  });

  test('large warm cache renders metadata without probing 100 runtimes', () async {
    final directory = await Directory.systemTemp.createTemp(
      'focalet-large-catalog-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final store = SqliteSessionCatalogStore(
      '${directory.path}/catalog.sqlite',
      clock: () => now,
    );
    final targets = [
      for (var index = 0; index < 100; index++)
        RuntimeTarget(
          id: 'runtime-$index',
          runtimeId: 'hermes',
          adapterId: 'hermes-gateway',
          displayName: 'Hermes $index',
          protocolName: 'Hermes Gateway',
          executablePath: '/runtime/$index',
          executionHost: const {},
          capabilityHints: const ['session.list.v1'],
        ),
    ];
    await store.save(
      SessionCatalogSnapshot(
        runtimes: targets,
        sessions: [
          for (final runtime in targets)
            for (var index = 0; index < 100; index++)
              SessionSummary(
                id: 'session-$index',
                title: 'Saved chat $index',
                runtimeTargetId: runtime.id,
                updatedAt: now
                    .subtract(Duration(minutes: index))
                    .toIso8601String(),
              ),
        ],
        syncedAt: {for (final target in targets) target.id: now},
      ),
    );
    final gate = Completer<void>();
    final core = RichFakeCore()
      ..historyCount = 0
      ..initializeGate = gate.future;
    core.discoveredTargets
      ..removeWhere((target) => target.id != 'runtime-codex')
      ..addAll(targets);
    final controller = FocaletController(
      core: core,
      desktop: FakeDesktopBridge(),
      sessionCatalogStore: store,
      clock: () => now,
    );
    final restored = Completer<void>();
    controller.addListener(() {
      if (controller.sessions.length == 10000 && !restored.isCompleted) {
        restored.complete();
      }
    });
    final stopwatch = Stopwatch()..start();
    final initialization = controller.initialize();
    await restored.future.timeout(const Duration(seconds: 10));
    stopwatch.stop();
    expect(core.connectCount, 0);
    expect(core.catalogRequests, isEmpty);
    // Informational timing, not a machine-dependent pass/fail threshold.
    debugPrint(
      '100 runtimes / 10000 cached sessions restored in ${stopwatch.elapsedMilliseconds} ms',
    );
    gate.complete();
    await initialization;
    await controller.refreshSessionCatalog();
    expect(core.catalogRequests, isEmpty);
    expect(core.connectCount, 1);
    await controller.close();
  });

  test('cache write failures do not prevent chatting or closing', () async {
    final core = multiRuntimeCore();
    final store = MemoryCatalogStore()..failWrites = true;
    final controller = FocaletController(
      core: core,
      desktop: FakeDesktopBridge(),
      sessionCatalogStore: store,
    );
    await controller.initialize();
    await controller.flushSessionCatalog();
    await controller.submit('Still usable');
    expect(core.lastMessage, contains('Still usable'));
    await controller.close();
    expect(core.closed, isTrue);
  });

  test(
    'partial provider summaries preserve cached workspace and reply ordering',
    () async {
      final core = RichFakeCore()
        ..historyCount = 0
        ..sessionsByRuntime['runtime-codex'] = [
          {'id': 'session-1', 'updatedAt': '2026-09-01T00:00:00Z'},
        ];
      final store = MemoryCatalogStore(
        SessionCatalogSnapshot(
          sessions: [
            SessionSummary(
              id: 'session-1',
              runtimeTargetId: 'runtime-codex',
              title: 'Remembered title',
              cwd: '/work/saved',
              updatedAt: now.toIso8601String(),
            ),
          ],
        ),
      );
      final controller = FocaletController(
        core: core,
        desktop: FakeDesktopBridge(),
        sessionCatalogStore: store,
        clock: () => now,
      );
      await controller.initialize();
      expect(controller.selectedWorkspace, '/work/saved');
      expect(controller.sessions.single.title, 'Remembered title');
      expect(controller.sessions.single.activityTime, now);
      core.sessionsByRuntime['runtime-codex'] = [
        {
          'id': 'session-1',
          'title': 'Renamed externally',
          'cwd': '/work/other',
          'updatedAt': now.add(const Duration(minutes: 1)).toIso8601String(),
        },
      ];
      await controller.refreshSessionCatalog(force: true);
      expect(controller.sessions.single.title, 'Renamed externally');
      expect(controller.sessions.single.cwd, '/work/other');
      await controller.close();
      expect(store.snapshot.sessions.single.title, 'Renamed externally');
    },
  );
}
