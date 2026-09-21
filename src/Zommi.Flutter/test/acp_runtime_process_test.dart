import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';

void main() {
  for (final runtime in ['hermes', 'opencode']) {
    test('$runtime ACP runs end to end through the Rust adapter', () async {
      final fixture = File(
        '${Directory.current.path}/../../crates/zommi-core-host/tests/'
        'fake_acp_runtime.py',
      ).absolute;
      final temporary = await Directory.systemTemp.createTemp(
        'zommi-acp-rust-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final requestLog = File('${temporary.path}/requests.jsonl');
      final bridge = ProcessCoreBridge(
        executablePath: _coreHostPath(),
        environment: <String, String>{
          'ZOMMI_${runtime.toUpperCase()}_COMMAND': await _findPython(),
          'ZOMMI_${runtime.toUpperCase()}_ARGS_JSON': jsonEncode(<String>[
            fixture.path,
          ]),
          if (runtime == 'opencode') 'ZOMMI_FAKE_ACP_CONFIG_OPTIONS': '1',
          'ZOMMI_CORE_STATE_PATH': '${temporary.path}/binding.json',
          'ZOMMI_FAKE_REQUEST_LOG': requestLog.path,
        },
      );
      addTearDown(bridge.close);
      final events = <CoreEvent>[];
      final approval = Completer<CoreEvent>();
      final completed = Completer<CoreEvent>();
      final subscription = bridge.events.listen((event) {
        events.add(event);
        if (event.name == 'approval.requested' && !approval.isCompleted) {
          approval.complete(event);
        }
        if (event.name == 'turn.completed' && !completed.isCompleted) {
          completed.complete(event);
        }
      });
      addTearDown(subscription.cancel);

      await bridge.initialize();
      final discovery = await bridge.discoverRuntimeTargets();
      final target = discovery.targets.singleWhere(
        (target) => target.adapterId == '$runtime-acp',
      );
      final connection = await bridge.connectRuntime(
        runtimeTargetId: target.id,
        cwd: temporary.path,
      );
      expect(connection.sessionId, 'acp-session-new');
      expect(connection.runtimeVersion, '3.2.1');
      expect(
        connection.sessionMetadata['activeModel'],
        runtime == 'opencode' ? 'provider:model-b' : 'provider:model-a',
      );
      expect(
        connection.capabilities,
        containsAll(<String>[
          'session.list.v1',
          'session.resume.v1',
          'turn.stream.v1',
          'approval.resolve.v1',
          'input.image.v1',
        ]),
      );

      expect(
        connection.models.map((model) => model['id']),
        containsAll(['provider:model-a', 'provider:model-b']),
      );
      final receipt = await bridge.startTurn(
        runtimeTargetId: target.id,
        sessionId: connection.sessionId,
        message: 'request-approval and inspect this',
        model: 'provider:model-b',
        snapshots: const <Map<String, Object?>>[
          <String, Object?>{
            'surfaceKind': 'Window',
            'application': 'Fixture',
            'selection': <String>['selected context'],
          },
        ],
        images: const <String>['data:image/png;base64,aGVsbG8='],
        clientOperationId: 'client:rust-acp-turn',
      );
      final approvalEvent = await approval.future;
      expect(approvalEvent.sessionId, receipt.sessionId);
      expect(approvalEvent.payload['approvalId'], isNotEmpty);
      await expectLater(
        bridge.resolveApproval(
          runtimeTargetId: target.id,
          sessionId: 'wrong-acp-session',
          approvalId: approvalEvent.payload['approvalId']!.toString(),
          optionId: 'allow_once',
        ),
        throwsA(
          isA<CoreProtocolException>().having(
            (error) => error.code,
            'code',
            'identity-mismatch',
          ),
        ),
      );
      await bridge.resolveApproval(
        runtimeTargetId: target.id,
        sessionId: receipt.sessionId,
        approvalId: approvalEvent.payload['approvalId']!.toString(),
        optionId: 'allow_once',
      );
      final terminal = await completed.future;
      expect(terminal.turnId, receipt.turnId);
      expect(terminal.payload['status'], 'completed');
      final lifecycle = events
          .where(
            (event) =>
                event.clientOperationId == 'client:rust-acp-turn' &&
                <String>{
                  'turn.started',
                  'item.update',
                  'turn.completed',
                }.contains(event.name),
          )
          .map((event) => event.name)
          .toList();
      expect(lifecycle.first, 'turn.started');
      expect(lifecycle.last, 'turn.completed');
      expect(
        events
            .where((event) => event.name == 'item.update')
            .map((event) => event.payload['kind']),
        containsAll(<String>['thinking', 'assistant']),
      );
      final artifacts = events
          .where((event) => event.name == 'item.update')
          .expand(
            (event) =>
                (event.payload['artifacts'] as List<Object?>? ?? const []),
          )
          .cast<Map<Object?, Object?>>()
          .toList();
      expect(
        artifacts.map((artifact) => artifact['dataUrl']),
        contains('data:image/png;base64,aGVsbG8='),
      );
      expect(artifacts.single['cwd'], temporary.path);
      final history = await bridge.readSession(
        runtimeTargetId: target.id,
        sessionId: connection.sessionId,
      );
      expect(jsonEncode(history), contains('ACP Rust reply'));

      final interrupted = bridge.events.firstWhere(
        (event) =>
            event.name == 'turn.completed' &&
            event.payload['status'] == 'interrupted',
      );
      final held = await bridge.startTurn(
        runtimeTargetId: target.id,
        sessionId: connection.sessionId,
        message: 'hold-for-interrupt',
        clientOperationId: 'client:rust-acp-interrupt',
      );
      await bridge.interruptTurn(
        runtimeTargetId: target.id,
        sessionId: held.sessionId,
        turnId: held.turnId,
      );
      expect((await interrupted).turnId, held.turnId);

      final lateCompleted = bridge.events.firstWhere(
        (event) =>
            event.name == 'turn.completed' &&
            event.clientOperationId == 'client:rust-acp-late',
      );
      await bridge.startTurn(
        runtimeTargetId: target.id,
        sessionId: connection.sessionId,
        message: 'late-frame',
        clientOperationId: 'client:rust-acp-late',
      );
      await lateCompleted;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        events
            .where(
              (event) =>
                  event.clientOperationId == 'client:rust-acp-late' &&
                  event.name == 'item.update',
            )
            .map((event) => event.payload['text'])
            .join(),
        isNot(contains('late ACP output')),
      );

      final unknown = bridge.events.firstWhere(
        (event) =>
            event.name == 'turn.completed' &&
            event.payload['status'] == 'unknown',
      );
      final acceptedBeforeExit = await bridge.startTurn(
        runtimeTargetId: target.id,
        sessionId: connection.sessionId,
        message: 'exit-runtime',
        clientOperationId: 'client:rust-acp-exit',
      );
      final unknownEvent = await unknown;
      expect(unknownEvent.turnId, acceptedBeforeExit.turnId);
      expect(
        unknownEvent.payload['error'],
        isNot(contains('acp-adapter-secret')),
      );
      expect(
        unknownEvent.payload['error'],
        isNot(contains('captured private ACP context')),
      );

      final requests = await requestLog.readAsLines().then(
        (lines) => lines.map(jsonDecode).whereType<Map>().toList(),
      );
      expect(
        requests.any(
          (request) =>
              request['method'] == 'authenticate' &&
              (request['params'] as Map)['methodId'] == 'provider',
        ),
        isTrue,
      );
      final modelChange = requests.singleWhere(
        (request) =>
            request['method'] ==
            (runtime == 'opencode'
                ? 'session/set_config_option'
                : 'session/set_model'),
      );
      expect(jsonEncode(modelChange), contains('provider:model-b'));
      if (runtime == 'opencode') {
        expect((modelChange['params'] as Map)['configId'], 'provider-model');
        expect(
          requests.any((request) => request['method'] == 'session/set_model'),
          isFalse,
        );
      }
      final prompt = requests.firstWhere(
        (request) =>
            request['method'] == 'session/prompt' &&
            jsonEncode(request).contains('request-approval'),
      );
      expect(jsonEncode(prompt), contains('PRIMARY SURFACE SELECTION'));
      expect(jsonEncode(prompt), contains('"mimeType":"image/png"'));
      expect(
        requests.any(
          (request) =>
              request['id'] == 'permission-1' &&
              jsonEncode(request).contains('allow_once'),
        ),
        isTrue,
      );
    });
  }

  for (final prepared in [false, true]) {
    test(
      'OpenCode refresh picks up login models and preserves state (prepared=$prepared)',
      () async {
        final temporary = await Directory.systemTemp.createTemp(
          'zommi-acp-refresh-',
        );
        addTearDown(() => temporary.delete(recursive: true));
        final fixture = File(
          '${Directory.current.path}/../../crates/zommi-core-host/tests/fake_acp_runtime.py',
        ).absolute;
        final binding = File('${temporary.path}/binding.json');
        final requestLog = File('${temporary.path}/requests.jsonl');
        final modelFile = File('${temporary.path}/models.json');
        Future<void> writeModels({
          bool expanded = false,
          bool failLoad = false,
        }) => modelFile.writeAsString(
          jsonEncode({
            'failLoad': failLoad,
            'models': [
              {'modelId': 'provider:model-a', 'name': 'Model A'},
              {'modelId': 'provider:model-b', 'name': 'Model B'},
              if (expanded)
                {'modelId': 'provider:after-login', 'name': 'After login'},
            ],
          }),
        );
        await writeModels();
        final bridge = ProcessCoreBridge(
          executablePath: _coreHostPath(),
          environment: {
            'ZOMMI_OPENCODE_COMMAND': await _findPython(),
            'ZOMMI_OPENCODE_ARGS_JSON': jsonEncode([fixture.path]),
            'ZOMMI_CORE_STATE_PATH': binding.path,
            'ZOMMI_FAKE_REQUEST_LOG': requestLog.path,
            'ZOMMI_FAKE_ACP_CONFIG_OPTIONS': '1',
            'ZOMMI_FAKE_ACP_MODEL_FILE': modelFile.path,
          },
        );
        addTearDown(bridge.close);
        final events = <CoreEvent>[];
        final subscription = bridge.events.listen(events.add);
        addTearDown(subscription.cancel);
        await bridge.initialize();
        final target = (await bridge.discoverRuntimeTargets()).targets
            .singleWhere((t) => t.runtimeId == 'opencode');
        if (prepared) {
          await bridge.prepareRuntime(runtimeTargetId: target.id);
          await writeModels(expanded: true);
          expect(
            await bridge.refreshRuntimeModels(runtimeTargetId: target.id),
            isNull,
          );
          expect(await binding.exists(), isFalse);
        }
        final connection = await bridge.connectRuntime(
          runtimeTargetId: target.id,
          preferredSessionId: 'exact-saved-chat',
          cwd: temporary.path,
        );
        final beforeBinding = await binding.readAsString();
        final beforeHistory = await bridge.readSession(
          runtimeTargetId: target.id,
          sessionId: connection.sessionId,
        );
        await writeModels(expanded: true);
        events.clear();
        final models = await bridge.refreshRuntimeModels(
          runtimeTargetId: target.id,
        );
        expect(
          models!.map((m) => m['id']),
          containsAll([
            'provider:model-a',
            'provider:model-b',
            'provider:after-login',
          ]),
        );
        expect(await binding.readAsString(), beforeBinding);
        expect(
          await bridge.readSession(
            runtimeTargetId: target.id,
            sessionId: connection.sessionId,
          ),
          beforeHistory,
        );
        expect(events.where((e) => e.name == 'item.update'), isEmpty);
        final refreshed = await bridge.connectRuntime(
          runtimeTargetId: target.id,
        );
        expect(refreshed.sessionId, 'exact-saved-chat');
        expect(refreshed.sessionMetadata['activeModel'], 'provider:model-b');

        await writeModels(failLoad: true);
        await expectLater(
          bridge.refreshRuntimeModels(runtimeTargetId: target.id),
          throwsA(isA<CoreProtocolException>()),
        );
        expect(await binding.readAsString(), beforeBinding);
        expect(
          await bridge.readSession(
            runtimeTargetId: target.id,
            sessionId: connection.sessionId,
          ),
          beforeHistory,
        );
        expect(
          (await bridge.connectRuntime(runtimeTargetId: target.id)).models
              .map((m) => m['id']),
          contains('provider:after-login'),
        );
        await writeModels(expanded: true);
        await bridge.refreshRuntimeModels(runtimeTargetId: target.id);

        final receipt = await bridge.startTurn(
          runtimeTargetId: target.id,
          sessionId: connection.sessionId,
          message: 'hold-for-interrupt',
          model: 'provider:after-login',
        );
        await expectLater(
          bridge.refreshRuntimeModels(runtimeTargetId: target.id),
          throwsA(
            isA<CoreProtocolException>().having(
              (e) => e.code,
              'code',
              'session-busy',
            ),
          ),
        );
        await bridge.interruptTurn(
          runtimeTargetId: target.id,
          sessionId: connection.sessionId,
          turnId: receipt.turnId,
        );
        final requests = (await requestLog.readAsLines())
            .map(jsonDecode)
            .whereType<Map>()
            .toList();
        expect(requests.where((r) => r['method'] == 'session/new'), isEmpty);
        expect(
          requests
              .where((r) => r['method'] == 'session/load')
              .every(
                (r) =>
                    r['params']['sessionId'] == 'exact-saved-chat' &&
                    r['params']['cwd'] == temporary.path,
              ),
          isTrue,
        );
      },
    );
  }

  test('OpenClaw ACP keeps authentication inside its runtime bridge', () async {
    final fixture = File(
      '${Directory.current.path}/../../crates/zommi-core-host/tests/'
      'fake_acp_runtime.py',
    ).absolute;
    final temporary = await Directory.systemTemp.createTemp(
      'zommi-openclaw-acp-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final requestLog = File('${temporary.path}/requests.jsonl');
    final bridge = ProcessCoreBridge(
      executablePath: _coreHostPath(),
      environment: <String, String>{
        'ZOMMI_OPENCLAW_COMMAND': await _findPython(),
        'ZOMMI_OPENCLAW_ARGS_JSON': jsonEncode(<String>[fixture.path]),
        'ZOMMI_CORE_STATE_PATH': '${temporary.path}/binding.json',
        'ZOMMI_FAKE_REQUEST_LOG': requestLog.path,
        'ZOMMI_FAKE_ACP_NO_AUTH': '1',
      },
    );
    addTearDown(bridge.close);
    await bridge.initialize();
    final discovery = await bridge.discoverRuntimeTargets();
    final target = discovery.targets.singleWhere(
      (target) => target.adapterId == 'openclaw-acp',
    );
    final connection = await bridge.connectRuntime(
      runtimeTargetId: target.id,
      cwd: temporary.path,
    );
    expect(connection.sessionId, 'acp-session-new');
    final requests = await requestLog.readAsLines().then(
      (lines) => lines.map(jsonDecode).whereType<Map>().toList(),
    );
    expect(
      requests.any((request) => request['method'] == 'initialize'),
      isTrue,
    );
    expect(
      requests.any((request) => request['method'] == 'authenticate'),
      isFalse,
    );
  });
}

String _coreHostPath() {
  final executableName = Platform.isWindows
      ? 'zommi-core-host.exe'
      : 'zommi-core-host';
  final executable = File(
    '${Directory.current.path}/../../target/debug/$executableName',
  ).absolute;
  if (!executable.existsSync()) {
    throw StateError('Build the Rust workspace before running Flutter tests.');
  }
  return executable.path;
}

Future<String> _findPython() async {
  for (final candidate in <String>['python3', 'python']) {
    try {
      final result = await Process.run(candidate, const ['--version']);
      if (result.exitCode == 0) return candidate;
    } on ProcessException {
      // Try the next common executable name.
    }
  }
  throw StateError('Python is required for the deterministic ACP fixture.');
}
