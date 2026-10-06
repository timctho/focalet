import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focalet_flutter/core/core_bridge.dart';

void main() {
  for (final adapter in [
    'hermes-gateway',
    'openclaw-gateway',
    'hermes-acp',
    'opencode-acp',
    'gemini-acp',
    'pi-rpc',
  ]) {
    test('$adapter returns exact inline history without relisting known sessions', () async {
      final temporary = await Directory.systemTemp.createTemp(
        'focalet-switch-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final fixtureRoot = Directory(
        '${Directory.current.path}/../../crates/focalet-core-host/tests',
      ).absolute.path;
      final python = Platform.isWindows ? 'python' : 'python3';
      final gateway = adapter.endsWith('gateway');
      final runtime = adapter.startsWith('hermes')
          ? 'HERMES'
          : adapter.startsWith('openclaw')
          ? 'OPENCLAW'
          : adapter.startsWith('opencode')
          ? 'OPENCODE'
          : adapter.startsWith('gemini')
          ? 'GEMINI'
          : 'PI';
      final fixture = gateway
          ? 'fake_gateway_runtime.py'
          : adapter == 'pi-rpc'
          ? 'fake_pi_rpc.py'
          : 'fake_acp_runtime.py';
      final log = File('${temporary.path}/requests.jsonl');
      String? endpoint;
      if (adapter == 'openclaw-gateway') {
        final server = await Process.start(
          python,
          ['$fixtureRoot/$fixture', '--mode', 'openclaw'],
          environment: {'FOCALET_FAKE_REQUEST_LOG': log.path},
        );
        addTearDown(() async {
          server.kill();
          await server.exitCode;
        });
        final line = await server.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 10));
        endpoint = line.substring('OPENCLAW_GATEWAY_READY '.length);
      }
      final bridge = ProcessCoreBridge(
        executablePath: File(
          '${Directory.current.path}/../../target/debug/focalet-core-host${Platform.isWindows ? '.exe' : ''}',
        ).absolute.path,
        environment: {
          'FOCALET_${runtime}_COMMAND': python,
          'FOCALET_${gateway ? '${runtime}_GATEWAY' : runtime}_ARGS_JSON':
              jsonEncode([
                '$fixtureRoot/$fixture',
                if (gateway) ...['--mode', runtime.toLowerCase()],
              ]),
          'FOCALET_OPENCLAW_GATEWAY_URL': ?endpoint,
          'OPENCLAW_GATEWAY_TOKEN': 'fixture-runtime-owned-token',
          'FOCALET_OPENCLAW_DEVICE_IDENTITY_PATH':
              '${temporary.path}/device.json',
          'FOCALET_CORE_STATE_PATH': '${temporary.path}/binding.json',
          'FOCALET_RUNTIME_OVERRIDES_PATH': '${temporary.path}/overrides.json',
          'FOCALET_RUNTIME_DISCOVERY_CACHE_PATH':
              '${temporary.path}/discovery.json',
          'FOCALET_FAKE_REQUEST_LOG': log.path,
          if (adapter == 'gemini-acp') 'FOCALET_FAKE_ACP_GEMINI': '1',
        },
      );
      addTearDown(bridge.close);
      await bridge.initialize();
      final discovery = await bridge.discoverRuntimeTargets();
      final target = discovery.targets.firstWhere(
        (target) => target.adapterId == adapter,
      );
      await bridge.prepareRuntime(runtimeTargetId: target.id);
      expect(await File('${temporary.path}/binding.json').exists(), isFalse);
      final initial = await bridge.connectRuntime(
        runtimeTargetId: target.id,
        cwd: temporary.path,
      );
      final selected = adapter == 'pi-rpc'
          ? await bridge.openSession(
              runtimeTargetId: target.id,
              sessionId: initial.sessionId,
            )
          : initial;
      final session = adapter == 'hermes-gateway'
          ? 'hermes-coder-session'
          : selected.sessionId;
      final before = (await log.readAsLines()).length;
      for (var i = 0; i < 3; i++) {
        final connection = await bridge.openSession(
          runtimeTargetId: target.id,
          sessionId: session,
        );
        expect(connection.sessionId, session);
        expect(connection.history?['thread'], isA<Map>());
        expect((connection.history!['thread'] as Map)['id'], session);
        expect((connection.history!['thread'] as Map)['turns'], isA<List>());
        if (adapter == 'hermes-gateway') {
          expect(connection.sessionMetadata['profile'], 'coder');
        }
      }
      final requests = (await log.readAsLines())
          .skip(before)
          .map(jsonDecode)
          .cast<Map>();
      final methods = requests
          .map((request) => request['method'] ?? request['type'])
          .toList();
      expect(
        methods.where(
          (method) => [
            'http.sessions',
            'session.list',
            'sessions.list',
            'session/list',
          ].contains(method),
        ),
        isEmpty,
      );
      if (adapter == 'hermes-gateway') {
        expect(
          methods.where((method) => method == 'model.options'),
          hasLength(1),
        );
        expect(
          methods.where((method) => method == 'session.resume'),
          hasLength(3),
        );
      }
      if (adapter == 'pi-rpc') {
        expect(
          methods.where((method) => method == 'get_messages'),
          hasLength(3),
        );
      }
      if (gateway) {
        final marker = (await log.readAsLines()).length;
        await expectLater(
          bridge.openSession(
            runtimeTargetId: target.id,
            sessionId: 'unknown-exact-session',
          ),
          throwsA(
            isA<CoreProtocolException>().having(
              (error) => error.code,
              'code',
              'identity-mismatch',
            ),
          ),
        );
        final refreshed = (await log.readAsLines()).skip(marker).join('\n');
        expect(
          refreshed,
          contains(
            adapter == 'hermes-gateway' ? 'http.sessions' : 'sessions.list',
          ),
        );
        expect(refreshed, isNot(contains('session.create')));
      }
    });
  }
}
