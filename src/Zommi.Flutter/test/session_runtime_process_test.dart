import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';

void main() {
  test('mixed Codex and Hermes chats route through the Rust host', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'zommi-mixed-chats-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final python = await _findPython();
    final requestLog = File('${temporary.path}/requests.jsonl');
    final bridge = ProcessCoreBridge(
      executablePath: File(
        '../../target/debug/zommi-core-host${Platform.isWindows ? '.exe' : ''}',
      ).absolute.path,
      environment: {
        'ZOMMI_CODEX_COMMAND': python,
        'ZOMMI_CODEX_ARGS_JSON': jsonEncode([
          File('../../crates/zommi-core-host/tests/fake_codex_app_server.py')
              .absolute
              .path,
        ]),
        'ZOMMI_HERMES_COMMAND': python,
        'ZOMMI_HERMES_GATEWAY_ARGS_JSON': jsonEncode([
          File('../../crates/zommi-core-host/tests/fake_gateway_runtime.py')
              .absolute
              .path,
          '--mode',
          'hermes',
        ]),
        'ZOMMI_CORE_STATE_PATH': '${temporary.path}/binding.json',
        'ZOMMI_RUNTIME_OVERRIDES_PATH': '${temporary.path}/overrides.json',
        'ZOMMI_FAKE_REQUEST_LOG': requestLog.path,
        'ZOMMI_FAKE_FRESH_THREAD_ID': 'created-codex-chat',
      },
    );
    final controller = ZommiController(
      core: bridge,
      desktop: const NoopDesktopBridge(),
    );
    addTearDown(controller.close);
    await controller.initialize();
    final codex = controller.runtimeTargets.firstWhere(
      (r) => r.adapterId == 'codex-app-server',
    );
    final hermes = controller.runtimeTargets.firstWhere(
      (r) => r.adapterId == 'hermes-gateway',
    );
    await controller.selectRuntime(codex.id);
    await controller.createSession(runtimeTargetId: codex.id);
    final codexSession = controller.activeSessionId!;
    expect(codexSession, 'created-codex-chat');
    await controller.createSession(runtimeTargetId: hermes.id);
    expect(controller.activeRuntime?.id, hermes.id, reason: controller.status);
    final hermesSession = controller.activeSessionId!;
    expect(
      controller.sessions.any(
        (s) => s.runtimeTargetId == codex.id && s.id == codexSession,
      ),
      isTrue,
    );
    expect(
      controller.sessions.any(
        (s) => s.runtimeTargetId == hermes.id && s.id == hermesSession,
      ),
      isTrue,
    );

    var completed = bridge.events.firstWhere(
      (e) => e.name == 'turn.completed' && e.runtimeTargetId == hermes.id,
    );
    await controller.submit('Message for Hermes');
    await completed.timeout(const Duration(seconds: 15));
    await controller.switchSession(codexSession, runtimeTargetId: codex.id);
    expect(controller.activeRuntime?.id, codex.id, reason: controller.status);
    completed = bridge.events.firstWhere(
      (e) => e.name == 'turn.completed' && e.runtimeTargetId == codex.id,
    );
    await controller.submit('Message for Codex');
    await completed.timeout(const Duration(seconds: 15));
    await controller.switchSession(hermesSession, runtimeTargetId: hermes.id);
    expect(controller.activeRuntime?.id, hermes.id, reason: controller.status);
    expect(controller.activeSessionId, hermesSession);

    final requests = (await requestLog.readAsLines()).map(
      (line) => jsonDecode(line) as Map,
    );
    final codexPrompt =
        requests.singleWhere((r) => r['method'] == 'turn/start')['params']
            as Map;
    expect(codexPrompt['threadId'], codexSession);
    expect(jsonEncode(codexPrompt), contains('Message for Codex'));
    final hermesPrompt =
        requests.singleWhere((r) => r['method'] == 'prompt.submit')['params']
            as Map;
    expect(jsonEncode(hermesPrompt), contains('Message for Hermes'));
  });
}

Future<String> _findPython() async {
  for (final candidate in ['python3', 'python']) {
    try {
      if ((await Process.run(candidate, ['--version'])).exitCode == 0) {
        return candidate;
      }
    } on ProcessException {
      // Try the other common Python executable.
    }
  }
  throw StateError('Python is required for runtime fixtures.');
}
