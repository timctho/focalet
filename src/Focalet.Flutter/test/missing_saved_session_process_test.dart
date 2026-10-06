import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focalet_flutter/core/core_bridge.dart';
import 'package:focalet_flutter/desktop/desktop_bridge.dart';
import 'package:focalet_flutter/state/focalet_controller.dart';

void main() {
  for (final scenario in [
    'remembered missing',
    'explicit missing',
    'resume failure',
  ]) {
    test(
      'Codex connection handles a $scenario session without losing identity',
      () async {
        final temporary = await Directory.systemTemp.createTemp(
          'focalet-missing-session-',
        );
        addTearDown(() => temporary.delete(recursive: true));
        final binding = File('${temporary.path}/binding.json');
        final log = File('${temporary.path}/requests.jsonl');
        final host = Platform.isWindows
            ? 'focalet-core-host.exe'
            : 'focalet-core-host';
        final bridge = ProcessCoreBridge(
          executablePath: File('../../target/debug/$host').absolute.path,
          environment: {
            'FOCALET_CODEX_COMMAND': Platform.isWindows ? 'python' : 'python3',
            'FOCALET_CODEX_ARGS_JSON': jsonEncode([
              File(
                '../../crates/focalet-core-host/tests/fake_codex_app_server.py',
              ).absolute.path,
            ]),
            'FOCALET_CORE_STATE_PATH': binding.path,
            'FOCALET_RUNTIME_OVERRIDES_PATH':
                '${temporary.path}/overrides.json',
            'FOCALET_RUNTIME_DISCOVERY_CACHE_PATH':
                '${temporary.path}/targets.json',
            'FOCALET_FAKE_REQUEST_LOG': log.path,
            'FOCALET_FAKE_UNIQUE_THREADS': '1',
            if (scenario == 'resume failure')
              'FOCALET_FAKE_RESUME_ERROR': 'Authentication required'
            else
              'FOCALET_FAKE_MISSING_THREAD': 'deleted-chat',
          },
        );
        addTearDown(bridge.close);
        await bridge.initialize();
        final discovery = await bridge.discoverRuntimeTargets();
        final target = discovery.targets.singleWhere(
          (target) =>
              target.runtimeId == 'codex' &&
              target.executionHost['kind'] == 'native',
        );
        final saved = {
          'runtimeTargetId': target.id,
          'sessionId': 'deleted-chat',
          'cwd': temporary.path,
        };
        await binding.writeAsString(jsonEncode(saved));
        if (scenario == 'remembered missing') {
          final controller = FocaletController(
            core: bridge,
            desktop: const NoopDesktopBridge(),
          );
          addTearDown(controller.close);
          await controller.initialize();
          expect(controller.starting, isFalse);
          expect(controller.statusWarning, isFalse);
          expect(controller.activeSessionId, isNotNull);
          expect(controller.activeSessionId, isNot('deleted-chat'));
          final first = controller.activeSessionId;
          await controller.createSession(runtimeTargetId: target.id);
          expect(controller.status, 'New chat ready');
          expect(controller.activeSessionId, isNot(first));
          expect(
            jsonDecode(await binding.readAsString())['sessionId'],
            controller.activeSessionId,
          );
        } else {
          await expectLater(
            bridge.connectRuntime(
              runtimeTargetId: target.id,
              preferredSessionId: scenario == 'explicit missing'
                  ? 'deleted-chat'
                  : null,
            ),
            throwsA(
              isA<CoreProtocolException>().having(
                (error) => error.code,
                'code',
                scenario == 'resume failure'
                    ? 'runtime-request-failed'
                    : 'session-not-found',
              ),
            ),
          );
          expect(jsonDecode(await binding.readAsString()), saved);
        }
        final requests = (await log.readAsLines()).map(jsonDecode).cast<Map>();
        expect(
          requests
              .where((r) => r['method'] == 'thread/resume')
              .first['params']['threadId'],
          'deleted-chat',
        );
        expect(
          requests.where((r) => r['method'] == 'thread/start').length,
          scenario == 'remembered missing' ? 2 : 0,
        );
        expect(requests.where((r) => r['method'] == 'turn/start'), isEmpty);
      },
    );
  }
}
