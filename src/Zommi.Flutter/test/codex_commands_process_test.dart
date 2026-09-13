import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';

void main() {
  Future<(ZommiController, ProcessCoreBridge, File)> setup({
    bool unsupported = false,
  }) async {
    final temporary = await Directory.systemTemp.createTemp(
      'zommi-command-contract-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final log = File('${temporary.path}/requests.jsonl');
    // Windows may resolve python3 to the Microsoft Store execution alias.
    // Use the installed interpreter, matching the other process fixtures.
    final python = Platform.isWindows ? 'python' : 'python3';
    final bridge = ProcessCoreBridge(
      executablePath: File(
        '../../target/debug/zommi-core-host${Platform.isWindows ? '.exe' : ''}',
      ).absolute.path,
      environment: {
        'ZOMMI_CODEX_COMMAND': python,
        'ZOMMI_CODEX_ARGS_JSON': jsonEncode([
          File('../../crates/zommi-core-host/tests/fake_codex_app_server.py')
              .absolute
              .path,
        ]),
        'ZOMMI_CORE_STATE_PATH': '${temporary.path}/binding.json',
        'ZOMMI_RUNTIME_OVERRIDES_PATH': '${temporary.path}/overrides.json',
        'ZOMMI_RUNTIME_DISCOVERY_CACHE_PATH': '${temporary.path}/targets.json',
        'ZOMMI_FAKE_REQUEST_LOG': log.path,
        'ZOMMI_FAKE_FRESH_THREAD_ID': 'new-command-thread',
        'ZOMMI_FAKE_GOAL_TURNS': '1',
        'ZOMMI_FAKE_UNIQUE_THREADS': '1',
        if (unsupported) 'ZOMMI_FAKE_GOAL_UNSUPPORTED': '1',
      },
    );
    final controller = ZommiController(
      core: bridge,
      desktop: const NoopDesktopBridge(),
    );
    addTearDown(controller.close);
    // Windows normally prefers WSL. Pin the native fixture before the
    // controller selects a runtime so the test never reaches a real agent.
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
    expect(controller.activeSessionId, isNotNull, reason: controller.status);
    return (controller, bridge, log);
  }

  List<Map<String, dynamic>> requests(File log) => log
      .readAsLinesSync()
      .map((line) => jsonDecode(line) as Map<String, dynamic>)
      .toList();

  test('composer commands cross the Rust broker and control the exact native goal without duplicate turns', () async {
    final (controller, bridge, log) = await setup();
    final originalId = controller.activeSessionId!;
    controller.selectedModel = 'command-test-model';
    controller.selectedEffort = 'high';
    final started = bridge.events.firstWhere((e) => e.name == 'turn.started');
    await controller.submit('/goal Finish the exact task');
    await started.timeout(const Duration(seconds: 10));
    expect(controller.turnActive, isTrue);
    expect(controller.commandResult, contains('Finish the exact task'));
    await controller.submit('/goal pause');
    expect(controller.commandResult, contains('Goal · paused'));
    await controller.submit('/goal');
    expect(controller.commandResult, contains('Finish the exact task'));
    await controller.submit('/goal edit');
    expect(controller.composerValue.text, '/goal Finish the exact task');
    await controller.submit('/goal resume');
    expect(controller.commandResult, contains('Goal · active'));
    await controller.submit('/goal pause');
    final completed = bridge.events.firstWhere(
      (e) => e.name == 'turn.completed',
    );
    await controller.interrupt();
    await completed.timeout(const Duration(seconds: 10));
    await controller.submit('/goal clear');
    expect(controller.commandResult, contains('No goal set'));
    final restarted = bridge.events.firstWhere((e) => e.name == 'turn.started');
    await controller.submit('/goal A second objective');
    await restarted.timeout(const Duration(seconds: 10));
    await controller.submit('/clear');
    expect(controller.activeSessionId, 'new-command-thread-2');
    expect(controller.activeSessionId, isNot(originalId));
    final all = requests(log);
    final sets = all.where((r) => r['method'] == 'thread/goal/set').toList();
    expect(sets.map((r) => r['params']['threadId']).toSet(), {originalId});
    expect(sets.first['params']['objective'], 'Finish the exact task');
    expect(
      sets
          .skip(1)
          .take(3)
          .every((r) => !(r['params'] as Map).containsKey('objective')),
      isTrue,
    );
    final settings = all.firstWhere(
      (r) => r['method'] == 'thread/settings/update',
    );
    expect(settings['params'], containsPair('model', 'command-test-model'));
    expect(settings['params'], containsPair('effort', 'high'));
    expect(all.indexOf(settings), lessThan(all.indexOf(sets.first)));
    expect(sets.last['params'], {'threadId': originalId, 'status': 'paused'});
    expect(
      all.firstWhere(
        (r) => r['method'] == 'initialize',
      )['params']['capabilities'],
      {'experimentalApi': true},
    );
    expect(all.where((r) => r['method'] == 'turn/start'), isEmpty);
    expect(
      all.where(
        (r) =>
            r['method'] == 'thread/delete' || r['method'] == 'thread/archive',
      ),
      isEmpty,
    );
    final before = all.length;
    await expectLater(
      bridge.goalCommand(
        runtimeTargetId: controller.activeRuntime!.id,
        sessionId: originalId,
        action: 'clear',
      ),
      throwsA(isA<CoreProtocolException>()),
    );
    expect(
      requests(log)
          .skip(before)
          .where((r) => r['method'] == 'thread/goal/clear'),
      isEmpty,
    );
  });

  test(
    'background command discovery and history requests share the core pipe',
    () async {
      final (controller, bridge, _) = await setup();
      final target = controller.activeRuntime!.id;
      final session = controller.activeSessionId!;
      final results = await Future.wait([
        for (var i = 0; i < 12; i++) ...[
          bridge.listCommands(runtimeTargetId: target, sessionId: session),
          bridge.readSession(runtimeTargetId: target, sessionId: session),
        ],
      ]);
      expect(results, hasLength(24));
    },
  );

  test('unavailable native goal API reports failure and never sends slash text to the model', () async {
    final (controller, bridge, log) = await setup(unsupported: true);
    await controller.submit('/goal Do work');
    expect(controller.commandResult, contains('Goals are unavailable'));
    expect(requests(log).where((r) => r['method'] == 'turn/start'), isEmpty);
    await expectLater(
      bridge.goalCommand(
        runtimeTargetId: controller.activeRuntime!.id,
        sessionId: controller.activeSessionId!,
        action: 'set',
        objective: '𐐀' * 4001,
      ),
      throwsA(isA<CoreProtocolException>()),
    );
    expect(
      requests(log).where((r) => r['method'] == 'thread/goal/set'),
      hasLength(1),
    );
  });
}
