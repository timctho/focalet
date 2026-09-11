import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/state/zommi_models.dart';

void main() {
  test('selected DOM and its image reach the agent protocol together after composer edits', () async {
    final executableName = Platform.isWindows
        ? 'zommi-core-host.exe'
        : 'zommi-core-host';
    final temporary = await Directory.systemTemp.createTemp(
      'zommi-dom-handoff-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final requestLog = File('${temporary.path}/requests.jsonl');
    final bridge = ProcessCoreBridge(
      executablePath: File('../../target/debug/$executableName').absolute.path,
      environment: {
        'ZOMMI_CODEX_COMMAND': await _findPython(),
        'ZOMMI_CODEX_ARGS_JSON': jsonEncode([
          File('../../crates/zommi-core-host/tests/fake_codex_app_server.py')
              .absolute
              .path,
        ]),
        'ZOMMI_CORE_STATE_PATH': '${temporary.path}/binding.json',
        'ZOMMI_RUNTIME_OVERRIDES_PATH': '${temporary.path}/overrides.json',
        'ZOMMI_FAKE_REQUEST_LOG': requestLog.path,
      },
    );
    final controller = ZommiController(
      core: bridge,
      desktop: const NoopDesktopBridge(),
    );
    addTearDown(controller.close);
    await controller.initialize();
    const original = 'first  line\n  第二行\tvalue';
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=';
    controller.addAttachment(
      ContextAttachment(
        id: 'removed',
        token: '',
        snapshot: const {
          'selection': ['REMOVED_CONTEXT_MUST_NOT_SEND'],
        },
      ),
    );
    controller.addAttachment(
      ContextAttachment(
        id: 'chosen',
        token: '',
        imageDataUrl: png,
        snapshot: const {
          'surfaceKind': 'Browser',
          'application': 'Chrome',
          'selection': [original],
          'source': {
            'provider': 'browser-dom',
            'nativeWindowId': 'window-1',
            'tabId': 'tab-1',
            'documentId': 'document-1',
          },
          'dom': {
            'mode': 'capture',
            'selectedText': [original],
          },
          'region': {
            'status': 'aligned',
            'mapping': {'coordinateSpace': 'browser-viewport-css-pixels'},
          },
        },
      ),
    );
    controller.removeAttachment('removed');
    final completed = bridge.events.firstWhere(
      (event) => event.name == 'turn.completed',
    );
    await controller.submit('Explain this selection.');
    await completed.timeout(const Duration(seconds: 15));
    final requests = (await requestLog.readAsLines()).map(
      (line) => jsonDecode(line) as Map<String, dynamic>,
    );
    final request = requests.singleWhere(
      (item) => item['method'] == 'turn/start',
    );
    final input = request['params']['input'] as List;
    expect(input, hasLength(2));
    final text = input[0]['text'] as String;
    expect(text, contains(jsonEncode(original)));
    expect(text, contains('"documentId":"document-1"'));
    expect(text, contains('browser-viewport-css-pixels'));
    expect(text, contains('Attached image 1 corresponds to this context.'));
    expect(text, isNot(contains('REMOVED_CONTEXT_MUST_NOT_SEND')));
    expect(input[1], {'type': 'image', 'url': png});
    expect(
      controller.turns.single.blocks
          .where((block) => block.kind == TranscriptKind.assistant)
          .single
          .text,
      'Rust-owned Codex reply',
    );
  });
  test(
    'rekeyed Codex completion renders once through Rust and controller',
    () async {
      final executableName = Platform.isWindows
          ? 'zommi-core-host.exe'
          : 'zommi-core-host';
      final executable = File('../../target/debug/$executableName').absolute;
      final fixture = File(
        '../../crates/zommi-core-host/tests/fake_codex_app_server.py',
      ).absolute;
      final temporary = await Directory.systemTemp.createTemp(
        'zommi-rekeyed-response-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final bridge = ProcessCoreBridge(
        executablePath: executable.path,
        environment: {
          'ZOMMI_CODEX_COMMAND': await _findPython(),
          'ZOMMI_CODEX_ARGS_JSON': jsonEncode([fixture.path]),
          'ZOMMI_CORE_STATE_PATH': '${temporary.path}/binding.json',
          'ZOMMI_RUNTIME_OVERRIDES_PATH': '${temporary.path}/overrides.json',
          'ZOMMI_FAKE_REKEY_COMPLETION': '1',
        },
      );
      final controller = ZommiController(
        core: bridge,
        desktop: const NoopDesktopBridge(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      final events = <CoreEvent>[];
      final streamedTexts = <String>[];
      final subscription = bridge.events.listen((event) {
        events.add(event);
        if (event.name == 'item.update' &&
            event.payload['lifecycle'] == 'delta') {
          streamedTexts.add(controller.turns.single.blocks.last.text);
        }
      });
      addTearDown(subscription.cancel);
      final completed = bridge.events.firstWhere(
        (event) => event.name == 'turn.completed',
      );
      await controller.submit('synthetic repeated characters');
      await completed.timeout(const Duration(seconds: 15));
      expect(controller.turns, hasLength(1));
      final answers = controller.turns.single.blocks.where(
        (block) => block.kind == TranscriptKind.assistant,
      );
      expect(answers, hasLength(1));
      expect(answers.single.text, 'Bookkeeper sees 111. 世界世界.');
      expect(streamedTexts, [
        'Book',
        'Bookkeeper',
        'Bookkeeper sees ',
        'Bookkeeper sees 1',
        'Bookkeeper sees 11',
        'Bookkeeper sees 111',
        'Bookkeeper sees 111. 世界',
        'Bookkeeper sees 111. 世界世界',
        'Bookkeeper sees 111. 世界世界.',
      ]);
      final updates = events
          .where(
            (event) =>
                event.name == 'item.update' &&
                event.payload['kind'] == 'assistant',
          )
          .toList();
      expect(updates.map((event) => event.payload['itemId']).toSet(), {
        'agent-fixture',
      });
      expect(
        updates
            .where((event) => event.payload['lifecycle'] == 'delta')
            .map((event) => event.payload['textMode']),
        everyElement('append'),
      );
      expect(updates.last.payload['replace'], isTrue);
    },
  );

  test('Flutter reports a missing Rust host without pending work', () async {
    final bridge = ProcessCoreBridge(
      executablePath:
          '${Directory.systemTemp.path}/zommi-core-host-does-not-exist',
    );
    await expectLater(bridge.initialize(), throwsA(isA<ProcessException>()));
    await bridge.close();
  });

  test(
    'Flutter exchanges versioned requests with the Rust core host',
    () async {
      final executableName = Platform.isWindows
          ? 'zommi-core-host.exe'
          : 'zommi-core-host';
      final executable = File(
        '${Directory.current.path}/../../target/debug/$executableName',
      ).absolute;
      expect(
        executable.existsSync(),
        isTrue,
        reason: 'Build the Rust workspace before running Flutter tests.',
      );

      final bridge = ProcessCoreBridge(executablePath: executable.path);
      addTearDown(bridge.close);
      final status = await bridge.initialize();
      expect(status.version, '0.1.0');
      expect(status.protocolVersion, coreProtocolVersion);
      expect(status.capabilities, contains('context.handoff.v1'));

      final handoff = await bridge.buildContextHandoff(
        message: 'compare this',
        snapshots: const [
          <String, Object?>{
            'surfaceKind': 'Browser',
            'application': 'Edge',
            'selection': <String>['selected value'],
            'locator': <String, Object?>{
              'kind': 'URL',
              'value': 'https://example.test/report',
            },
          },
        ],
        imageCount: 1,
      );
      expect(handoff, contains('<user_message>\ncompare this'));
      expect(handoff, contains('PRIMARY SURFACE SELECTION'));
      expect(handoff, contains('URL: https://example.test/report'));
      expect(handoff, contains('User-selected image regions attached: 1'));
    },
  );

  test(
    'Rust host keeps background runtime adapters alive across switches',
    () async {
      final executableName = Platform.isWindows
          ? 'zommi-core-host.exe'
          : 'zommi-core-host';
      final executable = File(
        '${Directory.current.path}/../../target/debug/$executableName',
      ).absolute;
      expect(executable.existsSync(), isTrue);
      final fixtureRoot = Directory(
        '${Directory.current.path}/../../crates/zommi-core-host/tests',
      ).absolute;
      final codexFixture = File('${fixtureRoot.path}/fake_codex_app_server.py');
      final piFixture = File('${fixtureRoot.path}/fake_pi_rpc.py');
      final python = await _findPython();
      final temporary = await Directory.systemTemp.createTemp(
        'zommi-multi-runtime-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final bridge = ProcessCoreBridge(
        executablePath: executable.path,
        environment: {
          'ZOMMI_CODEX_COMMAND': python,
          'ZOMMI_CODEX_ARGS_JSON': jsonEncode([codexFixture.path]),
          'ZOMMI_PI_COMMAND': python,
          'ZOMMI_PI_ARGS_JSON': jsonEncode([piFixture.path]),
          'ZOMMI_CORE_STATE_PATH': '${temporary.path}/binding.json',
          'ZOMMI_RUNTIME_OVERRIDES_PATH': '${temporary.path}/overrides.json',
        },
      );
      addTearDown(bridge.close);
      await bridge.initialize();
      final discovery = await bridge.discoverRuntimeTargets();
      final codex = discovery.targets.singleWhere(
        (target) => target.runtimeId == 'codex',
      );
      final pi = discovery.targets.singleWhere(
        (target) => target.runtimeId == 'pi',
      );
      final codexConnection = await bridge.connectRuntime(
        runtimeTargetId: codex.id,
        cwd: temporary.path,
      );
      final interrupted = bridge.events.firstWhere(
        (event) =>
            event.runtimeTargetId == codex.id &&
            event.name == 'turn.completed' &&
            event.payload['status'] == 'interrupted',
      );
      final held = await bridge.startTurn(
        runtimeTargetId: codex.id,
        sessionId: codexConnection.sessionId,
        message: 'hold-for-interrupt',
        clientOperationId: 'client:background-codex',
      );

      final piConnection = await bridge.connectRuntime(
        runtimeTargetId: pi.id,
        cwd: temporary.path,
      );
      expect(piConnection.runtimeTargetId, pi.id);
      await bridge.interruptTurn(
        runtimeTargetId: codex.id,
        sessionId: held.sessionId,
        turnId: held.turnId,
      );
      expect((await interrupted).turnId, held.turnId);
      expect(await bridge.listSessions(runtimeTargetId: pi.id), isNotEmpty);
      expect(await bridge.listSessions(runtimeTargetId: codex.id), isNotEmpty);
    },
  );

  test('Rust host replaces an exited Codex adapter on reconnect', () async {
    final executableName = Platform.isWindows
        ? 'zommi-core-host.exe'
        : 'zommi-core-host';
    final executable = File(
      '${Directory.current.path}/../../target/debug/$executableName',
    ).absolute;
    expect(executable.existsSync(), isTrue);
    final fixture = File(
      '${Directory.current.path}/../../crates/zommi-core-host/tests/'
      'fake_codex_app_server.py',
    ).absolute;
    final python = await _findPython();
    final temporary = await Directory.systemTemp.createTemp(
      'zommi-codex-reconnect-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final requestLog = File('${temporary.path}/requests.jsonl');
    final bridge = ProcessCoreBridge(
      executablePath: executable.path,
      environment: <String, String>{
        'ZOMMI_CODEX_COMMAND': python,
        'ZOMMI_CODEX_ARGS_JSON': jsonEncode(<String>[fixture.path]),
        'ZOMMI_CORE_STATE_PATH': '${temporary.path}/binding.json',
        'ZOMMI_FAKE_REQUEST_LOG': requestLog.path,
      },
    );
    addTearDown(bridge.close);
    await bridge.initialize();
    final discovery = await bridge.discoverRuntimeTargets();
    final codex = discovery.targets.singleWhere(
      (target) => target.runtimeId == 'codex',
    );
    final first = await bridge.connectRuntime(
      runtimeTargetId: codex.id,
      cwd: temporary.path,
    );
    final exited = bridge.events.firstWhere(
      (event) =>
          event.name == 'turn.completed' &&
          event.payload['status'] == 'unknown',
    );

    await bridge.startTurn(
      runtimeTargetId: codex.id,
      sessionId: first.sessionId,
      message: 'exit-runtime',
      clientOperationId: 'client:exit-runtime',
    );
    await exited.timeout(const Duration(seconds: 5));

    final reconnected = await bridge.connectRuntime(
      runtimeTargetId: codex.id,
      cwd: temporary.path,
    );
    expect(reconnected.runtimeTargetId, codex.id);
    expect(await bridge.listSessions(runtimeTargetId: codex.id), isNotEmpty);
    final processStarts = await requestLog.readAsLines().then(
      (lines) =>
          lines.where((line) => line.contains('fixtureOriginator')).length,
    );
    expect(processStarts, 2);
  });

  test('Flutter drives discovery, exact binding, streaming, and interrupt through Rust', () async {
    final executableName = Platform.isWindows
        ? 'zommi-core-host.exe'
        : 'zommi-core-host';
    final executable = File(
      '${Directory.current.path}/../../target/debug/$executableName',
    ).absolute;
    expect(executable.existsSync(), isTrue);
    final fixture = File(
      '${Directory.current.path}/../../crates/zommi-core-host/tests/'
      'fake_codex_app_server.py',
    ).absolute;
    expect(fixture.existsSync(), isTrue);
    final python = await _findPython();
    final temporary = await Directory.systemTemp.createTemp(
      'zommi-flutter-rust-codex-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final turnWorkspace = await Directory('${temporary.path}/turn-override')
        .create();
    final requestLog = File('${temporary.path}/requests.jsonl');
    final environment = <String, String>{
      'ZOMMI_CODEX_COMMAND': python,
      'ZOMMI_CODEX_ARGS_JSON': jsonEncode(<String>[fixture.path]),
      'ZOMMI_CORE_STATE_PATH': '${temporary.path}/binding.json',
      'ZOMMI_FAKE_REQUEST_LOG': requestLog.path,
    };

    final bridge = ProcessCoreBridge(
      executablePath: executable.path,
      environment: environment,
    );
    final events = <CoreEvent>[];
    final completed = Completer<CoreEvent>();
    final subscription = bridge.events.listen((event) {
      events.add(event);
      if (event.name == 'turn.completed' && !completed.isCompleted) {
        completed.complete(event);
      }
    });
    await bridge.initialize();
    final discovery = await bridge.discoverRuntimeTargets();
    final codexTarget = discovery.targets.singleWhere(
      (target) => target.runtimeId == 'codex',
    );
    expect(discovery.selectedTargetId, codexTarget.id);
    final connection = await bridge.connectRuntime(
      runtimeTargetId: codexTarget.id,
      cwd: temporary.path,
    );
    expect(connection.runtimeTargetId, codexTarget.id);
    expect(connection.sessionId, 'thread-rust-flutter');
    expect(connection.runtimeVersion, '9.8.7');
    final sessions = await bridge.listSessions(
      runtimeTargetId: connection.runtimeTargetId,
    );
    expect(
      sessions.map((session) => session['id']),
      contains(connection.sessionId),
    );
    final history = await bridge.readSession(
      runtimeTargetId: connection.runtimeTargetId,
      sessionId: connection.sessionId,
    );
    expect((history['thread'] as Map)['id'], connection.sessionId);
    final reopened = await bridge.openSession(
      runtimeTargetId: connection.runtimeTargetId,
      sessionId: connection.sessionId,
    );
    expect(reopened.sessionId, connection.sessionId);
    final configured = await bridge.configureSession(
      runtimeTargetId: connection.runtimeTargetId,
      sessionId: connection.sessionId,
      cwd: turnWorkspace.path,
    );
    expect(configured.sessionMetadata['cwd'], turnWorkspace.path);
    await expectLater(
      bridge.startTurn(
        runtimeTargetId: connection.runtimeTargetId,
        sessionId: connection.sessionId,
        message: 'must not reach Codex',
        clientOperationId: 'bad',
      ),
      throwsA(
        isA<CoreProtocolException>().having(
          (error) => error.code,
          'code',
          'invalid-request',
        ),
      ),
    );

    final receipt = await bridge.startTurn(
      runtimeTargetId: connection.runtimeTargetId,
      sessionId: connection.sessionId,
      message: 'compare selected context',
      snapshots: const [
        <String, Object?>{
          'surfaceKind': 'Browser',
          'application': 'Edge',
          'selection': <String>['selected value'],
        },
      ],
      images: const ['data:image/png;base64,aGVsbG8='],
      clientOperationId: 'client:flutter-rust-e2e',
      cwd: turnWorkspace.path,
    );
    expect(receipt.turnId, 'turn-rust-flutter');
    expect((await completed.future).payload['status'], 'completed');
    expect(
      events
          .where((event) => event.name == 'item.update')
          .map((event) => event.payload['text'])
          .whereType<String>(),
      contains('Rust-owned Codex reply'),
    );
    expect(
      events.where((event) => event.turnId == receipt.turnId),
      everyElement(
        isA<CoreEvent>()
            .having(
              (event) => event.runtimeTargetId,
              'runtimeTargetId',
              receipt.runtimeTargetId,
            )
            .having((event) => event.sessionId, 'sessionId', receipt.sessionId),
      ),
    );
    final replay = await bridge.startTurn(
      runtimeTargetId: connection.runtimeTargetId,
      sessionId: connection.sessionId,
      message: 'compare selected context',
      snapshots: const [
        <String, Object?>{
          'surfaceKind': 'Browser',
          'application': 'Edge',
          'selection': <String>['selected value'],
        },
      ],
      images: const ['data:image/png;base64,aGVsbG8='],
      clientOperationId: 'client:flutter-rust-e2e',
      cwd: turnWorkspace.path,
    );
    expect(replay.turnId, receipt.turnId);
    await expectLater(
      bridge.startTurn(
        runtimeTargetId: connection.runtimeTargetId,
        sessionId: connection.sessionId,
        message: 'conflicting replay',
        clientOperationId: 'client:flutter-rust-e2e',
      ),
      throwsA(
        isA<CoreProtocolException>().having(
          (error) => error.code,
          'code',
          'conflict',
        ),
      ),
    );
    await subscription.cancel();
    await bridge.close();

    final secondBridge = ProcessCoreBridge(
      executablePath: executable.path,
      environment: environment,
    );
    addTearDown(secondBridge.close);
    await secondBridge.initialize();
    final secondDiscovery = await secondBridge.discoverRuntimeTargets();
    final resumed = await secondBridge.connectRuntime(
      runtimeTargetId: secondDiscovery.selectedTargetId!,
      cwd: temporary.path,
    );
    expect(resumed.sessionId, 'thread-rust-flutter');

    final interruptCompleted = Completer<CoreEvent>();
    final secondSubscription = secondBridge.events.listen((event) {
      if (event.name == 'turn.completed' && !interruptCompleted.isCompleted) {
        interruptCompleted.complete(event);
      }
    });
    addTearDown(secondSubscription.cancel);
    final held = await secondBridge.startTurn(
      runtimeTargetId: resumed.runtimeTargetId,
      sessionId: resumed.sessionId,
      message: 'hold-for-interrupt',
      clientOperationId: 'client:flutter-rust-interrupt',
    );
    await expectLater(
      secondBridge.interruptTurn(
        runtimeTargetId: held.runtimeTargetId,
        sessionId: held.sessionId,
        turnId: 'another-turn',
      ),
      throwsA(
        isA<CoreProtocolException>().having(
          (error) => error.code,
          'code',
          'identity-mismatch',
        ),
      ),
    );
    await secondBridge.interruptTurn(
      runtimeTargetId: held.runtimeTargetId,
      sessionId: held.sessionId,
      turnId: held.turnId,
    );
    expect((await interruptCompleted.future).payload['status'], 'interrupted');

    final unknownOutcome = secondBridge.events.firstWhere(
      (event) =>
          event.name == 'turn.completed' &&
          event.payload['status'] == 'unknown',
    );
    final acceptedBeforeExit = await secondBridge.startTurn(
      runtimeTargetId: resumed.runtimeTargetId,
      sessionId: resumed.sessionId,
      message: 'exit-runtime',
      clientOperationId: 'client:flutter-rust-exit',
    );
    expect(acceptedBeforeExit.accepted, isTrue);
    final unknown = await unknownOutcome;
    expect(unknown.turnId, acceptedBeforeExit.turnId);
    expect(unknown.clientOperationId, 'client:flutter-rust-exit');
    expect(unknown.payload['error'], isNot(contains('fixture-private')));
    expect(
      unknown.payload['error'],
      isNot(contains('captured private context')),
    );

    final requests = await requestLog.readAsLines().then(
      (lines) => lines.map(jsonDecode).toList(growable: false),
    );
    expect(
      requests.whereType<Map>().any(
        (request) => request['fixtureOriginator'] == 'codex_exec',
      ),
      isTrue,
    );
    expect(
      requests.whereType<Map>().where(
        (request) => request['method'] == 'thread/resume',
      ),
      isNotEmpty,
    );
    final turnStart = requests.whereType<Map>().firstWhere(
      (request) =>
          request['method'] == 'turn/start' &&
          jsonEncode(request).contains('compare selected context'),
    );
    expect(
      requests.whereType<Map>().where(
        (request) =>
            request['method'] == 'turn/start' &&
            jsonEncode(request).contains('compare selected context'),
      ),
      hasLength(1),
    );
    final params = turnStart['params'] as Map;
    expect(params['summary'], 'detailed');
    expect(params['cwd'], turnWorkspace.path);
    expect(jsonEncode(params), contains('PRIMARY SURFACE SELECTION'));
    expect(jsonEncode(params), contains('data:image/png;base64,aGVsbG8='));
    final interrupt = requests.whereType<Map>().firstWhere(
      (request) => request['method'] == 'turn/interrupt',
    );
    expect(interrupt['params'], <String, Object?>{
      'threadId': 'thread-rust-flutter',
      'turnId': 'turn-rust-flutter',
    });
  });

  test(
    'Flutter persists and removes credential-free runtime overrides',
    () async {
      final executableName = Platform.isWindows
          ? 'zommi-core-host.exe'
          : 'zommi-core-host';
      final executable = File(
        '${Directory.current.path}/../../target/debug/$executableName',
      ).absolute;
      expect(executable.existsSync(), isTrue);
      final temporary = await Directory.systemTemp.createTemp(
        'zommi-runtime-override-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final bridge = ProcessCoreBridge(
        executablePath: executable.path,
        environment: {
          'ZOMMI_RUNTIME_OVERRIDES_PATH': '${temporary.path}/overrides.json',
          'ZOMMI_CORE_STATE_PATH': '${temporary.path}/binding.json',
        },
      );
      addTearDown(bridge.close);
      await bridge.initialize();
      final initial = await bridge.discoverRuntimeTargets();
      final hosts = initial.settings['hosts'] as List<Object?>;
      final nativeHost = hosts.whereType<Map>().firstWhere(
        (host) => host['kind'] == 'native',
      );
      final path = Platform.isWindows ? r'C:\Tools\codex.cmd' : '/opt/codex';
      final added = await bridge.addRuntimeOverride({
        'id': '',
        'adapterId': 'codex-app-server',
        'executionHost': Map<String, Object?>.from(nativeHost),
        'executablePath': path,
      });
      final overrides = added.settings['overrides'] as List<Object?>;
      expect(overrides, hasLength(1));
      final configured = Map<String, Object?>.from(overrides.single as Map);
      expect(configured['executablePath'], path);
      expect(jsonEncode(configured), isNot(contains('password')));
      expect(jsonEncode(configured), isNot(contains('token')));
      expect(
        added.targets.any(
          (target) =>
              target.executablePath == path && target.source == 'configured-ui',
        ),
        isTrue,
      );

      final removed = await bridge.removeRuntimeOverride(
        configured['id']!.toString(),
      );
      expect(removed.settings['overrides'], isEmpty);
    },
  );

  test(
    'a busy exact binding opens its history without replacing the chat',
    () async {
      final executableName = Platform.isWindows
          ? 'zommi-core-host.exe'
          : 'zommi-core-host';
      final executable = File(
        '${Directory.current.path}/../../target/debug/$executableName',
      ).absolute;
      final fixture = File(
        '${Directory.current.path}/../../crates/zommi-core-host/tests/'
        'fake_codex_app_server.py',
      ).absolute;
      final python = await _findPython();
      final temporary = await Directory.systemTemp.createTemp(
        'zommi-busy-binding-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final binding = File('${temporary.path}/binding.json');
      final requestLog = File('${temporary.path}/requests.jsonl');
      final bridge = ProcessCoreBridge(
        executablePath: executable.path,
        environment: <String, String>{
          'ZOMMI_CODEX_COMMAND': python,
          'ZOMMI_CODEX_ARGS_JSON': jsonEncode(<String>[fixture.path]),
          'ZOMMI_CORE_STATE_PATH': binding.path,
          'ZOMMI_FAKE_REQUEST_LOG': requestLog.path,
          'ZOMMI_FAKE_BUSY_RESUME': '1',
          'ZOMMI_FAKE_THREAD_ID': 'busy-thread',
          'ZOMMI_FAKE_FRESH_THREAD_ID': 'fresh-thread',
        },
      );
      addTearDown(bridge.close);
      await bridge.initialize();
      final discovery = await bridge.discoverRuntimeTargets();
      await binding.writeAsString(
        jsonEncode(<String, Object?>{
          'runtimeTargetId': discovery.selectedTargetId,
          'sessionId': 'busy-thread',
          'cwd': temporary.path,
        }),
      );
      final connection = await bridge.connectRuntime(
        runtimeTargetId: discovery.selectedTargetId!,
        cwd: temporary.path,
      );
      expect(connection.sessionId, 'busy-thread');
      expect(connection.sessionMetadata['readOnly'], isTrue);
      final requests = await requestLog.readAsLines().then(
        (lines) => lines.map(jsonDecode).whereType<Map>().toList(),
      );
      final resumeIndex = requests.indexWhere(
        (request) => request['method'] == 'thread/resume',
      );
      final startIndex = requests.indexWhere(
        (request) => request['method'] == 'thread/start',
      );
      expect(resumeIndex, greaterThanOrEqualTo(0));
      expect(startIndex, -1);
      expect(
        requests.any((request) => request['method'] == 'thread/read'),
        isTrue,
      );
    },
  );
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
  throw StateError('Python is required for the deterministic Codex fixture.');
}
