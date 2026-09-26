import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';

import 'test_support.dart';

RuntimeTarget agent(String id, String name, {String? adapter}) => RuntimeTarget(
  id: 'runtime-$id',
  runtimeId: id,
  adapterId: adapter ?? '$id-acp',
  displayName: name,
  protocolName: 'ACP',
  executablePath: '/usr/bin/$id',
  executionHost: const {
    'id': 'native:linux',
    'kind': 'native',
    'displayName': 'Linux',
  },
  capabilityHints: RichFakeCore.capabilities,
);

void main() {
  test('discovery and refresh keep pinned families first and other agents alphabetical', () async {
    final shuffled = [
      agent('pi', 'Pi'),
      agent('openclaw', 'OpenClaw'),
      agent('claude', 'Claude Code'),
      agent('hermes', 'Hermes'),
      agent('codex', 'Codex'),
      agent('aardvark', 'aardvark'),
      agent('opencode', 'OpenCode'),
      agent('gemini', 'Gemini CLI'),
    ];
    final core = RichFakeCore()
      ..discoveredTargets.clear()
      ..discoveredTargets.addAll(shuffled);
    final controller = ZommiController(
      core: core,
      desktop: FakeDesktopBridge(),
      runtimeSetupPending: true,
    );
    addTearDown(controller.close);
    await controller.initialize();
    const order = [
      'codex',
      'claude',
      'opencode',
      'aardvark',
      'gemini',
      'hermes',
      'openclaw',
      'pi',
    ];
    expect(
      controller.visibleRuntimeTargets.map((target) => target.runtimeId),
      order,
    );
    core.discoveredTargets
      ..clear()
      ..addAll(shuffled.reversed);
    await controller.refreshRuntimes();
    expect(
      controller.visibleRuntimeTargets.map((target) => target.runtimeId),
      order,
    );
    controller.runtimeSettings = {
      'adapters': [
        for (final target in shuffled)
          {
            'adapterId': target.adapterId,
            'displayName': target.displayName,
            'acceptsEndpoint': false,
          },
      ],
    };
    expect(
      controller.configurableRuntimeAdapters.map(
        (adapter) => adapter['adapterId'],
      ),
      order.map((id) => '$id-acp'),
    );
  });

  test('runtime setup failures retain the selected chat and offer a targeted recovery', () async {
    final openclaw = agent('openclaw', 'OpenClaw');
    final core = RichFakeCore()
      ..historyCount = 0
      ..discoveredTargets.add(openclaw);
    final desktop = FakeDesktopBridge();
    final controller = ZommiController(core: core, desktop: desktop);
    addTearDown(controller.close);
    await controller.initialize();
    final original = (controller.activeRuntime?.id, controller.activeSessionId);
    controller.composerValue = const TextEditingValue(text: 'keep my draft');
    core.connectErrorCode = 'gateway-unavailable';
    core.connectErrorMessage = 'Check the OpenClaw Gateway in this runtime.';
    expect(await controller.connectRuntimeForSetup(openclaw.id), isFalse);
    expect(controller.runtimeBusy, isFalse);
    expect(controller.runtimeRecoveryLabel, 'Open OpenClaw setup');
    expect((
      controller.activeRuntime?.id,
      controller.activeSessionId,
    ), original);
    expect(controller.composerValue.text, 'keep my draft');
    await controller.openRuntimeRecovery();
    expect(desktop.calls, contains('signIn:${openclaw.id}'));
    core.connectErrorCode = null;
    await controller.retryConnection();
    expect(controller.activeRuntime?.id, openclaw.id);
    expect(controller.runtimeRecoveryLabel, isNull);
  });
}
