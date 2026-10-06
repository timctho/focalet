import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focalet_flutter/core/core_bridge.dart';
import 'package:focalet_flutter/desktop/desktop_bridge.dart';
import 'package:focalet_flutter/state/focalet_controller.dart';
import 'package:focalet_flutter/state/focalet_models.dart';

void main() {
  test(
    'a crashed child recovers through the host and streams into the same chat',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'focalet-recovery-process-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final python = Platform.isWindows ? 'python' : 'python3';
      final host = Platform.isWindows
          ? 'focalet-core-host.exe'
          : 'focalet-core-host';
      final bridge = ProcessCoreBridge(
        executablePath: File('../../target/debug/$host').absolute.path,
        environment: {
          'FOCALET_CODEX_COMMAND': python,
          'FOCALET_CODEX_ARGS_JSON': jsonEncode([
            File(
              '../../crates/focalet-core-host/tests/fake_codex_app_server.py',
            ).absolute.path,
            '--control-dir',
            temporary.path,
          ]),
          'FOCALET_CORE_STATE_PATH': '${temporary.path}/binding.json',
          'FOCALET_RUNTIME_OVERRIDES_PATH': '${temporary.path}/overrides.json',
          'FOCALET_RUNTIME_DISCOVERY_CACHE_PATH':
              '${temporary.path}/targets.json',
        },
      );
      final controller = FocaletController(
        core: bridge,
        desktop: const NoopDesktopBridge(),
      );
      addTearDown(controller.close);
      // Windows normally prefers its default WSL runtime. Bind this test to
      // the native Python fixture before the controller chooses a runtime.
      await bridge.initialize();
      final discovery = await bridge.discoverRuntimeTargets();
      final fixtureTarget = discovery.targets.singleWhere(
        (target) =>
            target.runtimeId == 'codex' &&
            target.executionHost['kind'] == 'native',
      );
      await bridge.connectRuntime(
        runtimeTargetId: fixtureTarget.id,
        cwd: temporary.path,
      );
      await controller.initialize();
      expect(controller.activeRuntime?.runtimeId, 'codex');
      final runtimeTargetId = controller.activeRuntime!.id;
      final sessionId = controller.activeSessionId!;
      controller.selectedWorkspace = temporary.path;
      final model = controller.selectedModel;
      final effort = controller.selectedEffort;
      await controller.submit('hold-for-interrupt');
      final operationId = controller.turns.single.id;
      final turnId = controller.activeTurnId!;
      final events = <CoreEvent>[];
      final subscription = bridge.events.listen(events.add);
      addTearDown(subscription.cancel);
      final recovery = bridge.events.firstWhere(
        (e) => e.name == 'runtime.recovered',
      );
      final log = File('${temporary.path}/requests.jsonl');
      final initialRequests = (await log.readAsLines())
          .map(jsonDecode)
          .cast<Map>();
      final pid = initialRequests.firstWhere(
        (r) => r['fixturePid'] != null,
      )['fixturePid'];
      await File('${temporary.path}/exit-pid').writeAsString('$pid');
      final recovered = await recovery.timeout(const Duration(seconds: 10));
      expect(controller.activeSessionId, sessionId);
      expect(controller.selectedWorkspace, temporary.path);
      expect(controller.turnActive, isFalse);
      expect(
        controller.turns.single.blocks
            .where((b) => b.kind == TranscriptKind.error)
            .single
            .text,
        contains('not resent'),
      );
      final unknown = events.singleWhere(
        (e) => e.name == 'turn.completed' && e.payload['status'] == 'unknown',
      );
      expect(recovered.sequence, greaterThan(unknown.sequence));

      // Retrying the original operation id must return its receipt without
      // resending a turn that the old child already accepted.
      final duplicate = await bridge.startTurn(
        runtimeTargetId: runtimeTargetId,
        sessionId: sessionId,
        message: 'hold-for-interrupt',
        clientOperationId: operationId,
        cwd: temporary.path,
        model: model.isEmpty ? null : model,
        effort: effort.isEmpty ? null : effort,
      );
      expect(duplicate.turnId, turnId);
      final completed = bridge.events.firstWhere(
        (e) => e.name == 'turn.completed' && e.payload['status'] == 'completed',
      );
      await controller.submit('reply after recovery');
      await completed.timeout(const Duration(seconds: 10));
      expect(controller.turns, hasLength(2));
      expect(
        controller.turns.last.blocks
            .where((b) => b.kind == TranscriptKind.assistant)
            .single
            .text,
        'Rust-owned Codex reply',
      );
      expect(controller.turnActive, isFalse);
      final requests = (await log.readAsLines())
          .map(jsonDecode)
          .cast<Map>()
          .toList();
      expect(requests.where((r) => r['fixturePid'] != null), hasLength(2));
      expect(requests.where((r) => r['method'] == 'turn/start'), hasLength(2));
      expect(
        requests
            .where((r) => r['method'] == 'thread/resume')
            .last['params']['threadId'],
        sessionId,
      );
    },
  );
}
