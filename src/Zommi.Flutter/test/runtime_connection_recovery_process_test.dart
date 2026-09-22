import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';

void main() {
  late Directory root;
  late ProcessCoreBridge bridge;
  late RuntimeTarget target;

  Future<List<Map>> requests() async {
    final log = File('${root.path}/requests.jsonl');
    return await log.exists()
        ? (await log.readAsLines())
              .where((s) => s.isNotEmpty)
              .map(jsonDecode)
              .cast<Map>()
              .toList()
        : [];
  }

  Future<void> start({Duration timeout = const Duration(seconds: 12)}) async {
    root = await Directory.systemTemp.createTemp('zommi-connection-recovery-');
    addTearDown(() => root.delete(recursive: true));
    bridge = ProcessCoreBridge(
      executablePath: File(
        '../../target/debug/zommi-core-host${Platform.isWindows ? '.exe' : ''}',
      ).absolute.path,
      connectionTimeout: timeout,
      environment: {
        'ZOMMI_RUNTIME_DISCOVERY_MODE': 'configured-only',
        'ZOMMI_CODEX_COMMAND': Platform.isWindows ? 'python' : 'python3',
        'ZOMMI_CODEX_ARGS_JSON': jsonEncode([
          File('../../crates/zommi-core-host/tests/fake_codex_app_server.py')
              .absolute
              .path,
          '--control-dir',
          root.path,
        ]),
        'ZOMMI_CORE_STATE_PATH': '${root.path}/binding.json',
        'ZOMMI_RUNTIME_OVERRIDES_PATH': '${root.path}/overrides.json',
        'ZOMMI_RUNTIME_DISCOVERY_CACHE_PATH': '${root.path}/targets.json',
      },
    );
    addTearDown(bridge.close);
    await bridge.initialize();
    target = (await bridge.discoverRuntimeTargets()).targets.singleWhere(
      (t) => t.adapterId == 'codex-app-server',
    );
    await File('${root.path}/unique-threads').writeAsString('1');
  }

  test(
    'cold New chat creates one thread without resuming a previous binding',
    () async {
      await start();
      await File('${root.path}/binding.json').writeAsString(
        jsonEncode({
          'runtimeTargetId': target.id,
          'sessionId': 'old-chat',
          'cwd': root.path,
        }),
      );
      final connection = await bridge.createSession(runtimeTargetId: target.id);
      expect(connection.sessionId, 'fresh-1');
      final log = await requests();
      expect(log.where((r) => r['method'] == 'thread/start'), hasLength(1));
      expect(log.where((r) => r['method'] == 'thread/resume'), isEmpty);
      final done = bridge.events.firstWhere((e) => e.name == 'turn.completed');
      await bridge.startTurn(
        runtimeTargetId: target.id,
        sessionId: connection.sessionId,
        message: 'Hello',
        clientOperationId: 'one-turn',
      );
      await done.timeout(const Duration(seconds: 5));
    },
  );

  test(
    'first-run detection does not prepare or create an agent before selection',
    () async {
      await start();
      final controller = ZommiController(
        core: bridge,
        desktop: const NoopDesktopBridge(),
        runtimeSetupPending: true,
      );
      addTearDown(controller.close);
      await controller.initialize();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(await requests(), isEmpty);
      expect(controller.activeSessionId, isNull);
      expect(await controller.connectRuntimeForSetup(target.id), isTrue);
      expect(
        (await requests()).where((r) => r['method'] == 'thread/start'),
        hasLength(1),
      );
    },
  );

  test('unresponsive catalogs cannot prevent a new Codex chat', () async {
    await start();
    await File('${root.path}/stall-catalogs').writeAsString('1');
    final connection = await bridge.createSession(runtimeTargetId: target.id);
    expect(connection.sessionId, 'fresh-1');
    expect(connection.models, isEmpty);
    expect(
      (await requests()).where((r) => r['method'] == 'thread/start'),
      hasLength(1),
    );
  });

  test(
    'timed out initialization releases the worker and a fresh retry succeeds',
    () async {
      await start(timeout: const Duration(seconds: 2));
      final stall = File('${root.path}/stall-initialize');
      await stall.writeAsString('1');
      await expectLater(
        bridge.createSession(runtimeTargetId: target.id),
        throwsA(
          isA<CoreProtocolException>().having(
            (e) => e.code,
            'code',
            'runtime-timeout',
          ),
        ),
      );
      // The broker remains usable while the failed target can be retried.
      expect((await bridge.initialize()).protocolVersion, 1);
      await stall.delete();
      final connection = await bridge.createSession(runtimeTargetId: target.id);
      expect(connection.sessionId, 'fresh-1');
      expect(
        (await requests()).where((r) => r['method'] == 'thread/start'),
        hasLength(1),
      );
    },
  );

  test('core replacement restores the exact chat and draft without replaying turns', () async {
    await start();
    final controller = ZommiController(
      core: bridge,
      desktop: const NoopDesktopBridge(),
    );
    addTearDown(controller.close);
    await controller.initialize();
    final session = controller.activeSessionId;
    final done = bridge.events.firstWhere((e) => e.name == 'turn.completed');
    await controller.submit('Only once');
    await done.timeout(const Duration(seconds: 5));
    controller.updateComposerValue(
      const TextEditingValue(text: 'Keep this draft'),
    );
    await bridge.restartCore();
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline) &&
        (controller.sessionBusy || controller.status != 'Chat switched')) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(controller.activeSessionId, session);
    expect(controller.status, 'Chat switched');
    expect(controller.composerValue.text, 'Keep this draft');
    expect(
      (await requests()).where((r) => r['method'] == 'turn/start'),
      hasLength(1),
    );
    expect(
      (await requests()).where((r) => r['method'] == 'thread/start'),
      hasLength(1),
    );
  });
}
