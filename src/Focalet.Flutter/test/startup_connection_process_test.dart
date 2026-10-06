import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focalet_flutter/core/core_bridge.dart';
import 'package:focalet_flutter/desktop/desktop_bridge.dart';
import 'package:focalet_flutter/state/focalet_controller.dart';

void main() {
  for (final scenario in [
    'slow startup',
    'timed out startup',
    'first start fails',
  ]) {
    test('Hermes $scenario opens the saved chat without a sidebar click', () async {
      final directory = await Directory.systemTemp.createTemp(
        'focalet-startup-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final binding = File('${directory.path}/binding.json');
      final log = File('${directory.path}/requests.jsonl');
      final bridge = ProcessCoreBridge(
        executablePath: File(
          '../../target/debug/focalet-core-host${Platform.isWindows ? '.exe' : ''}',
        ).absolute.path,
        requestTimeout: const Duration(milliseconds: 500),
        connectionTimeout: scenario == 'timed out startup'
            ? const Duration(seconds: 1)
            : const Duration(seconds: 90),
        environment: {
          'FOCALET_HERMES_COMMAND': Platform.isWindows ? 'python' : 'python3',
          'FOCALET_HERMES_GATEWAY_ARGS_JSON': jsonEncode([
            File('../../crates/focalet-core-host/tests/fake_gateway_runtime.py')
                .absolute
                .path,
            '--mode',
            'hermes',
          ]),
          'FOCALET_FAKE_STARTUP_DELAY': scenario == 'timed out startup'
              ? '2'
              : '1',
          if (scenario == 'timed out startup')
            'FOCALET_FAKE_STARTUP_DELAY_MARKER':
                '${directory.path}/delayed-once',
          if (scenario == 'first start fails')
            'FOCALET_FAKE_STARTUP_FAILURE_MARKER':
                '${directory.path}/failed-once',
          'FOCALET_CORE_STATE_PATH': binding.path,
          'FOCALET_RUNTIME_OVERRIDES_PATH': '${directory.path}/overrides.json',
          'FOCALET_RUNTIME_DISCOVERY_CACHE_PATH':
              '${directory.path}/discovery.json',
          'FOCALET_FAKE_REQUEST_LOG': log.path,
        },
      );
      addTearDown(bridge.close);
      await bridge.initialize();
      final discovery = await bridge.discoverRuntimeTargets();
      final target = discovery.targets.firstWhere(
        (target) =>
            target.adapterId == 'hermes-gateway' &&
            target.executionHost['kind'] == 'native',
      );
      await binding.writeAsString(
        jsonEncode({
          'runtimeTargetId': target.id,
          'sessionId': 'hermes-coder-session',
          'cwd': directory.path,
          'sessionMetadata': {'profile': 'coder', 'cwd': directory.path},
        }),
      );
      final controller = FocaletController(
        core: bridge,
        desktop: const NoopDesktopBridge(),
        catalogStartupDelay: const Duration(days: 1),
      );
      addTearDown(controller.close);
      final elapsed = Stopwatch()..start();
      await controller.initialize();
      if (scenario == 'slow startup') {
        expect(elapsed.elapsed, greaterThan(const Duration(milliseconds: 500)));
        expect(
          controller.activeSessionId,
          'hermes-coder-session',
          reason: controller.status,
        );
      }
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while ((controller.activeSessionId != 'hermes-coder-session' ||
              controller.sessionBusy) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        controller.activeSessionId,
        'hermes-coder-session',
        reason: controller.status,
      );
      expect(controller.statusWarning, isFalse, reason: controller.status);
      expect(controller.selectedProfile, 'coder');
      expect(controller.turns.single.userText, 'saved question');
      expect(controller.turns.single.blocks.last.text, 'saved answer');
      final requests = (await log.readAsLines())
          .map(jsonDecode)
          .whereType<Map>()
          .toList();
      expect(
        requests.where(
          (value) =>
              ['session.create', 'prompt.submit'].contains(value['method']),
        ),
        isEmpty,
      );
      final resumes = requests.where(
        (value) => value['method'] == 'session.resume',
      );
      expect(resumes, isNotEmpty);
      for (final resume in resumes) {
        expect(resume['params']['session_id'], 'hermes-coder-session');
        expect(resume['params']['profile'], 'coder');
      }
      expect(
        jsonDecode(await binding.readAsString())['sessionId'],
        'hermes-coder-session',
      );
    });
  }
}
