import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/state/session_catalog_store.dart';
import 'package:zommi_flutter/state/zommi_models.dart';

/// Small, rebuildable catalog. Each serialized operation opens and closes its
/// connection in a worker isolate, so SQLite locks and I/O never block the UI.
final class SqliteSessionCatalogStore implements SessionCatalogStore {
  SqliteSessionCatalogStore(
    this.path, {
    this.legacyPath,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  factory SqliteSessionCatalogStore.platform() {
    final legacy = FileSessionCatalogStore.platform().path;
    return SqliteSessionCatalogStore(
      legacy.replaceFirst(RegExp(r'\.json$'), '.sqlite'),
      legacyPath: legacy,
    );
  }

  final String path;
  final String? legacyPath;
  final DateTime Function() _clock;
  Future<void> _operations = Future.value();

  @override
  Future<SessionCatalogSnapshot> load() {
    final read = _operations.then(
      (_) => _readOffThread(path, legacyPath, _clock()),
    );
    _operations = read.then<void>((_) {}).catchError((Object _) {});
    return read;
  }

  @override
  Future<void> save(SessionCatalogSnapshot snapshot) {
    final write = _operations.then(
      (_) => _writeOffThread(path, legacyPath, snapshot, _clock()),
    );
    _operations = write.catchError((Object _) {});
    return write;
  }
}

// Top-level entry points prevent isolate closures from capturing the store's
// pending Future or any application state.
Future<SessionCatalogSnapshot> _readOffThread(
  String path,
  String? legacy,
  DateTime now,
) => Isolate.run(
  () => _withCatalog(path, legacy, now, (db) {
    _transaction(db, () => _prune(db, now));
    final runtimes = <RuntimeTarget>[];
    final synced = <String, DateTime>{};
    final attempted = <String, DateTime>{};
    final used = <String, DateTime>{};
    for (final row in db.select('SELECT * FROM runtimes')) {
      final id = row['id'] as String;
      if (row['runtime_id'] != null) {
        runtimes.add(
          RuntimeTarget.fromJson({
            'id': id,
            'runtimeId': row['runtime_id'],
            'adapterId': row['adapter_id'],
            'displayName': row['display_name'],
            'status': 'unavailable',
          }),
        );
      }
      for (final (column, times) in [
        ('synced_at', synced),
        ('attempted_at', attempted),
        ('used_at', used),
      ]) {
        if (row[column] case final int time) {
          times[id] = DateTime.fromMillisecondsSinceEpoch(time, isUtc: true);
        }
      }
    }
    final rows = db.select(
      'SELECT * FROM sessions ORDER BY activity_at DESC, runtime_target_id, id',
    );
    return SessionCatalogSnapshot(
      runtimes: runtimes,
      sessions: [
        for (final row in rows)
          SessionSummary(
            id: row['id'] as String,
            runtimeTargetId: row['runtime_target_id'] as String,
            title: row['title'] as String,
            cwd: row['cwd'] as String?,
            profile: row['profile'] as String?,
            updatedAt: row['updated_at'] as String?,
          ),
      ],
      syncedAt: synced,
      attemptedAt: attempted,
      usedAt: used,
      protectedSessions: {
        for (final row in rows)
          if (row['protected'] == 1)
            (row['runtime_target_id'] as String, row['id'] as String),
      },
    );
  }),
);

Future<void> _writeOffThread(
  String path,
  String? legacy,
  SessionCatalogSnapshot snapshot,
  DateTime now,
) => Isolate.run(
  () => _withCatalog(path, legacy, now, (db) {
    _transaction(db, () => _save(db, snapshot.retained(now), now));
  }),
);

T _withCatalog<T>(
  String path,
  String? legacy,
  DateTime now,
  T Function(Database) action,
) {
  File(path).parent.createSync(recursive: true);
  for (var attempt = 0; ; attempt++) {
    Database? db;
    try {
      db = sqlite3.open(path);
      db.execute('PRAGMA busy_timeout = 5000');
      db.execute('PRAGMA synchronous = FULL');
      final version =
          db.select('PRAGMA user_version').single.values.single as int;
      if (version > 1) {
        throw const FormatException('Unsupported session catalog database');
      }
      if (version == 0) {
        // Import and schema marker commit together. Interrupted migration can
        // safely retry; legacy files are removed only after a successful commit.
        _transaction(db, () {
          db!.execute('''
            CREATE TABLE runtimes (
              id TEXT PRIMARY KEY, runtime_id TEXT, adapter_id TEXT, display_name TEXT,
              synced_at INTEGER, attempted_at INTEGER, used_at INTEGER
            );
            CREATE TABLE sessions (
              runtime_target_id TEXT NOT NULL, id TEXT NOT NULL, title TEXT NOT NULL,
              cwd TEXT, profile TEXT, updated_at TEXT, activity_at INTEGER,
              protected INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (runtime_target_id, id)
            );
            CREATE INDEX sessions_activity ON sessions(activity_at DESC);
            CREATE INDEX sessions_expiry ON sessions(activity_at) WHERE protected = 0;
          ''');
          _save(db, _readLegacy(legacy).retained(now), now);
          db.execute('PRAGMA user_version = 1');
        });
      }
      _removeLegacy(legacy);
      return action(db);
    } on SqliteException catch (error) {
      // Only confirmed corrupt/not-a-database caches are rebuilt. Locks, disk
      // errors and unknown schemas must never cause us to delete valid data.
      if (attempt != 0 || ![11, 26].contains(error.resultCode)) rethrow;
      db?.close();
      db = null;
      File(path).deleteSync();
    } finally {
      db?.close();
    }
  }
}

void _transaction(Database db, void Function() action) {
  db.execute('BEGIN IMMEDIATE');
  try {
    action();
    db.execute('COMMIT');
  } on Object {
    db.execute('ROLLBACK');
    rethrow;
  }
}

void _save(Database db, SessionCatalogSnapshot snapshot, DateTime now) {
  final labels = {for (final runtime in snapshot.runtimes) runtime.id: runtime};
  final runtimeIds = {
    ...labels.keys,
    ...snapshot.syncedAt.keys,
    ...snapshot.attemptedAt.keys,
    ...snapshot.usedAt.keys,
  };
  final runtimeWrite = db.prepare('''
    INSERT INTO runtimes VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      runtime_id = excluded.runtime_id, adapter_id = excluded.adapter_id,
      display_name = excluded.display_name, synced_at = excluded.synced_at,
      attempted_at = excluded.attempted_at, used_at = excluded.used_at
    WHERE runtime_id IS NOT excluded.runtime_id OR adapter_id IS NOT excluded.adapter_id
      OR display_name IS NOT excluded.display_name OR synced_at IS NOT excluded.synced_at
      OR attempted_at IS NOT excluded.attempted_at OR used_at IS NOT excluded.used_at
  ''');
  final sessionWrite = db.prepare('''
    INSERT INTO sessions VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(runtime_target_id, id) DO UPDATE SET
      title = excluded.title, cwd = excluded.cwd, profile = excluded.profile,
      updated_at = excluded.updated_at, activity_at = excluded.activity_at,
      protected = excluded.protected
    WHERE title IS NOT excluded.title OR cwd IS NOT excluded.cwd
      OR profile IS NOT excluded.profile OR updated_at IS NOT excluded.updated_at
      OR activity_at IS NOT excluded.activity_at OR protected IS NOT excluded.protected
  ''');
  // Protection is a snapshot of the current selected/running sessions, not a
  // permanent pin. Previously protected rows become eligible for expiry again.
  db.execute(
    'CREATE TEMP TABLE current_protection (runtime_target_id TEXT, id TEXT, PRIMARY KEY(runtime_target_id, id))',
  );
  final protect = db.prepare('INSERT INTO current_protection VALUES (?, ?)');
  try {
    for (final id in runtimeIds) {
      final runtime = labels[id];
      runtimeWrite.execute([
        id,
        runtime?.runtimeId,
        runtime?.adapterId,
        runtime?.displayName,
        snapshot.syncedAt[id]?.millisecondsSinceEpoch,
        snapshot.attemptedAt[id]?.millisecondsSinceEpoch,
        snapshot.usedAt[id]?.millisecondsSinceEpoch,
      ]);
    }
    for (final key in snapshot.protectedSessions) {
      protect.execute([key.$1, key.$2]);
    }
    db.execute(
      '''UPDATE sessions SET protected = 0 WHERE protected = 1 AND NOT EXISTS (
      SELECT 1 FROM current_protection p WHERE p.runtime_target_id = sessions.runtime_target_id AND p.id = sessions.id
    )''',
    );
    for (final session in snapshot.sessions) {
      sessionWrite.execute([
        session.runtimeTargetId,
        session.id,
        session.title,
        session.cwd,
        session.profile,
        session.updatedAt,
        session.activityTime?.millisecondsSinceEpoch,
        snapshot.protectedSessions.contains((
              session.runtimeTargetId,
              session.id,
            ))
            ? 1
            : 0,
      ]);
    }
    _prune(db, now);
  } finally {
    protect.close();
    sessionWrite.close();
    runtimeWrite.close();
    db.execute('DROP TABLE current_protection');
  }
}

void _prune(Database db, DateTime now) {
  db.execute(
    'DELETE FROM sessions WHERE protected = 0 AND (activity_at < ? OR activity_at IS NULL)',
    [now.toUtc().subtract(sessionCatalogRetention).millisecondsSinceEpoch],
  );
}

SessionCatalogSnapshot _readLegacy(String? path) {
  if (path != null) {
    for (final candidate in [path, '$path.backup']) {
      try {
        final file = File(candidate);
        if (file.lengthSync() > 16 * 1024 * 1024) continue;
        return SessionCatalogSnapshot.fromJson(
          jsonDecode(file.readAsStringSync()),
        );
      } on FileSystemException {
        // Missing cache: try the previous JSON recovery snapshot.
      } on FormatException {
        // Invalid cache: providers can rebuild it.
      }
    }
  }
  return const SessionCatalogSnapshot();
}

void _removeLegacy(String? path) {
  if (path == null) return;
  for (final candidate in [
    path,
    '$path.backup',
    '$path.pending',
    '$path.backup.pending',
  ]) {
    try {
      final file = File(candidate);
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // A locked legacy file can be retired on the next successful open.
    }
  }
}
