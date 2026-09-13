import 'dart:convert';
import 'dart:io';

import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/state/zommi_models.dart';

const sessionCatalogRetention = Duration(days: 7);

/// Rebuildable sidebar metadata. Transcripts and runtime credentials stay with
/// their providers; cached runtime labels are never connection configuration.
final class SessionCatalogSnapshot {
  const SessionCatalogSnapshot({
    this.runtimes = const [],
    this.sessions = const [],
    this.syncedAt = const {},
    this.attemptedAt = const {},
    this.usedAt = const {},
    this.protectedSessions = const {},
    this.dismissedSessions = const {},
  });

  final List<RuntimeTarget> runtimes;
  final List<SessionSummary> sessions;
  final Map<String, DateTime> syncedAt;
  final Map<String, DateTime> attemptedAt;
  final Map<String, DateTime> usedAt;
  final Set<(String, String)> protectedSessions;
  final Set<(String, String)> dismissedSessions;

  SessionCatalogSnapshot retained(DateTime now) {
    final cutoff = now.toUtc().subtract(sessionCatalogRetention);
    return SessionCatalogSnapshot(
      runtimes: runtimes,
      sessions: [
        for (final session in sessions)
          if (session.pinned ||
              session.customTitle != null ||
              protectedSessions.contains((
                session.runtimeTargetId,
                session.id,
              )) ||
              (session.activityTime?.isBefore(cutoff) == false))
            session,
      ],
      syncedAt: syncedAt,
      attemptedAt: attemptedAt,
      usedAt: usedAt,
      protectedSessions: protectedSessions,
      dismissedSessions: dismissedSessions,
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'runtimes': [
      for (final runtime in runtimes)
        {
          'id': runtime.id,
          'runtimeId': runtime.runtimeId,
          'adapterId': runtime.adapterId,
          'displayName': runtime.displayName,
        },
    ],
    'sessions': [
      for (final session in sessions)
        {
          'runtimeTargetId': session.runtimeTargetId,
          'id': session.id,
          'title': session.title,
          'pinned': session.pinned,
          'customTitle': ?session.customTitle,
          'cwd': ?session.cwd,
          'profile': ?session.profile,
          'updatedAt': ?session.updatedAt,
        },
    ],
    'syncedAt': _encodeTimes(syncedAt),
    'attemptedAt': _encodeTimes(attemptedAt),
    'usedAt': _encodeTimes(usedAt),
    'dismissedSessions': [
      for (final (runtime, session) in dismissedSessions)
        {'runtimeTargetId': runtime, 'id': session},
    ],
  };

  factory SessionCatalogSnapshot.fromJson(Object? value) {
    if (value is! Map || value['schemaVersion'] != 1) {
      throw const FormatException('Unsupported session catalog cache');
    }
    final runtimes = <RuntimeTarget>[];
    for (final item in _maps(value['runtimes'])) {
      if (item['id'] is! String || (item['id'] as String).isEmpty) continue;
      runtimes.add(
        RuntimeTarget.fromJson({
          'id': item['id'],
          'runtimeId': item['runtimeId'],
          'adapterId': item['adapterId'],
          'displayName': item['displayName'],
          'status': 'unavailable',
        }),
      );
    }
    final sessions = <(String, String), SessionSummary>{};
    for (final item in _maps(value['sessions'])) {
      final id = item['id'];
      final runtimeId = item['runtimeTargetId'];
      if (id is! String ||
          id.isEmpty ||
          runtimeId is! String ||
          runtimeId.isEmpty) {
        continue;
      }
      sessions[(runtimeId, id)] = SessionSummary.fromJson(
        item,
        runtimeTargetId: runtimeId,
      );
    }
    return SessionCatalogSnapshot(
      runtimes: runtimes,
      sessions: sessions.values.toList(),
      syncedAt: _decodeTimes(value['syncedAt']),
      attemptedAt: _decodeTimes(value['attemptedAt']),
      usedAt: _decodeTimes(value['usedAt']),
      dismissedSessions: {
        for (final item in _maps(value['dismissedSessions']))
          if (item['runtimeTargetId'] case final String runtime)
            if (item['id'] case final String session)
              if (runtime.isNotEmpty && session.isNotEmpty) (runtime, session),
      },
    );
  }

  static Iterable<Map<String, Object?>> _maps(Object? value) => value is List
      ? value.whereType<Map>().map((item) => item.cast<String, Object?>())
      : const [];

  static Map<String, String> _encodeTimes(Map<String, DateTime> values) => {
    for (final entry in values.entries)
      entry.key: entry.value.toUtc().toIso8601String(),
  };

  static Map<String, DateTime> _decodeTimes(Object? value) => value is Map
      ? {
          for (final entry in value.entries)
            if (entry.key is String && entry.value is String)
              if (DateTime.tryParse(entry.value as String) case final time?)
                entry.key as String: time.toUtc(),
        }
      : {};
}

abstract interface class SessionCatalogStore {
  Future<SessionCatalogSnapshot> load();
  Future<void> save(SessionCatalogSnapshot snapshot);
}

final class NoopSessionCatalogStore implements SessionCatalogStore {
  const NoopSessionCatalogStore();

  @override
  Future<SessionCatalogSnapshot> load() async => const SessionCatalogSnapshot();

  @override
  Future<void> save(SessionCatalogSnapshot snapshot) async {}
}

final class FileSessionCatalogStore implements SessionCatalogStore {
  FileSessionCatalogStore(this.path);

  factory FileSessionCatalogStore.platform() {
    final env = Platform.environment;
    final String directory;
    if (Platform.isWindows) {
      directory = '${env['APPDATA'] ?? env['LOCALAPPDATA'] ?? '.'}\\Zommi';
    } else if (Platform.isMacOS) {
      directory = '${env['HOME'] ?? '.'}/Library/Application Support/Zommi';
    } else {
      directory =
          '${env['XDG_STATE_HOME'] ?? '${env['HOME'] ?? '.'}/.local/state'}/zommi';
    }
    return FileSessionCatalogStore(
      '$directory${Platform.pathSeparator}session-catalog.json',
    );
  }

  final String path;
  Future<void> _writes = Future.value();

  @override
  Future<SessionCatalogSnapshot> load() async {
    for (final candidate in [path, '$path.backup']) {
      try {
        final file = File(candidate);
        if (await file.length() > 16 * 1024 * 1024) continue;
        return SessionCatalogSnapshot.fromJson(
          jsonDecode(await file.readAsString()),
        );
      } on Object {
        // Missing, interrupted or corrupt caches can be rebuilt from providers.
      }
    }
    return const SessionCatalogSnapshot();
  }

  @override
  Future<void> save(SessionCatalogSnapshot snapshot) {
    final encoded = jsonEncode(snapshot.toJson());
    final write = _writes.then((_) async {
      final file = File(path);
      await file.parent.create(recursive: true);
      final temporary = File('$path.pending');
      await temporary.writeAsString(encoded, flush: true);
      if (await file.exists()) {
        // Retain the last complete snapshot before atomically replacing it.
        var valid = false;
        try {
          SessionCatalogSnapshot.fromJson(
            jsonDecode(await file.readAsString()),
          );
          valid = true;
        } on FormatException {
          // A corrupt primary must not replace the valid recovery backup.
        }
        if (valid) {
          final backup = await file.copy('$path.backup.pending');
          await backup.rename('$path.backup');
        }
      }
      await temporary.rename(path);
    });
    _writes = write.catchError((Object _) {});
    return write;
  }
}
