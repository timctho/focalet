import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focalet_flutter/core/core_bridge.dart';
import 'package:focalet_flutter/desktop/desktop_bridge.dart';
import 'package:focalet_flutter/state/focalet_controller.dart';

void main() {
  for (final mode in ['success', 'failure', 'same-id']) {
    test('native fork $mode preserves source and never replays a turn', () async {
      final directory = await Directory.systemTemp.createTemp('focalet-fork-');
      addTearDown(() => directory.delete(recursive: true));
      final log = File('${directory.path}/requests.jsonl');
      final bridge = ProcessCoreBridge(
        executablePath: File(
          '../../target/debug/focalet-core-host${Platform.isWindows ? '.exe' : ''}',
        ).absolute.path,
        environment: {
          'FOCALET_CODEX_COMMAND': Platform.isWindows ? 'python' : 'python3',
          'FOCALET_CODEX_ARGS_JSON': jsonEncode([
            File(
              '../../crates/focalet-core-host/tests/fake_codex_app_server.py',
            ).absolute.path,
          ]),
          'FOCALET_CORE_STATE_PATH': '${directory.path}/binding.json',
          'FOCALET_RUNTIME_OVERRIDES_PATH': '${directory.path}/overrides.json',
          'FOCALET_RUNTIME_DISCOVERY_CACHE_PATH':
              '${directory.path}/discovery.json',
          'FOCALET_FAKE_REQUEST_LOG': log.path,
          'FOCALET_FAKE_HISTORY_COUNT': '3',
          'FOCALET_FAKE_FORK_CWD': '${directory.path}/source-workspace',
          if (mode == 'failure') 'FOCALET_FAKE_FORK_FAIL': '1',
          if (mode == 'same-id') 'FOCALET_FAKE_FORK_SAME_ID': '1',
        },
      );
      final controller = FocaletController(
        core: bridge,
        desktop: const NoopDesktopBridge(),
        catalogStartupDelay: const Duration(days: 1),
      );
      addTearDown(controller.close);
      await controller.initialize();
      final target = controller.runtimeTargets.firstWhere(
        (t) =>
            t.adapterId == 'codex-app-server' &&
            t.executionHost['kind'] == 'native',
      );
      await controller.selectRuntime(target.id);
      await controller.switchSession('source-chat');
      final source = controller.sessions.firstWhere(
        (s) => s.id == 'source-chat',
      );
      final sourceText = controller.turns.map((t) => t.userText).toList();
      final count = (await log.readAsLines()).length;
      await controller.duplicateSession(source);
      final requests = (await log.readAsLines())
          .skip(count)
          .map((line) => jsonDecode(line) as Map)
          .toList();
      expect(requests.where((r) => r['method'] == 'thread/fork'), hasLength(1));
      expect(
        requests.where(
          (r) => ['thread/start', 'turn/start'].contains(r['method']),
        ),
        isEmpty,
      );
      if (mode == 'success') {
        expect(
          controller.activeSessionId,
          isNot(source.id),
          reason: controller.status,
        );
        expect(controller.turns.map((t) => t.userText), sourceText);
        expect(controller.sessions.first.title, '${source.title} (copy)');
        final binding = jsonDecode(
          await File('${directory.path}/binding.json').readAsString(),
        ) as Map;
        expect(binding['cwd'], '${directory.path}/source-workspace');
        await controller.switchSession(source.id);
        expect(controller.turns.map((t) => t.userText), sourceText);
      } else {
        expect(controller.activeSessionId, source.id);
        expect(controller.status, contains('Could not duplicate chat'));
      }
    });
  }
}
