import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focalet_flutter/core/core_bridge.dart';

Future<(ProcessCoreBridge, File)> bridgeFor(
  Directory root, {
  String delay = '3',
}) async {
  final log = File('${root.path}/requests.jsonl');
  final fixture = Directory('../../crates/focalet-core-host/tests')
      .absolute
      .path;
  final bridge = ProcessCoreBridge(
    executablePath: File(
      '../../target/debug/focalet-core-host${Platform.isWindows ? '.exe' : ''}',
    ).absolute.path,
    environment: {
      'FOCALET_CODEX_COMMAND': Platform.isWindows ? 'python' : 'python3',
      'FOCALET_CODEX_ARGS_JSON': jsonEncode([
        '$fixture/fake_codex_app_server.py',
      ]),
      'FOCALET_HERMES_COMMAND': Platform.isWindows ? 'python' : 'python3',
      'FOCALET_HERMES_GATEWAY_ARGS_JSON': jsonEncode([
        '$fixture/fake_gateway_runtime.py',
        '--mode',
        'hermes',
      ]),
      'FOCALET_FAKE_STARTUP_DELAY': delay,
      'FOCALET_FAKE_REQUEST_LOG': log.path,
      'FOCALET_CORE_STATE_PATH': '${root.path}/binding.json',
      'FOCALET_RUNTIME_OVERRIDES_PATH': '${root.path}/overrides.json',
      'FOCALET_RUNTIME_DISCOVERY_CACHE_PATH': '${root.path}/discovery.json',
    },
  );
  await bridge.initialize();
  return (bridge, log);
}

Future<List<Map>> requests(File log) async => await log.exists()
    ? (await log.readAsLines())
          .where((l) => l.isNotEmpty)
          .map(jsonDecode)
          .cast<Map>()
          .toList()
    : [];

Future<int> waitForStartup(File log) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    for (final request in await requests(log)) {
      if (request['method'] == 'fixture.startup') return request['pid'] as int;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('The isolated runtime did not start');
}

