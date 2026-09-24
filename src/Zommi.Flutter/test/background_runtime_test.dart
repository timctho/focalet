import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';

import 'test_support.dart';

class BackgroundCore extends RichFakeCore implements RuntimePreparationBridge {
  final prepares = <String>[];
  final gates = <String, Completer<void>>{};
  final entered = <String, Completer<void>>{};
  final prepareGate = Completer<void>();

  @override
  Future<void> prepareRuntime({required String runtimeTargetId}) async {
    prepares.add(runtimeTargetId);
    await prepareGate.future;
  }

  @override
  Future<RuntimeConnection> connectRuntime({
    required String runtimeTargetId,
    String? preferredSessionId,
    String? cwd,
  }) async {
    entered[runtimeTargetId]?.complete();
    if (gates[runtimeTargetId] case final gate?) await gate.future;
    return super.connectRuntime(
      runtimeTargetId: runtimeTargetId,
      preferredSessionId: preferredSessionId,
      cwd: cwd,
    );
  }
}

void main() {
  test('a slow default runtime leaves selection and drafts usable; late success stays background', () async {
    final core = BackgroundCore()..historyCount = 1;
    final gate = core.gates['runtime-codex'] = Completer<void>();
    final entered = core.entered['runtime-codex'] = Completer<void>();
    core.discoveredTargets.add(
      const RuntimeTarget(
        id: 'runtime-hermes',
        runtimeId: 'hermes',
        adapterId: 'hermes-gateway',
        displayName: 'Hermes',
        protocolName: 'Gateway',
        executablePath: '/hermes',
        executionHost: {},
        capabilityHints: RichFakeCore.capabilities,
      ),
    );
    final controller = ZommiController(
      core: core,
      desktop: FakeDesktopBridge(),
      catalogStartupDelay: const Duration(days: 1),
    );
    addTearDown(controller.close);
    final initializing = controller.initialize();
    await entered.future;
    expect(controller.starting, isFalse);
    expect(controller.runtimeBusy, isFalse);
    expect(core.prepares, ['runtime-claude', 'runtime-hermes']);
    controller.updateComposerValue(
      const TextEditingValue(text: 'Draft during startup'),
    );
    await controller
        .switchSession('pi-chat', runtimeTargetId: 'runtime-pi')
        .timeout(const Duration(seconds: 1));
    expect(controller.activeSessionId, 'pi-chat');
    controller.updateComposerValue(const TextEditingValue(text: 'Pi draft'));
    gate.complete();
    core.prepareGate.complete();
    await initializing;
    expect(controller.activeRuntime?.id, 'runtime-pi');
    expect(controller.activeSessionId, 'pi-chat');
    expect(controller.composerValue.text, 'Pi draft');
    expect(controller.sessionBusy, isFalse);
    expect(core.createdSessions, isEmpty);
    expect(core.lastMessage, isNull);
  });

  test('selecting a ready runtime overtakes a slow cold switch', () async {
    final core = BackgroundCore()..historyCount = 1;
    final controller = ZommiController(
      core: core,
      desktop: FakeDesktopBridge(),
      catalogStartupDelay: const Duration(days: 1),
    );
    addTearDown(controller.close);
    await controller.initialize();
    controller.updateComposerValue(const TextEditingValue(text: 'Codex draft'));
    final gate = core.gates['runtime-pi'] = Completer<void>();
    final entered = core.entered['runtime-pi'] = Completer<void>();
    final slow = controller.switchSession(
      'pi-chat',
      runtimeTargetId: 'runtime-pi',
    );
    await entered.future;
    await controller
        .switchSession('session-2', runtimeTargetId: 'runtime-codex')
        .timeout(const Duration(seconds: 1));
    expect(controller.activeSessionId, 'session-2');
    expect(controller.sessionBusy, isFalse);
    gate.complete();
    await slow;
    expect(controller.activeRuntime?.id, 'runtime-codex');
    expect(controller.activeSessionId, 'session-2');
    await controller.switchSession('session-1');
    expect(controller.composerValue.text, 'Codex draft');
    core.prepareGate.complete();
  });

  test('setup only detects runtimes until the user chooses one', () async {
    final core = BackgroundCore();
    final controller = ZommiController(
      core: core,
      desktop: FakeDesktopBridge(),
      runtimeSetupPending: true,
    );
    addTearDown(controller.close);
    await controller.initialize();
    expect(controller.starting, isFalse);
    expect(controller.activeSessionId, isNull);
    expect(core.connectCount, 0);
    expect(core.prepares, isEmpty);
    expect(core.createdSessions, isEmpty);
    core.prepareGate.complete();
  });
}
