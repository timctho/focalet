import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/state/history_mapper.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/state/zommi_models.dart';

import 'test_support.dart';

void main() {
  for (final initiallyUnavailable in [false, true]) {
    test(
      'Hermes refresh bypasses provider cache and restores model selection (unavailable=$initiallyUnavailable)',
      () async {
        final temporary = await Directory.systemTemp.createTemp(
          'zommi-hermes-models-',
        );
        addTearDown(() => temporary.delete(recursive: true));
        final modelFile = File('${temporary.path}/models.json');
        if (initiallyUnavailable) {
          await modelFile.writeAsString(jsonEncode({'fail': true}));
        }
        final requestLog = File('${temporary.path}/requests.jsonl');
        final bridge = ProcessCoreBridge(
          executablePath: _coreHostPath(),
          environment: {
            'ZOMMI_HERMES_COMMAND': await _findPython(),
            'ZOMMI_HERMES_GATEWAY_ARGS_JSON': jsonEncode([
              _fixturePath().path,
              '--mode',
              'hermes',
            ]),
            'ZOMMI_CORE_STATE_PATH': '${temporary.path}/binding.json',
            'ZOMMI_FAKE_GATEWAY_MODEL_FILE': modelFile.path,
            'ZOMMI_FAKE_HERMES_LAZY_INFO': '1',
            'ZOMMI_FAKE_REQUEST_LOG': requestLog.path,
          },
        );
        addTearDown(bridge.close);
        await bridge.initialize();
        final target = (await bridge.discoverRuntimeTargets()).targets
            .singleWhere((target) => target.adapterId == 'hermes-gateway');
        final connection = await bridge.connectRuntime(
          runtimeTargetId: target.id,
          cwd: temporary.path,
        );
        await modelFile.writeAsString(
          jsonEncode({
            'requireRefresh': true,
            'providers': [
              {
                'slug': 'copilot',
                'models': ['gpt-test', 'after-login'],
              },
              {
                'slug': 'custom',
                'models': ['after-login'],
              },
            ],
          }),
        );
        final models = await bridge.refreshRuntimeModels(
          runtimeTargetId: target.id,
        );
        expect(
          models!.map((model) => model['id']),
          containsAll(['copilot::after-login', 'custom::after-login']),
        );
        final refreshed = await bridge.connectRuntime(
          runtimeTargetId: target.id,
        );
        expect(refreshed.sessionId, connection.sessionId);
        expect(refreshed.capabilities, contains('model.select.v1'));
        await bridge.createSession(
          runtimeTargetId: target.id,
          model: connection.sessionMetadata['activeModel'] as String,
        );
        final createRequest = (await _readRequests(requestLog))
            .lastWhere((request) => request['method'] == 'session.create');
        expect((createRequest['params'] as Map)['model'], 'gpt-test');
        expect((createRequest['params'] as Map)['provider'], 'copilot');
        await expectLater(
          bridge.startTurn(
            runtimeTargetId: target.id,
            sessionId: connection.sessionId,
            message: 'must not be submitted using another model',
            model: 'copilot::removed-model',
          ),
          throwsA(
            isA<CoreProtocolException>().having(
              (error) => error.message,
              'message',
              contains('model'),
            ),
          ),
        );
        expect(
          (await _readRequests(requestLog))
              .where((request) => request['method'] == 'prompt.submit'),
          isEmpty,
        );
      },
    );
  }

  for (final switchWhileRunning in [false, true]) {
    test(
      'Hermes preserves reply order when switching ${switchWhileRunning ? 'during' : 'after'} a turn',
      () async {
        final temporary = await Directory.systemTemp.createTemp(
          'zommi-hermes-order-',
        );
        addTearDown(() => temporary.delete(recursive: true));
        final bridge = ProcessCoreBridge(
          executablePath: _coreHostPath(),
          environment: {
            'ZOMMI_HERMES_COMMAND': await _findPython(),
            'ZOMMI_HERMES_GATEWAY_ARGS_JSON': jsonEncode([
              _fixturePath().path,
              '--mode',
              'hermes',
            ]),
            'ZOMMI_CORE_STATE_PATH': '${temporary.path}/binding.json',
          },
        );
        addTearDown(bridge.close);
        await bridge.initialize();
        final discovery = await bridge.discoverRuntimeTargets();
        final target = discovery.targets.singleWhere(
          (target) => target.adapterId == 'hermes-gateway',
        );
        final connection = await bridge.connectRuntime(
          runtimeTargetId: target.id,
          cwd: temporary.path,
        );

        // Run the real adapter's normalized events through the production Flutter
        // reducer; only the runtime/session identity is bound to this test chat.
        final core = RichFakeCore()..historyCount = 0;
        final controller = ZommiController(
          core: core,
          desktop: FakeDesktopBridge(),
        );
        addTearDown(controller.close);
        await controller.initialize();
        final prompt = switchWhileRunning
            ? 'timeline-order-hold'
            : 'timeline-order';
        await controller.submit(prompt);
        final liveTurnId = controller.turns.single.id;
        final subscription = bridge.events.listen((event) {
          if (event.sessionId != connection.sessionId) return;
          core.emit(
            CoreEvent(
              name: event.name,
              sequence: event.sequence,
              runtimeTargetId: 'runtime-codex',
              sessionId: 'session-1',
              turnId: liveTurnId,
              payload: event.payload,
            ),
          );
        });
        addTearDown(subscription.cancel);
        final complete = bridge.events.firstWhere(
          (event) => event.name == 'turn.completed',
        );
        final toolStarted = bridge.events.firstWhere(
          (event) =>
              event.name == 'item.update' && event.payload['kind'] == 'tool',
        );
        await bridge.startTurn(
          runtimeTargetId: target.id,
          sessionId: connection.sessionId,
          message: prompt,
          snapshots: const [],
          images: const [],
          clientOperationId: 'hermes-order',
        );
        if (switchWhileRunning) {
          await toolStarted;
          await bridge.openSession(
            runtimeTargetId: target.id,
            sessionId: 'hermes-coder-session',
          );
          await bridge.openSession(
            runtimeTargetId: target.id,
            sessionId: connection.sessionId,
          );
        }
        await complete;
        await Future<void>.delayed(Duration.zero);
        final live = controller.turns.single;
        final expectedKinds = [
          TranscriptKind.thinking,
          TranscriptKind.assistant,
          TranscriptKind.tool,
          TranscriptKind.thinking,
          TranscriptKind.assistant,
          TranscriptKind.thinking,
          TranscriptKind.assistant,
        ];
        expect(live.blocks.map((block) => block.kind), expectedKinds);
        expect(
          live.blocks
              .where((block) => block.kind.isMessage)
              .map((block) => block.text),
          ['Checking files', 'Checking results', 'Verified answer'],
        );
        expect(
          live.blocks
              .where((block) => block.kind == TranscriptKind.thinking)
              .map((block) => block.text),
          ['First reasoning', 'Second reasoning', 'Final reasoning'],
        );
        expect(
          live.blocks.where((block) => block.kind == TranscriptKind.tool),
          hasLength(1),
        );
        expect(
          live.blocks
              .where((block) => block.isActivity)
              .every((block) => block.completed),
          isTrue,
        );

        final immediate = mapThreadHistory(
          await bridge.readSession(
            runtimeTargetId: target.id,
            sessionId: connection.sessionId,
          ),
        ).last;
        expect(immediate.blocks.map((block) => block.kind), expectedKinds);
        expect(immediate.blocks.last.text, 'Verified answer');
        await bridge.openSession(
          runtimeTargetId: target.id,
          sessionId: 'hermes-coder-session',
        );
        await bridge.openSession(
          runtimeTargetId: target.id,
          sessionId: connection.sessionId,
        );
        final restored = mapThreadHistory(
          await bridge.readSession(
            runtimeTargetId: target.id,
            sessionId: connection.sessionId,
          ),
        ).last;
        expect(restored.blocks.map((block) => block.kind), expectedKinds);
        for (final primary in [live, restored]) {
          final merged = mergeConversationTurn(
            primary,
            identical(primary, live) ? restored : live,
          );
          expect(merged.blocks.map((block) => block.kind), expectedKinds);
          expect(merged.blocks.last.text, 'Verified answer');
          expect(
            merged.blocks.where((block) => block.kind == TranscriptKind.tool),
            hasLength(1),
          );
        }
      },
    );
  }
  test(
    'Hermes falls back to legacy session listing when REST is unavailable',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'zommi-hermes-legacy-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final bridge = ProcessCoreBridge(
        executablePath: _coreHostPath(),
        environment: {
          'ZOMMI_HERMES_COMMAND': await _findPython(),
          'ZOMMI_HERMES_GATEWAY_ARGS_JSON': jsonEncode([
            _fixturePath().path,
            '--mode',
            'hermes',
          ]),
          'ZOMMI_CORE_STATE_PATH': '${temporary.path}/binding.json',
          'ZOMMI_FAKE_HERMES_LEGACY_SESSION_LIST': '1',
        },
      );
      addTearDown(bridge.close);
      await bridge.initialize();
      final discovery = await bridge.discoverRuntimeTargets();
      final target = discovery.targets.singleWhere(
        (target) => target.adapterId == 'hermes-gateway',
      );
      final connection = await bridge.connectRuntime(
        runtimeTargetId: target.id,
        cwd: temporary.path,
      );
      expect(connection.sessions, isNotEmpty);
      expect(connection.sessions.first['updatedAt'], 12);
    },
  );

  test(
    'Hermes Gateway runs exact sessions and lifecycle over WebSocket',
    () async {
      final fixture = _fixturePath();
      final temporary = await Directory.systemTemp.createTemp(
        'zommi-hermes-gateway-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final requestLog = File('${temporary.path}/requests.jsonl');
      final environment = <String, String>{
        'ZOMMI_HERMES_COMMAND': await _findPython(),
        'ZOMMI_HERMES_GATEWAY_ARGS_JSON': jsonEncode(<String>[
          fixture.path,
          '--mode',
          'hermes',
        ]),
        'ZOMMI_CORE_STATE_PATH': '${temporary.path}/binding.json',
        'ZOMMI_FAKE_REQUEST_LOG': requestLog.path,
      };
      final bridge = ProcessCoreBridge(
        executablePath: _coreHostPath(),
        environment: environment,
      );
      addTearDown(bridge.close);
      final events = <CoreEvent>[];
      final subscription = bridge.events.listen(events.add);
      addTearDown(subscription.cancel);

      await bridge.initialize();
      final discovery = await bridge.discoverRuntimeTargets();
      final target = discovery.targets.singleWhere(
        (target) => target.adapterId == 'hermes-gateway',
      );
      final connection = await bridge.connectRuntime(
        runtimeTargetId: target.id,
        cwd: temporary.path,
      );
      expect(connection.sessionId, 'hermes-stored-session');
      expect(connection.protocolVersion, 1);
      expect(connection.runtimeVersion, '0.20.0');
      expect(connection.sessions.first['updatedAt'], 50.5);
      expect(connection.sessions.first['profile'], 'coder');
      expect(
        connection.capabilities,
        containsAll(<String>[
          'turn.stream.v1',
          'turn.interrupt.v1',
          'approval.resolve.v1',
          'question.resolve.v1',
        ]),
      );

      final approval = bridge.events.firstWhere(
        (event) => event.name == 'approval.requested',
      );
      final question = bridge.events.firstWhere(
        (event) => event.name == 'question.requested',
      );
      final completed = bridge.events.firstWhere(
        (event) =>
            event.name == 'turn.completed' &&
            event.payload['status'] == 'completed',
      );
      final receipt = await bridge.startTurn(
        runtimeTargetId: target.id,
        sessionId: connection.sessionId,
        message: 'request-interactions and inspect this',
        snapshots: const <Map<String, Object?>>[
          <String, Object?>{
            'surfaceKind': 'Window',
            'application': 'Fixture',
            'selection': <String>['selected context'],
          },
        ],
        images: const <String>['data:image/png;base64,aGVsbG8='],
        clientOperationId: 'client:hermes-gateway-rust',
      );
      final approvalEvent = await approval;
      final questionEvent = await question;
      expect(approvalEvent.sessionId, receipt.sessionId);
      expect(questionEvent.sessionId, receipt.sessionId);
      await expectLater(
        bridge.resolveApproval(
          runtimeTargetId: target.id,
          sessionId: 'wrong-hermes-session',
          approvalId: approvalEvent.payload['approvalId']!.toString(),
          optionId: 'once',
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
        optionId: 'once',
      );
      await bridge.resolveQuestion(
        runtimeTargetId: target.id,
        sessionId: receipt.sessionId,
        questionId: questionEvent.payload['questionId']!.toString(),
        answer: const <String, Object?>{'value': 'dev'},
      );
      expect((await completed).turnId, receipt.turnId);
      final lifecycle = events
          .where(
            (event) =>
                event.clientOperationId == 'client:hermes-gateway-rust' &&
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

      final interrupted = bridge.events.firstWhere(
        (event) =>
            event.name == 'turn.completed' &&
            event.payload['status'] == 'interrupted',
      );
      final held = await bridge.startTurn(
        runtimeTargetId: target.id,
        sessionId: connection.sessionId,
        message: 'hold-for-interrupt',
        clientOperationId: 'client:hermes-gateway-interrupt',
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
            event.clientOperationId == 'client:hermes-gateway-late',
      );
      await bridge.startTurn(
        runtimeTargetId: target.id,
        sessionId: connection.sessionId,
        message: 'late-frame',
        clientOperationId: 'client:hermes-gateway-late',
      );
      await lateCompleted;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        events
            .where(
              (event) =>
                  event.clientOperationId == 'client:hermes-gateway-late' &&
                  event.name == 'turn.completed',
            )
            .length,
        1,
      );
      expect(
        events
            .where(
              (event) =>
                  event.clientOperationId == 'client:hermes-gateway-late' &&
                  event.name == 'item.update',
            )
            .map((event) => event.payload['text'])
            .join(),
        isNot(contains('late')),
      );

      await bridge.close();
      final resumed = ProcessCoreBridge(
        executablePath: _coreHostPath(),
        environment: environment,
      );
      addTearDown(resumed.close);
      await resumed.initialize();
      final resumedTarget = (await resumed.discoverRuntimeTargets()).targets
          .singleWhere((target) => target.adapterId == 'hermes-gateway');
      final resumedConnection = await resumed.connectRuntime(
        runtimeTargetId: resumedTarget.id,
        cwd: temporary.path,
      );
      expect(resumedConnection.sessionId, 'hermes-stored-session');
      final unknown = resumed.events.firstWhere(
        (event) =>
            event.name == 'turn.completed' &&
            event.payload['status'] == 'unknown',
      );
      final accepted = await resumed.startTurn(
        runtimeTargetId: resumedTarget.id,
        sessionId: resumedConnection.sessionId,
        message: 'disconnect-after-accept',
        clientOperationId: 'client:hermes-gateway-disconnect',
      );
      expect((await unknown).turnId, accepted.turnId);

      final requests = await _readRequests(requestLog);
      expect(
        requests.where((request) => request['method'] == 'http.sessions'),
        isNotEmpty,
      );
      final listing = requests.firstWhere(
        (request) => request['method'] == 'http.sessions',
      );
      expect((listing['params'] as Map)['order'], ['recent']);
      expect(
        requests
            .where((request) => request['method'] == 'session.create')
            .length,
        1,
      );
      expect(
        requests
            .where((request) => request['method'] == 'session.resume')
            .length,
        1,
      );
      expect(
        jsonEncode(
          requests.firstWhere(
            (request) => request['method'] == 'prompt.submit',
          ),
        ),
        contains('PRIMARY SURFACE SELECTION'),
      );
    },
  );

  test(
    'Hermes workspace and profile settings use native Gateway RPCs',
    () async {
      final fixture = _fixturePath();
      final temporary = await Directory.systemTemp.createTemp(
        'zommi-hermes-settings-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final changedWorkspace = await Directory('${temporary.path}/changed')
          .create();
      final coderWorkspace = await Directory('${temporary.path}/coder')
          .create();
      final requestLog = File('${temporary.path}/requests.jsonl');
      final bridge = ProcessCoreBridge(
        executablePath: _coreHostPath(),
        environment: <String, String>{
          'ZOMMI_HERMES_COMMAND': await _findPython(),
          'ZOMMI_HERMES_GATEWAY_ARGS_JSON': jsonEncode(<String>[
            fixture.path,
            '--mode',
            'hermes',
          ]),
          'ZOMMI_CORE_STATE_PATH': '${temporary.path}/binding.json',
          'ZOMMI_FAKE_REQUEST_LOG': requestLog.path,
        },
      );
      addTearDown(bridge.close);

      await bridge.initialize();
      final target = (await bridge.discoverRuntimeTargets()).targets
          .singleWhere((target) => target.adapterId == 'hermes-gateway');
      final connection = await bridge.connectRuntime(
        runtimeTargetId: target.id,
        cwd: temporary.path,
      );
      expect(
        (connection.sessionMetadata['profiles'] as List).whereType<Map>().map(
          (profile) => profile['name'],
        ),
        containsAll(<String>['default', 'coder']),
      );
      expect(connection.sessionMetadata['profile'], 'default');

      final moved = await bridge.configureSession(
        runtimeTargetId: target.id,
        sessionId: connection.sessionId,
        cwd: changedWorkspace.path,
      );
      expect(moved.sessionMetadata['cwd'], changedWorkspace.path);

      final switched = await bridge.configureSession(
        runtimeTargetId: target.id,
        sessionId: moved.sessionId,
        cwd: coderWorkspace.path,
        profile: 'coder',
        model: 'copilot::gpt-test',
        effort: 'medium',
      );
      expect(switched.sessionId, 'hermes-coder-session');
      expect(switched.sessionMetadata['profile'], 'coder');
      expect(switched.sessionMetadata['cwd'], coderWorkspace.path);

      final requests = await _readRequests(requestLog);
      expect(
        requests.any(
          (request) =>
              request['method'] == 'session.cwd.set' &&
              (request['params'] as Map)['cwd'] == changedWorkspace.path,
        ),
        isTrue,
      );
      expect(
        requests.any(
          (request) =>
              request['method'] == 'session.create' &&
              (request['params'] as Map)['profile'] == 'coder' &&
              (request['params'] as Map)['cwd'] == coderWorkspace.path,
        ),
        isTrue,
      );
    },
  );

  test(
    'OpenClaw v4 Gateway preserves identity and terminal ordering',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'zommi-openclaw-gateway-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final requestLog = File('${temporary.path}/requests.jsonl');
      final fixture = await _startOpenClawFixture(requestLog);
      addTearDown(() => fixture.process.kill());
      final environment = <String, String>{
        'ZOMMI_OPENCLAW_GATEWAY_URL': fixture.endpoint,
        'ZOMMI_OPENCLAW_GATEWAY_AGENT_ID': 'main',
        'OPENCLAW_GATEWAY_TOKEN': 'fixture-runtime-owned-token',
        'ZOMMI_CORE_STATE_PATH': '${temporary.path}/binding.json',
        'ZOMMI_OPENCLAW_DEVICE_IDENTITY_PATH':
            '${temporary.path}/openclaw-device.json',
        'ZOMMI_FAKE_REQUEST_LOG': requestLog.path,
      };
      final bridge = ProcessCoreBridge(
        executablePath: _coreHostPath(),
        environment: environment,
      );
      addTearDown(bridge.close);
      final events = <CoreEvent>[];
      final subscription = bridge.events.listen(events.add);
      addTearDown(subscription.cancel);
      await bridge.initialize();
      final discovery = await bridge.discoverRuntimeTargets();
      final target = discovery.targets.singleWhere(
        (target) => target.adapterId == 'openclaw-gateway',
      );
      expect(
        target.endpoint,
        fixture.endpoint.endsWith('/')
            ? fixture.endpoint
            : '${fixture.endpoint}/',
      );
      expect(target.profileId, 'main');
      final connection = await bridge.connectRuntime(
        runtimeTargetId: target.id,
        cwd: temporary.path,
      );
      expect(connection.sessionId, 'agent:main:zommi-rust');
      expect(connection.protocolVersion, 4);
      expect(connection.runtimeVersion, '2026.8.1');
      expect(connection.capabilities, contains('operation.idempotency.v1'));

      final created = await bridge.createSession(
        runtimeTargetId: target.id,
        model: 'custom::gpt-test',
      );
      expect(created.sessionMetadata['activeModel'], 'custom::gpt-test');
      final createRequest = (await _readRequests(requestLog))
          .lastWhere((request) => request['method'] == 'sessions.create');
      expect((createRequest['params'] as Map)['model'], 'custom/gpt-test');
      await expectLater(
        bridge.startTurn(
          runtimeTargetId: target.id,
          sessionId: created.sessionId,
          message: 'must not silently use the active model',
          model: 'custom::removed-model',
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
        (await _readRequests(requestLog))
            .where((request) => request['method'] == 'chat.send'),
        isEmpty,
      );

      final approval = bridge.events.firstWhere(
        (event) => event.name == 'approval.requested',
      );
      final question = bridge.events.firstWhere(
        (event) => event.name == 'question.requested',
      );
      final completed = bridge.events.firstWhere(
        (event) =>
            event.name == 'turn.completed' &&
            event.payload['status'] == 'completed',
      );
      final receipt = await bridge.startTurn(
        runtimeTargetId: target.id,
        sessionId: connection.sessionId,
        message: 'request-interactions and inspect this',
        snapshots: const <Map<String, Object?>>[
          <String, Object?>{
            'surfaceKind': 'Window',
            'application': 'Fixture',
            'selection': <String>['selected context'],
          },
        ],
        images: const <String>['data:image/png;base64,aGVsbG8='],
        clientOperationId: 'client:openclaw-gateway-rust',
      );
      final approvalEvent = await approval;
      final questionEvent = await question;
      expect(questionEvent.payload['questions'], hasLength(2));
      await expectLater(
        bridge.resolveQuestion(
          runtimeTargetId: target.id,
          sessionId: 'wrong-openclaw-session',
          questionId: questionEvent.payload['questionId']!.toString(),
          answer: const <String, Object?>{
            'answers': <String, Object?>{
              'branch': <String>['dev'],
              'reason': <String>['safer'],
            },
          },
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
        optionId: 'allow-once',
      );
      await bridge.resolveQuestion(
        runtimeTargetId: target.id,
        sessionId: receipt.sessionId,
        questionId: questionEvent.payload['questionId']!.toString(),
        answer: const <String, Object?>{
          'answers': <String, Object?>{
            'branch': <String>['dev'],
            'reason': <String>['safer'],
          },
        },
      );
      expect((await completed).turnId, receipt.turnId);
      final lifecycle = events
          .where(
            (event) =>
                event.clientOperationId == 'client:openclaw-gateway-rust' &&
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

      final lifecycleFallback = bridge.events.firstWhere(
        (event) =>
            event.name == 'turn.completed' &&
            event.clientOperationId == 'client:openclaw-agent-lifecycle',
      );
      final lifecycleReceipt = await bridge.startTurn(
        runtimeTargetId: target.id,
        sessionId: connection.sessionId,
        message: 'agent-lifecycle',
        clientOperationId: 'client:openclaw-agent-lifecycle',
      );
      final lifecycleTerminal = await lifecycleFallback;
      expect(lifecycleTerminal.turnId, lifecycleReceipt.turnId);
      expect(lifecycleTerminal.payload['status'], 'completed');
      expect(lifecycleTerminal.payload['evidence'], 'agent-lifecycle');

      final interrupted = bridge.events.firstWhere(
        (event) =>
            event.name == 'turn.completed' &&
            event.payload['status'] == 'interrupted',
      );
      final held = await bridge.startTurn(
        runtimeTargetId: target.id,
        sessionId: connection.sessionId,
        message: 'hold-for-interrupt',
        clientOperationId: 'client:openclaw-gateway-interrupt',
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
            event.clientOperationId == 'client:openclaw-gateway-late',
      );
      await bridge.startTurn(
        runtimeTargetId: target.id,
        sessionId: connection.sessionId,
        message: 'late-frame',
        clientOperationId: 'client:openclaw-gateway-late',
      );
      await lateCompleted;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        events
            .where(
              (event) =>
                  event.clientOperationId == 'client:openclaw-gateway-late' &&
                  event.name == 'turn.completed',
            )
            .length,
        1,
      );
      expect(
        events
            .where(
              (event) =>
                  event.clientOperationId == 'client:openclaw-gateway-late' &&
                  event.name == 'item.update',
            )
            .map((event) => event.payload['text'])
            .join(),
        isNot(contains('late')),
      );

      await bridge.close();
      final resumed = ProcessCoreBridge(
        executablePath: _coreHostPath(),
        environment: environment,
      );
      addTearDown(resumed.close);
      await resumed.initialize();
      final resumedTarget = (await resumed.discoverRuntimeTargets()).targets
          .singleWhere((target) => target.adapterId == 'openclaw-gateway');
      final resumedConnection = await resumed.connectRuntime(
        runtimeTargetId: resumedTarget.id,
        cwd: temporary.path,
      );
      expect(resumedConnection.sessionId, 'agent:main:zommi-rust');
      final unknown = resumed.events.firstWhere(
        (event) =>
            event.name == 'turn.completed' &&
            event.payload['status'] == 'unknown',
      );
      final accepted = await resumed.startTurn(
        runtimeTargetId: resumedTarget.id,
        sessionId: resumedConnection.sessionId,
        message: 'disconnect-after-accept',
        clientOperationId: 'client:openclaw-gateway-disconnect',
      );
      expect((await unknown).turnId, accepted.turnId);

      final requests = await _readRequests(requestLog);
      final connect = requests.firstWhere(
        (request) => request['method'] == 'connect',
      );
      expect(connect['type'], 'req');
      expect((connect['params'] as Map)['minProtocol'], 4);
      expect(
        ((connect['params'] as Map)['device'] as Map)['id'],
        hasLength(64),
      );
      expect(
        jsonEncode(connect),
        isNot(contains('fixture-runtime-owned-token')),
      );
      expect(
        requests
            .where((request) => request['method'] == 'sessions.create')
            .length,
        2, // Initial connection and the explicit provider/model selection.
      );
      final create = requests.firstWhere(
        (request) => request['method'] == 'sessions.create',
      );
      expect((create['params'] as Map)['agentId'], 'main');
      final send = requests.firstWhere(
        (request) => request['method'] == 'chat.send',
      );
      expect(
        (send['params'] as Map)['idempotencyKey'],
        'client:openclaw-gateway-rust',
      );
      expect(jsonEncode(send), contains('PRIMARY SURFACE SELECTION'));
      final connects = requests
          .where((request) => request['method'] == 'connect')
          .toList();
      expect(connects, hasLength(2));
      expect(
        (((connects.first['params'] as Map)['device'] as Map)['id']),
        (((connects.last['params'] as Map)['device'] as Map)['id']),
      );
      expect(
        await File('${temporary.path}/binding.json').readAsString(),
        isNot(contains('fixture-issued-device-token')),
      );
    },
  );
}

final class _GatewayFixture {
  const _GatewayFixture({required this.process, required this.endpoint});

  final Process process;
  final String endpoint;
}

Future<_GatewayFixture> _startOpenClawFixture(File requestLog) async {
  final process = await Process.start(
    await _findPython(),
    <String>[_fixturePath().path, '--mode', 'openclaw'],
    environment: <String, String>{
      ...Platform.environment,
      'ZOMMI_FAKE_REQUEST_LOG': requestLog.path,
    },
  );
  final line = await process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .first
      .timeout(const Duration(seconds: 10));
  const prefix = 'OPENCLAW_GATEWAY_READY ';
  if (!line.startsWith(prefix)) {
    process.kill();
    throw StateError('OpenClaw fixture did not announce readiness: $line');
  }
  return _GatewayFixture(
    process: process,
    endpoint: line.substring(prefix.length),
  );
}

File _fixturePath() => File(
  '${Directory.current.path}/../../crates/zommi-core-host/tests/'
  'fake_gateway_runtime.py',
).absolute;

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

Future<List<Map<String, Object?>>> _readRequests(File file) async =>
    (await file.readAsLines())
        .map(jsonDecode)
        .whereType<Map<String, Object?>>()
        .toList(growable: false);

Future<String> _findPython() async {
  for (final candidate in <String>['python3', 'python']) {
    try {
      final result = await Process.run(candidate, const ['--version']);
      if (result.exitCode == 0) return candidate;
    } on ProcessException {
      // Try the next common executable name.
    }
  }
  throw StateError('Python is required for deterministic Gateway fixtures.');
}