void main() {
  test(
    'replacing a dead prepared transport clears its preparation state',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'focalet-dead-prepared-',
      );
      addTearDown(() => root.delete(recursive: true));
      final (bridge, log) = await bridgeFor(root, delay: '0.2');
      addTearDown(bridge.close);
      final target = (await bridge.discoverRuntimeTargets()).targets.firstWhere(
        (target) => target.adapterId == 'hermes-gateway',
      );
      await bridge.prepareRuntime(runtimeTargetId: target.id);
      final runtimePid = await waitForStartup(log);
      final stopped = bridge.events.firstWhere(
        (event) =>
            event.runtimeTargetId == target.id &&
            event.name == 'runtime.status' &&
            event.payload['status'] == 'unavailable',
      );
      expect(Process.killPid(runtimePid), isTrue);
      await stopped.timeout(const Duration(seconds: 5));
      await bridge.connectRuntime(
        runtimeTargetId: target.id,
        preferredSessionId: 'hermes-stored-session',
      );
      final resumes = (await requests(log))
          .where((request) => request['method'] == 'session.resume')
          .length;
      expect(resumes, 1);
      await bridge.connectRuntime(
        runtimeTargetId: target.id,
        preferredSessionId: 'hermes-stored-session',
      );
      expect(
        (await requests(log))
            .where((request) => request['method'] == 'session.resume'),
        hasLength(resumes),
      );
    },
  );

  test(
    'parallel runtimes retain global operation-id conflict protection',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'focalet-operation-identity-',
      );
      addTearDown(() => root.delete(recursive: true));
      final (bridge, log) = await bridgeFor(root, delay: '0');
      addTearDown(bridge.close);
      final discovery = await bridge.discoverRuntimeTargets();
      final codex = discovery.targets.firstWhere(
        (target) => target.adapterId == 'codex-app-server',
      );
      final hermes = discovery.targets.firstWhere(
        (target) => target.adapterId == 'hermes-gateway',
      );
      await bridge.connectRuntime(
        runtimeTargetId: codex.id,
        preferredSessionId: 'exact-chat',
      );
      await bridge.connectRuntime(
        runtimeTargetId: hermes.id,
        preferredSessionId: 'hermes-stored-session',
      );
      await bridge.startTurn(
        runtimeTargetId: codex.id,
        sessionId: 'exact-chat',
        message: 'Isolated fixture turn',
        clientOperationId: 'same-operation',
      );
      await expectLater(
        bridge.startTurn(
          runtimeTargetId: hermes.id,
          sessionId: 'hermes-stored-session',
          message: 'Must not be submitted',
          clientOperationId: 'same-operation',
        ),
        throwsA(
          isA<CoreProtocolException>().having(
            (error) => error.code,
            'code',
            'conflict',
          ),
        ),
      );
      expect(
        (await requests(log))
            .where((request) => request['method'] == 'prompt.submit'),
        isEmpty,
      );
    },
  );

  for (final prepare in [true, false]) {
    test(
      '${prepare ? 'unselected preparation' : 'slow selection'} cannot block another runtime or overwrite its binding',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'focalet-background-',
        );
        addTearDown(() => root.delete(recursive: true));
        final (bridge, log) = await bridgeFor(root);
        addTearDown(bridge.close);
        final discovery = await bridge.discoverRuntimeTargets();
        final hermes = discovery.targets.firstWhere(
          (t) => t.adapterId == 'hermes-gateway',
        );
        final codex = discovery.targets.firstWhere(
          (t) => t.adapterId == 'codex-app-server',
        );
        var finished = false;
        final slow = prepare
            ? bridge.prepareRuntime(runtimeTargetId: hermes.id)
            : bridge.connectRuntime(
                runtimeTargetId: hermes.id,
                preferredSessionId: 'hermes-stored-session',
              );
        final completion = slow.then((_) => finished = true);
        await waitForStartup(log);
        final fast = await bridge
            .connectRuntime(
              runtimeTargetId: codex.id,
              preferredSessionId: 'foreground-chat',
            )
            .timeout(const Duration(seconds: 2));
        expect(fast.sessionId, 'foreground-chat');
        expect(finished, isFalse);
        final binding = File('${root.path}/binding.json');
        final selected = await binding.readAsString();
        await completion;
        expect(await binding.readAsString(), selected);
        if (prepare) {
          final methods = (await requests(log)).map((r) => r['method']);
          expect(
            methods.where(
              (m) => [
                'session.create',
                'session.resume',
                'prompt.submit',
              ].contains(m),
            ),
            isEmpty,
          );
          final watch = Stopwatch()..start();
          final connection = await bridge
              .connectRuntime(
                runtimeTargetId: hermes.id,
                preferredSessionId: 'hermes-stored-session',
              )
              .timeout(const Duration(seconds: 2));
          expect(connection.sessionId, 'hermes-stored-session');
          expect(
            watch.elapsed,
            lessThan(const Duration(seconds: 2)),
            reason: 'Retained handshake must avoid a second 3s process launch',
          );
        }
      },
    );
  }
  test('closing cancels a runtime starting in a worker', () async {
    final root = await Directory.systemTemp.createTemp(
      'focalet-background-close-',
    );
    addTearDown(() => root.delete(recursive: true));
    final (bridge, log) = await bridgeFor(root, delay: '30');
    final target = (await bridge.discoverRuntimeTargets()).targets.firstWhere(
      (t) => t.adapterId == 'hermes-gateway',
    );
    final pending = expectLater(
      bridge.prepareRuntime(runtimeTargetId: target.id),
      throwsA(isA<CoreProtocolException>()),
    );
    final runtimePid = await waitForStartup(log);
    await bridge.close().timeout(const Duration(seconds: 5));
    await pending;
    if (Platform.isLinux) {
      final process = Directory('/proc/$runtimePid');
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (await process.exists() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      expect(await process.exists(), isFalse);
    }
    expect(await File('${root.path}/binding.json').exists(), isFalse);
  });
  test(
    'prepared Codex initializes once and retains native history on activation',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'focalet-codex-prepared-',
      );
      addTearDown(() => root.delete(recursive: true));
      final (bridge, log) = await bridgeFor(root);
      addTearDown(bridge.close);
      final target = (await bridge.discoverRuntimeTargets()).targets.firstWhere(
        (t) => t.adapterId == 'codex-app-server',
      );
      await Future.wait([
        bridge.prepareRuntime(runtimeTargetId: target.id),
        bridge.prepareRuntime(runtimeTargetId: target.id),
      ]);
      expect(await File('${root.path}/binding.json').exists(), isFalse);
      expect(
        (await requests(log)).map((r) => r['method']),
        isNot(contains('thread/start')),
      );
      final connected = await bridge.connectRuntime(
        runtimeTargetId: target.id,
        preferredSessionId: 'exact-chat',
        cwd: root.path,
      );
      expect(connected.sessionId, 'exact-chat');
      expect(
        (await requests(log)).where((r) => r['method'] == 'initialize'),
        hasLength(1),
      );
      expect(
        (await requests(log)).where((r) => r['method'] == 'model/list'),
        hasLength(1),
      );
    },
  );
}
