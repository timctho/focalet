import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';

void main() {
  for (final index in [0, 1, 2, -1, 3]) {
    test('native edit at $index rewinds before submitting and survives reopening', () async {
      final directory = await Directory.systemTemp.createTemp('zommi-rewind-');
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
          'ZOMMI_FAKE_HISTORY_COUNT': '3',
          'ZOMMI_FAKE_REWIND_HISTORY': '1',
          if (index < 0) 'ZOMMI_FAKE_REWIND_FAIL': '1',
        },
      );
      final controller = ZommiController(
        core: bridge,
        desktop: const NoopDesktopBridge(),
        catalogStartupDelay: const Duration(days: 1),
      );
      addTearDown(controller.close);
      await controller.initialize();
      final target = controller.runtimeTargets.firstWhere(
        (target) =>
            target.adapterId == 'codex-app-server' &&
            target.executionHost['kind'] == 'native',
      );
      await controller.selectRuntime(target.id);
      await controller.switchSession('edit-chat');
      expect(controller.messageEditingSupported, isTrue);
      if (index == 3) {
        await controller.submit('hold-for-interrupt');
        await controller.submit('Discard queued follow-up');
      }
      final before = controller.turns.toList();
      final offset = (await log.readAsLines()).length;
      // Stale tails and missing targets must fail before mutating native history.
      for (final (turnId, lastId) in [
        ('missing', before.last.runtimeTurnId!),
        (before.first.runtimeTurnId!, 'stale-tail'),
      ]) {
        await expectLater(
          bridge.rewindSession(
            runtimeTargetId: target.id,
            sessionId: 'edit-chat',
            turnId: turnId,
            expectedLastTurnId: lastId,
          ),
          throwsA(
            isA<CoreProtocolException>().having(
              (error) => error.code,
              'code',
              index == 3 ? 'session-busy' : 'history-changed',
            ),
          ),
        );
      }
      final selected = index < 0 || index == 3 ? 1 : index;
      expect(
        await controller.resendMessage(before[selected], 'Replacement'),
        index >= 0,
        reason: controller.status,
      );
      final requests = (await log.readAsLines())
          .skip(offset)
          .map((line) => jsonDecode(line) as Map)
          .toList();
      final rollbacks = requests
          .where((request) => request['method'] == 'thread/revert')
          .toList();
      expect(rollbacks, hasLength(1));
      expect(rollbacks.single['params'], {
        'threadId': 'edit-chat',
        'beforeTurnId': before[selected].runtimeTurnId,
      });
      final starts = requests
          .where((request) => request['method'] == 'turn/start')
          .toList();
      if (index < 0) {
        expect(starts, isEmpty);
        expect(
          controller.turns.map((turn) => turn.userText),
          before.map((turn) => turn.userText),
        );
        return;
      }
      expect(starts, hasLength(1));
      expect(
        requests.indexOf(rollbacks.single),
        lessThan(requests.indexOf(starts.single)),
      );
      expect(
        requests.singleWhere(
          (request) => request.containsKey('modelContextTurnIds'),
        )['modelContextTurnIds'],
        before.take(selected).map((turn) => turn.runtimeTurnId).toList(),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (controller.turnActive && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(controller.turnActive, isFalse);
      final expected = [
        ...before.take(selected).map((turn) => turn.userText),
        'Replacement',
      ];
      expect(controller.turns.map((turn) => turn.userText), expected);
      await controller.switchSession('other-chat');
      await controller.switchSession('edit-chat');
      expect(controller.turns.map((turn) => turn.userText), expected);
      final canonical = await bridge.readSession(
        runtimeTargetId: target.id,
        sessionId: 'edit-chat',
      );
      expect((canonical['thread'] as Map)['turns'], hasLength(selected + 1));
      expect(controller.queuedMessages, isEmpty);
      if (index == 3) {
        final stop = requests.singleWhere(
          (request) => request['method'] == 'turn/interrupt',
        );
        expect(
          requests.indexOf(stop),
          lessThan(requests.indexOf(rollbacks.single)),
        );
      }
    });
  }
}
