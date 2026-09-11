import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/state/session_catalog_store.dart';
import 'package:zommi_flutter/state/sqlite_session_catalog_store.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'session_catalog_cache_test.dart'
    show MemoryCatalogStore, now, saved, cached;
import 'session_runtime_test.dart' show hermes, multiRuntimeCore;
import 'test_support.dart';

void main() {
  late Directory directory;
  late String path;
  late DateTime time;
  late SqliteSessionCatalogStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zommi-sqlite-');
    path = '${directory.path}/session-catalog.sqlite';
    time = now;
    store = SqliteSessionCatalogStore(path, clock: () => time);
  });
  tearDown(() => directory.delete(recursive: true));

  SessionSummary row(
    String id,
    DateTime? at, {
    String runtime = 'runtime-hermes',
  }) => SessionSummary(
    id: id,
    title: id,
    runtimeTargetId: runtime,
    updatedAt: at?.toIso8601String(),
  );

  test(
    'version one upgrades without losing rows and dismissals survive reopen',
    () async {
      await store.save(
        SessionCatalogSnapshot(
          sessions: [
            row('empty-chat', time),
            row('empty-chat', time, runtime: 'runtime-codex'),
          ],
        ),
      );
      final legacy = sqlite3.open(path);
      legacy.execute('DROP TABLE dismissed_sessions');
      legacy.execute('PRAGMA user_version = 1');
      legacy.close();
      expect((await store.load()).sessions, hasLength(2));
      await store.save(
        SessionCatalogSnapshot(
          sessions: [row('empty-chat', time, runtime: 'runtime-codex')],
          dismissedSessions: {('runtime-hermes', 'empty-chat')},
        ),
      );
      final restored = await SqliteSessionCatalogStore(
        path,
        clock: () => time,
      ).load();
      expect(restored.dismissedSessions, {('runtime-hermes', 'empty-chat')});
      expect(restored.sessions.single.runtimeTargetId, 'runtime-codex');
      final db = sqlite3.open(path);
      expect(db.select('PRAGMA user_version').single.values.single, 2);
      db.close();
    },
  );

  test('real database preserves scoped metadata and excludes runtime configuration', () async {
    final runtime = RuntimeTarget(
      id: hermes.id,
      runtimeId: 'hermes',
      adapterId: hermes.adapterId,
      displayName: 'Hermes',
      protocolName: 'Gateway',
      executablePath: '/private/runtime-secret',
      executionHost: const {'token': 'host-secret'},
      endpoint: 'https://user:password@example.test',
    );
    await store.save(
      SessionCatalogSnapshot(
        runtimes: [runtime],
        sessions: [
          saved,
          row(saved.id, now, runtime: 'runtime-codex'),
        ],
        syncedAt: {hermes.id: now},
        attemptedAt: {hermes.id: now},
        usedAt: {hermes.id: now},
      ),
    );
    final restored = await SqliteSessionCatalogStore(
      path,
      clock: () => time,
    ).load();
    expect(restored.sessions, hasLength(2));
    expect(restored.sessions.first.runtimeTargetId, 'runtime-codex');
    expect(restored.sessions.last.cwd, saved.cwd);
    expect(restored.syncedAt[hermes.id], now);
    expect(restored.attemptedAt[hermes.id], now);
    expect(restored.usedAt[hermes.id], now);
    expect(restored.runtimes.single.executablePath, isEmpty);
    expect(restored.runtimes.single.status, 'unavailable');
    final bytes = latin1.decode(await File(path).readAsBytes());
    expect(bytes, startsWith('SQLite format 3'));
    for (final secret in ['runtime-secret', 'host-secret', 'password']) {
      expect(bytes, isNot(contains(secret)));
    }
  });

  test('seven day cutoff expires on read and protects only selected or running keys', () async {
    final cutoff = now.subtract(sessionCatalogRetention);
    await store.save(
      SessionCatalogSnapshot(
        sessions: [
          row('boundary', cutoff),
          row('expired', cutoff.subtract(const Duration(milliseconds: 1))),
          row('unknown', null),
          row('active', cutoff.subtract(const Duration(days: 1))),
          row(
            'active',
            cutoff.subtract(const Duration(days: 1)),
            runtime: 'runtime-codex',
          ),
          row('running', null),
        ],
        protectedSessions: const {
          ('runtime-hermes', 'active'),
          ('runtime-hermes', 'running'),
        },
        syncedAt: {hermes.id: now},
      ),
    );
    expect(
      (await store.load()).sessions.map((s) => s.id),
      unorderedEquals(['boundary', 'active', 'running']),
    );
    time = now.add(const Duration(milliseconds: 1));
    expect(
      (await store.load()).sessions.map((s) => s.id),
      unorderedEquals(['active', 'running']),
    );
    // Releasing protection expires old rows, while sync freshness survives.
    await store.save(SessionCatalogSnapshot(syncedAt: {hermes.id: now}));
    final empty = await store.load();
    expect(empty.sessions, isEmpty);
    expect(empty.syncedAt[hermes.id], now);
    // Repeated provider listings cannot resurrect expired/undated cache rows.
    await store.save(
      SessionCatalogSnapshot(
        sessions: [row('expired', cutoff), row('unknown', null)],
      ),
    );
    expect((await store.load()).sessions, isEmpty);
  });

  test('serialized saves update only changed rows and a failed transaction rolls back', () async {
    await store.save(cached());
    var db = sqlite3.open(path);
    db.execute('''
      CREATE TABLE updates (title TEXT);
      CREATE TRIGGER record_update AFTER UPDATE ON sessions BEGIN INSERT INTO updates VALUES (NEW.title); END;
      CREATE TRIGGER fail_update BEFORE UPDATE ON sessions WHEN NEW.title = 'fail' BEGIN SELECT RAISE(ABORT, 'test failure'); END;
    ''');
    db.close();
    await store.save(cached());
    await Future.wait([
      for (var i = 0; i < 3; i++)
        store.save(
          SessionCatalogSnapshot(
            sessions: [saved.copyWith(title: 'Revision $i')],
          ),
        ),
    ]);
    await expectLater(
      store.save(
        SessionCatalogSnapshot(
          runtimes: [hermes],
          sessions: [saved.copyWith(title: 'fail')],
          syncedAt: {hermes.id: now.add(const Duration(hours: 1))},
        ),
      ),
      throwsA(isA<SqliteException>()),
    );
    final restored = await store.load();
    expect(restored.sessions.single.title, 'Revision 2');
    expect(restored.syncedAt[hermes.id], now);
    db = sqlite3.open(path);
    expect(db.select('SELECT title FROM updates').map((r) => r['title']), [
      'Revision 0',
      'Revision 1',
      'Revision 2',
    ]);
    db.close();
  });

  test('legacy backup imports once, filters old rows and retires JSON after commit', () async {
    final legacy = '${directory.path}/session-catalog.json';
    await File(legacy).writeAsString('{interrupted');
    await File('$legacy.backup').writeAsString(
      jsonEncode(
        SessionCatalogSnapshot(
          runtimes: [hermes],
          sessions: [saved, row('old', now.subtract(const Duration(days: 8)))],
          syncedAt: {hermes.id: now},
        ).toJson(),
      ),
    );
    store = SqliteSessionCatalogStore(
      path,
      legacyPath: legacy,
      clock: () => time,
    );
    expect((await store.load()).sessions.single.title, saved.title);
    expect(await File(legacy).exists(), isFalse);
    expect(await File('$legacy.backup').exists(), isFalse);
    await store.save(
      SessionCatalogSnapshot(sessions: [saved.copyWith(title: 'SQLite title')]),
    );
    // A leftover legacy file cannot overwrite the already migrated database.
    await File(legacy).writeAsString(jsonEncode(cached().toJson()));
    expect((await store.load()).sessions.single.title, 'SQLite title');
    expect(await File(legacy).exists(), isFalse);
  });

  test(
    'corrupt database is rebuildable but a future schema is left intact',
    () async {
      await File(path).writeAsString('broken sqlite');
      expect((await store.load()).sessions, isEmpty);
      await store.save(cached());
      expect((await store.load()).sessions.single.title, saved.title);
      final db = sqlite3.open(path);
      db.execute('PRAGMA user_version = 99');
      db.close();
      await expectLater(store.load(), throwsFormatException);
      await expectLater(store.save(cached()), throwsFormatException);
      final check = sqlite3.open(path);
      expect(
        check.select('SELECT title FROM sessions').single['title'],
        saved.title,
      );
      expect(check.select('PRAGMA user_version').single.values.single, 99);
      check.close();
    },
  );

  test('controller keeps old active/running chats and loads history without recaching expired rows', () async {
    final old = now.subtract(const Duration(days: 8)).toIso8601String();
    final core = multiRuntimeCore()
      ..sessionsByRuntime['runtime-codex'] = [
        {'id': 'session-1', 'updatedAt': old},
      ]
      ..sessionsByRuntime[hermes.id] = [
        {'id': 'session-1', 'updatedAt': old},
        {'id': 'running', 'updatedAt': old},
        {'id': 'older', 'updatedAt': old},
      ];
    final controller = ZommiController(
      core: core,
      desktop: FakeDesktopBridge(),
      sessionCatalogStore: store,
      clock: () => time,
    );
    addTearDown(controller.close);
    await controller.initialize();
    await controller.refreshSessionCatalog(force: true);
    core.emit(
      const CoreEvent(
        name: 'turn.started',
        sequence: 1,
        runtimeTargetId: 'runtime-hermes',
        sessionId: 'running',
        turnId: 'running-turn',
        payload: {},
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      controller.visibleSessions.map((s) => (s.runtimeTargetId, s.id)),
      unorderedEquals([('runtime-codex', 'session-1'), (hermes.id, 'running')]),
    );
    await controller.flushSessionCatalog();
    expect((await store.load()).sessions, hasLength(2));
    await controller.loadMoreSessions();
    expect(controller.visibleSessions, hasLength(4));
    await controller.flushSessionCatalog();
    expect((await store.load()).sessions, hasLength(2));
    await controller.switchSession('older', runtimeTargetId: hermes.id);
    await controller.flushSessionCatalog();
    final retained = await store.load();
    expect(
      retained.sessions.map((s) => s.id),
      unorderedEquals(['running', 'older']),
    );
    expect(core.openedSessions.last, (hermes.id, 'older'));
    expect(core.createdSessions, isEmpty);
  });

  testWidgets(
    'older chats are accessible from the sidebar and hourly retention runs while idle',
    (tester) async {
      final expired = DateTime.now()
          .toUtc()
          .subtract(const Duration(days: 8))
          .toIso8601String();
      final core = multiRuntimeCore()
        ..sessionsByRuntime[hermes.id] = [
          {
            'id': 'old-chat',
            'title': 'Earlier Hermes work',
            'updatedAt': expired,
          },
        ];
      await tester.pumpWidget(
        ZommiApp(core: core, desktop: FakeDesktopBridge()),
      );
      await tester.pumpAndSettle();
      expect(find.text('Earlier Hermes work'), findsNothing);
      expect(find.byKey(const ValueKey('load-older-sessions')), findsNothing);
      await tester.drag(
        find.byKey(const ValueKey('session-list')),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      expect(find.text('Earlier Hermes work'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();

      final memory = MemoryCatalogStore(cached());
      final controller = ZommiController(
        core: multiRuntimeCore(),
        desktop: FakeDesktopBridge(),
        sessionCatalogStore: memory,
        clock: () => time,
      );
      await controller.initialize();
      time = now.add(const Duration(days: 8));
      await tester.pump(const Duration(hours: 1));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        memory.snapshot.sessions.any(
          (s) => s.runtimeTargetId == hermes.id && s.id == saved.id,
        ),
        isFalse,
      );
      await tester.runAsync(controller.close);
    },
  );
}
