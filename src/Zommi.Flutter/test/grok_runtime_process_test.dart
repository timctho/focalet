import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';

void main() {
  Future<(ProcessCoreBridge, RuntimeTarget, File)> start({
    required bool authenticated,
  }) async {
    final directory = await Directory.systemTemp.createTemp('zommi-grok-');
    addTearDown(() => directory.delete(recursive: true));
    final log = File('${directory.path}/requests.jsonl');
    final bridge = ProcessCoreBridge(
      executablePath: File(
        '../../target/debug/zommi-core-host${Platform.isWindows ? '.exe' : ''}',
      ).absolute.path,
      environment: {
        'ZOMMI_RUNTIME_DISCOVERY_MODE': 'configured-only',
        'ZOMMI_GROK_COMMAND': Platform.isWindows ? 'python' : 'python3',
        'ZOMMI_GROK_ARGS_JSON': jsonEncode([
          File('../../crates/zommi-core-host/tests/fake_pi_rpc.py')
              .absolute
              .path,
        ]),
        'ZOMMI_CORE_STATE_PATH': '${directory.path}/binding.json',
        'ZOMMI_RUNTIME_OVERRIDES_PATH': '${directory.path}/overrides.json',
        'ZOMMI_RUNTIME_DISCOVERY_CACHE_PATH': '${directory.path}/targets.json',
        'ZOMMI_FAKE_REQUEST_LOG': log.path,
        'ZOMMI_FAKE_PI_GROK': authenticated ? '1' : '0',
      },
    );
    addTearDown(bridge.close);
    await bridge.initialize();
    final targets = await bridge.discoverRuntimeTargets();
    return (
      bridge,
      targets.targets.singleWhere((t) => t.runtimeId == 'grok'),
      log,
    );
  }

  test('Grok exposes only xAI models and supports chats, images and interruption via Pi', () async {
    final (bridge, target, log) = await start(authenticated: true);
    expect(target.displayName, 'Grok (via Pi)');
    final connection = await bridge.connectRuntime(runtimeTargetId: target.id);
    expect(connection.models.map((m) => m['id']), ['xai/grok-test']);
    expect(
      connection.capabilities,
      containsAll(['input.image.v1', 'session.resume.v1', 'turn.interrupt.v1']),
    );
    final refreshed = await bridge.refreshRuntimeModels(
      runtimeTargetId: target.id,
    );
    expect(refreshed?.map((m) => m['id']), ['xai/grok-test']);
    await expectLater(
      bridge.startTurn(
        runtimeTargetId: target.id,
        sessionId: connection.sessionId,
        message: 'must not run',
        model: 'openai/gpt-test',
        clientOperationId: 'wrong-model',
      ),
      throwsA(isA<CoreProtocolException>()),
    );
    final done = bridge.events.firstWhere((e) => e.name == 'turn.completed');
    final turn = await bridge.startTurn(
      runtimeTargetId: target.id,
      sessionId: connection.sessionId,
      message: 'hold-for-interrupt',
      model: 'xai/grok-test',
      images: ['data:image/png;base64,aGVsbG8='],
      clientOperationId: 'grok-image',
    );
    await bridge.interruptTurn(
      runtimeTargetId: target.id,
      sessionId: turn.sessionId,
      turnId: turn.turnId,
    );
    expect(
      (await done.timeout(const Duration(seconds: 5))).payload['status'],
      'interrupted',
    );
    final requests = (await log.readAsLines()).map(jsonDecode).cast<Map>();
    expect(requests.where((r) => r['type'] == 'prompt'), hasLength(1));
    expect(
      requests.firstWhere((r) => r['type'] == 'set_model')['provider'],
      'xai',
    );
  });

  test('Grok without xAI configuration gives setup guidance and never sends a prompt', () async {
    final (bridge, target, log) = await start(authenticated: false);
    await expectLater(
      bridge.connectRuntime(runtimeTargetId: target.id),
      throwsA(
        isA<CoreProtocolException>()
            .having((e) => e.code, 'code', 'authentication-required')
            .having((e) => e.message, 'setup', contains('pi --provider xai')),
      ),
    );
    final requests = (await log.readAsLines()).map(jsonDecode).cast<Map>();
    expect(requests.where((r) => r['type'] == 'prompt'), isEmpty);
    expect((await bridge.discoverRuntimeTargets()).targets, isNotEmpty);
  });
}
