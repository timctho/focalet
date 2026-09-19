import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';

void main() {
  for (final busy in [false, true]) {
    test('Codex loads summary pages and lazy native items (busy=$busy)', () async {
      final directory = await Directory.systemTemp.createTemp('zommi-paged-');
      addTearDown(() => directory.delete(recursive: true));
      final log = File('${directory.path}/requests.jsonl');
      final bridge = ProcessCoreBridge(
        executablePath: File(
          '../../target/debug/zommi-core-host${Platform.isWindows ? '.exe' : ''}',
        ).absolute.path,
        environment: {
          'ZOMMI_CODEX_COMMAND': Platform.isWindows ? 'python' : 'python3',
          'ZOMMI_CODEX_ARGS_JSON': jsonEncode([
            File('../../crates/zommi-core-host/tests/fake_codex_app_server.py')
                .absolute
                .path,
          ]),
          'ZOMMI_CORE_STATE_PATH': '${directory.path}/binding.json',
          'ZOMMI_RUNTIME_OVERRIDES_PATH': '${directory.path}/overrides.json',
          'ZOMMI_RUNTIME_DISCOVERY_CACHE_PATH':
              '${directory.path}/discovery.json',
          'ZOMMI_FAKE_REQUEST_LOG': log.path,
          'ZOMMI_FAKE_HISTORY_COUNT': '41',
          'ZOMMI_FAKE_PAGED_HISTORY': '1',
          if (busy) 'ZOMMI_FAKE_BUSY_RESUME': '1',
        },
      );
      addTearDown(bridge.close);
      await bridge.initialize();
      final discovery = await bridge.discoverRuntimeTargets();
      final target = discovery.targets.firstWhere(
        (target) =>
            target.adapterId == 'codex-app-server' &&
            target.executionHost['kind'] == 'native',
      );
      final connected = await bridge.connectRuntime(
        runtimeTargetId: target.id,
        preferredSessionId: 'saved-chat',
        cwd: directory.path,
      );
      expect(connected.models, isNotEmpty);
      expect((connected.history!['thread'] as Map)['turns'], hasLength(18));
      final switched = await bridge.openSession(
        runtimeTargetId: target.id,
        sessionId: 'saved-chat',
      );
      expect(switched.models, isEmpty);
      expect(switched.sessions, hasLength(1));
      final turns = <Map>[];
      var page = switched.history!;
      while (true) {
        final batch = ((page['thread'] as Map)['turns'] as List).cast<Map>();
        turns.insertAll(0, batch);
        final cursor = (page['pagination'] as Map)['nextCursor'] as String?;
        if (cursor == null) break;
        page = await bridge.readHistoryPage(
          runtimeTargetId: target.id,
          sessionId: 'saved-chat',
          cursor: cursor,
        );
      }
      expect(
        turns.map((turn) => turn['id']),
        List.generate(41, (index) => 'saved-chat-turn-$index'),
      );
      expect(turns.every((turn) => turn['itemsView'] == 'summary'), isTrue);
      final detail = await bridge.readHistoryTurn(
        runtimeTargetId: target.id,
        sessionId: 'saved-chat',
        turnId: 'saved-chat-turn-40',
      );
      expect(
        (((detail['thread'] as Map)['turns'] as List).single as Map)['items'],
        hasLength(3),
      );
      await expectLater(
        bridge.readHistoryTurn(
          runtimeTargetId: target.id,
          sessionId: 'saved-chat',
          turnId: 'missing',
        ),
        throwsA(isA<CoreProtocolException>()),
      );
      final requests = (await log.readAsLines())
          .map(jsonDecode)
          .cast<Map>()
          .toList();
      expect(
        requests.where(
          (r) =>
              r['method'] == 'thread/read' &&
              (r['params'] as Map)['includeTurns'] == true,
        ),
        isEmpty,
      );
      expect(
        requests.where((r) => r['method'] == 'thread/resume'),
        hasLength(2),
      );
      expect(
        requests.where(
          (r) => r['method'] == 'turn/start' || r['method'] == 'thread/start',
        ),
        isEmpty,
      );
    });
  }
}
