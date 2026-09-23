import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';

void main() {
  test('Antigravity chats retain text while refreshing models and switching sessions', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'zommi-antigravity-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final python = Platform.isWindows ? 'python' : 'python3';
    final bridge = ProcessCoreBridge(
      executablePath: File(
        '../../target/debug/zommi-core-host${Platform.isWindows ? '.exe' : ''}',
      ).absolute.path,
      environment: {
        'ZOMMI_RUNTIME_DISCOVERY_MODE': 'configured-only',
        'ZOMMI_AGY_COMMAND': python,
        'ZOMMI_ANTIGRAVITY_ARGS_JSON': jsonEncode([
          File('../../crates/zommi-core-host/tests/fake_antigravity_runtime.py')
              .absolute
              .path,
        ]),
        'ZOMMI_FAKE_AGY_STATE': temporary.path,
        'ZOMMI_CORE_STATE_PATH': '${temporary.path}/binding.json',
        'ZOMMI_RUNTIME_OVERRIDES_PATH': '${temporary.path}/overrides.json',
        'ZOMMI_RUNTIME_DISCOVERY_CACHE_PATH': '${temporary.path}/targets.json',
      },
    );
    final controller = ZommiController(
      core: bridge,
      desktop: const NoopDesktopBridge(),
      catalogStartupDelay: const Duration(days: 1),
    );
    addTearDown(controller.close);
    await controller.initialize();
    final target = controller.runtimeTargets.singleWhere(
      (t) => t.runtimeId == 'antigravity',
    );
    await controller.selectRuntime(target.id);
    expect(controller.activeSessionId, isNotNull, reason: controller.status);
    expect(controller.capabilities, isNot(contains('input.image.v1')));
    expect(controller.models, hasLength(2));
    final original = controller.activeSessionId!;
    await controller.submit('remember ocean');
    await _idle(controller);
    expect(
      controller.turns.single.blocks.map((b) => b.text).join(),
      contains('Hello Antigravity'),
    );
    expect(
      controller.turns.single.blocks.where(
        (b) => b.text == 'Hello Antigravity',
      ),
      hasLength(1),
    );
    await File('${temporary.path}/more-models')
        .writeAsString('signed-in provider');
    await controller.refreshRuntimes();
    expect(controller.models, hasLength(3));
    expect(controller.activeSessionId, original);
    await controller.createSession();
    expect(controller.activeSessionId, isNot(original));
    await controller.switchSession(original);
    expect(controller.activeSessionId, original);
    expect(controller.turns, hasLength(1));
    await controller.submit('recall');
    await _idle(controller);
    expect(
      controller.turns.last.blocks.map((b) => b.text).join(),
      contains('remember ocean'),
    );
  });
}

Future<void> _idle(ZommiController controller) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (controller.turnActive && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(controller.turnActive, isFalse, reason: controller.status);
}
