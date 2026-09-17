import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';

void main() {
  for (final mode in ['pi', 'hermes', 'openclaw']) {
    for (final scenario in [
      'first',
      'middle',
      'last',
      'live',
      'repeated',
      'failure',
    ]) {
      test('$mode edit/resend $scenario keeps the exact native context', () async {
        final directory = await Directory.systemTemp.createTemp(
          'zommi-$mode-rewind-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final fixture = File(
          '../../crates/zommi-core-host/tests/fake_rewind_runtime.py',
        ).absolute.path;
        final environment = <String, String>{
          'ZOMMI_CORE_STATE_PATH': '${directory.path}/binding.json',
          'ZOMMI_RUNTIME_OVERRIDES_PATH': '${directory.path}/overrides.json',
          'ZOMMI_RUNTIME_DISCOVERY_CACHE_PATH':
              '${directory.path}/discovery.json',
          'ZOMMI_FAKE_REWIND_STORE': '${directory.path}/history.json',
          'ZOMMI_FAKE_REQUEST_LOG': '${directory.path}/requests.jsonl',
          if (scenario == 'failure') 'ZOMMI_FAKE_REWIND_FAIL': '1',
        };
        final python = Platform.isWindows ? 'python' : 'python3';
        Process? server;
        if (mode == 'openclaw') {
          server = await Process.start(python, [
            fixture,
            '--mode',
            mode,
          ], environment: environment);
          server.stderr.transform(utf8.decoder).listen(stderr.write);
          addTearDown(() async {
            server!.kill();
            await server.exitCode;
          });
          final ready = await server.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first
              .timeout(const Duration(seconds: 10));
          environment.addAll({
            'ZOMMI_OPENCLAW_GATEWAY_URL': ready.substring(
              'OPENCLAW_GATEWAY_READY '.length,
            ),
            'ZOMMI_OPENCLAW_GATEWAY_AGENT_ID': 'main',
            'OPENCLAW_GATEWAY_TOKEN': 'fixture-token',
            'ZOMMI_OPENCLAW_DEVICE_IDENTITY_PATH':
                '${directory.path}/device.json',
          });
        } else {
          environment.addAll({
            'ZOMMI_${mode.toUpperCase()}_COMMAND': python,
            'ZOMMI_${mode == 'pi' ? 'PI' : 'HERMES_GATEWAY'}_ARGS_JSON':
                jsonEncode([fixture, '--mode', mode]),
          });
        }
        final bridge = ProcessCoreBridge(
          executablePath: File(
            '../../target/debug/zommi-core-host${Platform.isWindows ? '.exe' : ''}',
          ).absolute.path,
          environment: environment,
        );
        await bridge.initialize();
        final discovery = await bridge.discoverRuntimeTargets();
        final adapter = mode == 'pi' ? 'pi-rpc' : '$mode-gateway';
        final target = discovery.targets.firstWhere(
          (target) =>
              target.adapterId == adapter &&
              (mode == 'openclaw' || target.executionHost['kind'] == 'native'),
        );
        final connection = await bridge.connectRuntime(
          runtimeTargetId: target.id,
          cwd: directory.path,
        );
        final controller = ZommiController(
          core: bridge,
          desktop: const NoopDesktopBridge(),
          catalogStartupDelay: const Duration(days: 1),
        );
        var controllerClosed = false;
        addTearDown(() async {
          if (!controllerClosed) await controller.close();
        });
        await controller.initialize();
        await controller.selectRuntime(target.id);
        expect(controller.messageEditingSupported, isTrue);
        expect(controller.turns.map((turn) => turn.userText), [
          'Question 0',
          'Question 1',
          'Question 2',
        ]);
        final source = controller.activeSessionId!;
        if (scenario == 'live') {
          await controller.submit('hold-for-interrupt');
          await controller.submit('Discard queue');
        }
        final index = scenario == 'first'
            ? 0
            : scenario == 'last'
            ? 2
            : 1;
        final original = controller.turns[index];
        controller.updateComposerValue(
          const TextEditingValue(text: 'Unrelated draft'),
        );
        final snapshot = await bridge
            .prepareSessionRewind(runtimeTargetId: target.id, sessionId: source)
            .catchError((Object error) {
              if (scenario == 'live') return <String, Object?>{};
              throw error;
            });
        if (scenario != 'live') {
          final native = (snapshot['thread'] as Map)['turns'] as List;
          await expectLater(
            bridge.rewindSession(
              runtimeTargetId: target.id,
              sessionId: source,
              turnId: (native[index] as Map)['id'] as String,
              expectedLastTurnId: 'stale-tail',
            ),
            throwsA(isA<CoreProtocolException>()),
          );
        }
        final replacement = scenario == 'repeated'
            ? original.userText
            : 'Replacement';
        expect(
          await controller.resendMessage(original, replacement),
          scenario != 'failure',
          reason: controller.status,
        );
        expect(controller.composerValue.text, 'Unrelated draft');
        if (scenario == 'failure') {
          expect(controller.turns.map((turn) => turn.userText), [
            'Question 0',
            'Question 1',
            'Question 2',
          ]);
          return;
        }
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (controller.turnActive && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(controller.turnActive, isFalse, reason: controller.status);
        final expected = [
          for (var i = 0; i < index; i++) 'Question $i',
          replacement,
        ];
        expect(controller.turns.map((turn) => turn.userText), expected);
        final selected = controller.activeSessionId!;
        expect(selected == source, mode != 'pi');
        final requests = (await File(
          environment['ZOMMI_FAKE_REQUEST_LOG']!,
        ).readAsLines()).map(jsonDecode).whereType<Map>().toList();
        final sent = requests
            .where((request) => request['replacement'] == replacement)
            .single;
        expect(sent['modelContext'], expected.take(index).toList());
        expect(
          requests.where(
            (request) => request['replacement'] == 'Discard queue',
          ),
          isEmpty,
        );
        await controller.switchSession(selected, runtimeTargetId: target.id);
        final reopened = await bridge.prepareSessionRewind(
          runtimeTargetId: target.id,
          sessionId: selected,
        );
        expect(
          ((reopened['thread'] as Map)['turns'] as List),
          hasLength(index + 1),
        );
        expect(controller.turns.map((turn) => turn.userText), expected);
        // A second edit addresses the newly persisted replacement, whose native
        // entry ID differs from the live receipt/run ID on these runtimes.
        expect(
          await controller.resendMessage(
            controller.turns.last,
            'Second replacement',
          ),
          isTrue,
          reason: controller.status,
        );
        final binding = jsonDecode(
          await File(environment['ZOMMI_CORE_STATE_PATH']!).readAsString(),
        ) as Map;
        expect(binding['sessionId'], controller.activeSessionId);
        expect(connection.runtimeTargetId, target.id);
        final finalSession = controller.activeSessionId!;
        await controller.close();
        controllerClosed = true;
        final reopenedBridge = ProcessCoreBridge(
          executablePath: File(
            '../../target/debug/zommi-core-host${Platform.isWindows ? '.exe' : ''}',
          ).absolute.path,
          environment: environment,
        );
        addTearDown(reopenedBridge.close);
        await reopenedBridge.initialize();
        await reopenedBridge.discoverRuntimeTargets();
        final rebound = await reopenedBridge.connectRuntime(
          runtimeTargetId: target.id,
        );
        expect(rebound.sessionId, finalSession);
        final restarted = await reopenedBridge.prepareSessionRewind(
          runtimeTargetId: target.id,
          sessionId: finalSession,
        );
        expect(
          ((restarted['thread'] as Map)['turns'] as List),
          hasLength(index + 1),
        );
      }, timeout: const Timeout(Duration(seconds: 75)));
    }
  }
}
