import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';

void main() {
  test('Pi RPC runs sessions, stream, steering, questions, and interrupt in Rust', () async {
    final fixture = File(
      '${Directory.current.path}/../../crates/zommi-core-host/tests/fake_pi_rpc.py',
    ).absolute;
    final temporary = await Directory.systemTemp.createTemp('zommi-pi-rust-');
    addTearDown(() => temporary.delete(recursive: true));
    final requestLog = File('${temporary.path}/requests.jsonl');
    final statePath = '${temporary.path}/binding.json';
    final environment = <String, String>{
      'ZOMMI_PI_COMMAND': await _findPython(),
      'ZOMMI_PI_ARGS_JSON': jsonEncode(<String>[fixture.path]),
      'ZOMMI_CORE_STATE_PATH': statePath,
      'ZOMMI_FAKE_REQUEST_LOG': requestLog.path,
    };
    final bridge = ProcessCoreBridge(
      executablePath: _coreHostPath(),
      environment: environment,
    );
    final question = Completer<CoreEvent>();
    final completed = Completer<CoreEvent>();
    final events = <CoreEvent>[];
    final subscription = bridge.events.listen((event) {
      events.add(event);
      if (event.name == 'question.requested' && !question.isCompleted) {
        question.complete(event);
      }
      if (event.name == 'turn.completed' && !completed.isCompleted) {
        completed.complete(event);
      }
    });
    await bridge.initialize();
    final discovery = await bridge.discoverRuntimeTargets();
    final target = discovery.targets.singleWhere(
      (target) => target.adapterId == 'pi-rpc',
    );
    final connection = await bridge.connectRuntime(
      runtimeTargetId: target.id,
      cwd: temporary.path,
    );
    expect(connection.sessionId, 'pi-session-a');
    expect(connection.runtimeVersion, '4.5.6');
    expect(connection.sessionMetadata['sessionFile'], '/sessions/a.jsonl');
    expect(connection.capabilities, contains('turn.steer.v1'));

    await expectLater(
      bridge.startTurn(
        runtimeTargetId: target.id,
        sessionId: connection.sessionId,
        message: 'must not silently use another model',
        model: 'provider/removed-model',
      ),
      throwsA(
        isA<CoreProtocolException>().having(
          (error) => error.code,
          'code',
          'invalid-request',
        ),
      ),
    );
    expect(
      (await requestLog.readAsLines())
          .map(jsonDecode)
          .whereType<Map>()
          .where((request) => request['type'] == 'prompt'),
      isEmpty,
    );

    final receipt = await bridge.startTurn(
      runtimeTargetId: target.id,
      sessionId: connection.sessionId,
      message: 'ask-question about selected value',
      snapshots: const <Map<String, Object?>>[
        <String, Object?>{
          'surfaceKind': 'Window',
          'application': 'Fixture',
          'selection': <String>['selected value'],
        },
      ],
      images: const <String>['data:image/png;base64,aGVsbG8='],
      clientOperationId: 'client:rust-pi-turn',
    );
    await bridge.steerTurn(
      runtimeTargetId: target.id,
      sessionId: receipt.sessionId,
      turnId: receipt.turnId,
      message: 'also compare totals',
    );
    final questionEvent = await question.future;
    expect(questionEvent.payload['method'], 'confirm');
    await expectLater(
      bridge.resolveQuestion(
        runtimeTargetId: target.id,
        sessionId: 'wrong-pi-session',
        questionId: questionEvent.payload['questionId']!.toString(),
        answer: const <String, Object?>{'confirmed': true},
      ),
      throwsA(
        isA<CoreProtocolException>().having(
          (error) => error.code,
          'code',
          'identity-mismatch',
        ),
      ),
    );
    await bridge.resolveQuestion(
      runtimeTargetId: target.id,
      sessionId: receipt.sessionId,
      questionId: questionEvent.payload['questionId']!.toString(),
      answer: const <String, Object?>{'confirmed': true},
    );
    final terminal = await completed.future;
    expect(terminal.turnId, receipt.turnId);
    expect(terminal.payload['status'], 'completed');
    final lifecycle = events
        .where(
          (event) =>
              event.clientOperationId == 'client:rust-pi-turn' &&
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
          (event) => (event.payload['artifacts'] as List<Object?>? ?? const []),
        )
        .cast<Map<Object?, Object?>>()
        .toList();
    expect(
      artifacts.map((artifact) => artifact['kind']),
      containsAll(<String>['image', 'html']),
    );
    expect(artifacts.map((artifact) => artifact['cwd']).toSet(), <Object?>{
      temporary.path,
    });
    final history = await bridge.readSession(
      runtimeTargetId: target.id,
      sessionId: connection.sessionId,
    );
    expect(jsonEncode(history), contains('saved answer'));
    await subscription.cancel();
    await bridge.close();

    final binding = jsonDecode(await File(statePath).readAsString()) as Map;
    expect(
      (binding['sessionMetadata'] as Map)['sessionFile'],
      '/sessions/a.jsonl',
    );
    final secondBridge = ProcessCoreBridge(
      executablePath: _coreHostPath(),
      environment: <String, String>{
        ...environment,
        'ZOMMI_FAKE_PI_INITIAL_FILE': '/sessions/other.jsonl',
      },
    );
    addTearDown(secondBridge.close);
    await secondBridge.initialize();
    final secondDiscovery = await secondBridge.discoverRuntimeTargets();
    final secondTarget = secondDiscovery.targets.singleWhere(
      (target) => target.adapterId == 'pi-rpc',
    );
    final resumed = await secondBridge.connectRuntime(
      runtimeTargetId: secondTarget.id,
      cwd: temporary.path,
    );
    expect(resumed.sessionId, 'pi-session-a');
    final secondEvents = <CoreEvent>[];
    final secondSubscription = secondBridge.events.listen(secondEvents.add);
    addTearDown(secondSubscription.cancel);

    final interrupted = secondBridge.events.firstWhere(
      (event) =>
          event.name == 'turn.completed' &&
          event.payload['status'] == 'interrupted',
    );
    final held = await secondBridge.startTurn(
      runtimeTargetId: secondTarget.id,
      sessionId: resumed.sessionId,
      message: 'hold-for-interrupt',
      clientOperationId: 'client:rust-pi-interrupt',
    );
    await secondBridge.interruptTurn(
      runtimeTargetId: secondTarget.id,
      sessionId: held.sessionId,
      turnId: held.turnId,
    );
    expect((await interrupted).turnId, held.turnId);

    final lateCompleted = secondBridge.events.firstWhere(
      (event) =>
          event.name == 'turn.completed' &&
          event.clientOperationId == 'client:rust-pi-late',
    );
    await secondBridge.startTurn(
      runtimeTargetId: secondTarget.id,
      sessionId: resumed.sessionId,
      message: 'late-frame',
      clientOperationId: 'client:rust-pi-late',
    );
    await lateCompleted;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      secondEvents
          .where(
            (event) =>
                event.clientOperationId == 'client:rust-pi-late' &&
                event.name == 'item.update',
          )
          .map((event) => event.payload['text'])
          .join(),
      isNot(contains('late Pi output')),
    );

    final unknown = secondBridge.events.firstWhere(
      (event) =>
          event.name == 'turn.completed' &&
          event.payload['status'] == 'unknown',
    );
    final acceptedBeforeExit = await secondBridge.startTurn(
      runtimeTargetId: secondTarget.id,
      sessionId: resumed.sessionId,
      message: 'exit-runtime',
      clientOperationId: 'client:rust-pi-exit',
    );
    final unknownEvent = await unknown;
    expect(unknownEvent.turnId, acceptedBeforeExit.turnId);
    expect(unknownEvent.payload['error'], isNot(contains('pi-adapter-secret')));
    expect(
      unknownEvent.payload['error'],
      isNot(contains('captured private Pi context')),
    );

    final requests = await requestLog.readAsLines().then(
      (lines) => lines.map(jsonDecode).whereType<Map>().toList(),
    );
    expect(
      requests.any(
        (request) =>
            request['startupSession'] == 'pi-session-a' &&
            jsonEncode(request['startupArgs']) ==
                jsonEncode(['--session', '/sessions/a.jsonl']),
      ),
      isTrue,
    );
    final prompt = requests.firstWhere(
      (request) =>
          request['type'] == 'prompt' &&
          jsonEncode(request).contains('ask-question'),
    );
    expect(jsonEncode(prompt), contains('PRIMARY SURFACE SELECTION'));
    expect(jsonEncode(prompt), contains('"mimeType":"image/png"'));
    expect(requests.any((request) => request['type'] == 'steer'), isTrue);
    expect(
      requests.any(
        (request) =>
            request['type'] == 'extension_ui_response' &&
            request['confirmed'] == true,
      ),
      isTrue,
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
  throw StateError('Python is required for the deterministic Pi fixture.');
}
