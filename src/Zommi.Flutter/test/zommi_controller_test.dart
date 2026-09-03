import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/state/zommi_models.dart';

import 'test_support.dart';

void main() {
  test(
    'runtime capability failures are not mislabeled as core failures',
    () async {
      final core = RichFakeCore()
        ..historyCount = 0
        ..connectErrorCode = 'capability-unavailable'
        ..connectErrorMessage =
            'Native Windows terminal compatibility requires a ConPTY backend.';
      final controller = ZommiController(
        core: core,
        desktop: FakeDesktopBridge(),
      );

      await controller.initialize();

      expect(controller.status, startsWith('Agent runtime unavailable ·'));
      expect(controller.status, isNot(contains('Rust core unavailable')));
      await controller.close();
    },
  );

  test('manual runtime refresh bypasses the WSL discovery backoff', () async {
    final core = RichFakeCore()..historyCount = 0;
    final controller = ZommiController(
      core: core,
      desktop: FakeDesktopBridge(),
    );
    await controller.initialize();
    expect(core.lastDiscoveryForce, isFalse);

    await controller.refreshRuntimes();

    expect(core.lastDiscoveryForce, isTrue);
    await controller.close();
  });

  test('portal authorization does not block Rust runtime discovery', () async {
    final core = RichFakeCore()..historyCount = 0;
    final desktopReady = Completer<DesktopReadiness>();
    final desktop = FakeDesktopBridge()..initializeGate = desktopReady.future;
    final controller = ZommiController(core: core, desktop: desktop);

    final initialization = controller.initialize();
    for (
      var attempt = 0;
      attempt < 10 && controller.activeRuntime == null;
      attempt++
    ) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(controller.activeRuntime?.id, core.activeTargetId);
    expect(controller.contextShortcutRegistered, isFalse);

    desktopReady.complete(
      const DesktopReadiness(contextShortcut: true, imageShortcut: true),
    );
    await initialization;
    expect(controller.contextShortcutRegistered, isTrue);
    expect(controller.imageShortcutRegistered, isTrue);
    await controller.close();
  });

  test(
    'three hundred stream deltas stay in one identity-bearing block',
    () async {
      final core = RichFakeCore()..historyCount = 0;
      final desktop = FakeDesktopBridge();
      final controller = ZommiController(core: core, desktop: desktop);
      await controller.initialize();
      await controller.submit('stress stream');

      core.emit(
        _event(1, 'turn.started', payload: const {'status': 'inProgress'}),
      );
      for (var index = 1; index <= 300; index++) {
        core.emit(
          _event(
            index + 1,
            'item.update',
            payload: {
              'kind': 'assistant',
              'lifecycle': 'delta',
              'title': 'Codex',
              'text': 'line $index\n',
              'itemId': 'answer-1',
            },
          ),
        );
      }

      expect(controller.turns, hasLength(1));
      expect(controller.turns.single.blocks, hasLength(1));
      final answer = controller.turns.single.blocks.single;
      expect(answer.text, startsWith('line 1\n'));
      expect(answer.text, endsWith('line 300\n'));
      expect(
        RegExp(r'^line ', multiLine: true).allMatches(answer.text),
        hasLength(300),
      );

      core.emit(
        _event(
          301,
          'item.update',
          payload: const {
            'kind': 'assistant',
            'lifecycle': 'delta',
            'title': 'Codex',
            'text': 'late duplicate',
            'itemId': 'answer-1',
          },
        ),
      );
      expect(answer.text, isNot(contains('late duplicate')));
      await controller.close();
    },
  );

  test(
    'authoritative cumulative stream frames replace instead of duplicate',
    () async {
      final core = RichFakeCore()..historyCount = 0;
      final controller = ZommiController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      await controller.initialize();
      await controller.submit('stream once');

      core.emit(
        _event(
          1,
          'item.update',
          payload: const {
            'kind': 'assistant',
            'lifecycle': 'delta',
            'text': 'Hello',
            'itemId': 'answer',
          },
        ),
      );
      core.emit(
        _event(
          2,
          'item.update',
          payload: const {
            'kind': 'assistant',
            'lifecycle': 'completed',
            'text': 'Hello from Codex',
            'replace': true,
            'itemId': 'answer',
          },
        ),
      );

      final answer = controller.turns.single.blocks.single.text;
      expect(answer, 'Hello from Codex');
      expect(RegExp('Hello').allMatches(answer), hasLength(1));
      await controller.close();
    },
  );

  test('implicit cumulative stream frames do not duplicate text', () async {
    final core = RichFakeCore()..historyCount = 0;
    final controller = ZommiController(
      core: core,
      desktop: FakeDesktopBridge(),
    );
    await controller.initialize();
    await controller.submit('stream once');

    core.emit(
      _event(
        1,
        'item.update',
        payload: const {
          'kind': 'assistant',
          'lifecycle': 'delta',
          'text': 'Hello',
          'itemId': 'answer',
        },
      ),
    );
    core.emit(
      _event(
        2,
        'item.update',
        payload: const {
          'kind': 'assistant',
          'lifecycle': 'delta',
          'text': 'Hello from Codex',
          'itemId': 'answer',
        },
      ),
    );

    final answer = controller.turns.single.blocks.single.text;
    expect(answer, 'Hello from Codex');
    expect(RegExp('Hello').allMatches(answer), hasLength(1));
    await controller.close();
  });

  test('desktop invocation attaches context before requesting focus', () async {
    final core = RichFakeCore()..historyCount = 0;
    final desktop = FakeDesktopBridge();
    final controller = ZommiController(core: core, desktop: desktop);
    await controller.initialize();
    desktop.calls.clear();
    final observations = <(int, String)>[];
    controller.addListener(() {
      observations.add((
        controller.attachments.length,
        desktop.calls.join(','),
      ));
    });

    desktop.emit(
      DesktopInvocation(
        kind: DesktopInvocationKind.context,
        attachment: ContextAttachment(
          id: 'context-1',
          token: '',
          snapshot: const {
            'application': 'Edge',
            'locator': {'kind': 'URL', 'value': 'https://example.com'},
          },
          previewText: 'Context',
        ),
      ),
    );
    await Future<void>.delayed(
      surfaceTransitionDuration + const Duration(milliseconds: 20),
    );

    expect(observations.first.$1, 1);
    expect(observations.first.$2, isNot(contains('showPanel')));
    expect(desktop.calls, contains('showPanel'));
    expect(
      desktop.calls.where((call) => call == 'surface:false:false'),
      isEmpty,
    );
    expect(controller.attachments.single.token, '[example.com]');
    expect(desktop.surfaceAnimations, everyElement(isFalse));
    await controller.close();
  });

  test(
    'cancelled image shortcut still restores and focuses the composer',
    () async {
      final core = RichFakeCore()..historyCount = 0;
      final desktop = FakeDesktopBridge();
      final controller = ZommiController(core: core, desktop: desktop);
      await controller.initialize();
      desktop.calls.clear();

      desktop.emit(const DesktopInvocation(kind: DesktopInvocationKind.image));
      await Future<void>.delayed(Duration.zero);

      expect(controller.focusComposerEpoch, 1);
      expect(desktop.calls, contains('showPanel'));
      expect(
        desktop.calls.where((call) => call.startsWith('surface:')),
        isEmpty,
      );
      await controller.close();
    },
  );

  test(
    'taskbar chat stays expanded while large-window resize completes',
    () async {
      final core = RichFakeCore()..historyCount = 0;
      final desktop = FakeDesktopBridge();
      final controller = ZommiController(core: core, desktop: desktop);
      await controller.initialize();

      expect(controller.expanded, isTrue);
      await controller.setExpanded(true, focus: true);
      expect(controller.focusComposerEpoch, 1);
      expect(desktop.calls, contains('showPanel'));

      final resizeGate = Completer<void>();
      desktop.surfaceGate = resizeGate.future;
      final resize = controller.toggleLargePanel();
      await Future<void>.delayed(Duration.zero);
      expect(controller.surfaceTransitioning, isTrue);
      expect(controller.surfaceTransitionAnimating, isTrue);
      expect(controller.transitionTargetExpanded, isTrue);
      expect(controller.transitionTargetLarge, isTrue);
      expect(controller.expanded, isTrue);

      resizeGate.complete();
      await resize;
      expect(controller.surfaceTransitioning, isFalse);
      expect(controller.expanded, isTrue);
      expect(controller.largePanel, isTrue);
      await controller.close();
    },
  );

  test(
    'terminal completion suppresses late frames and exposes unknown outcome',
    () async {
      final core = RichFakeCore()..historyCount = 0;
      final controller = ZommiController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      await controller.initialize();
      await controller.submit('ambiguous turn');
      core.emit(
        _event(1, 'turn.started', payload: const {'status': 'inProgress'}),
      );
      core.emit(
        _event(
          2,
          'item.update',
          payload: const {
            'kind': 'assistant',
            'lifecycle': 'delta',
            'text': 'partial',
            'itemId': 'answer',
          },
        ),
      );
      core.emit(
        _event(3, 'turn.completed', payload: const {'status': 'unknown'}),
      );
      core.emit(
        _event(
          2,
          'item.update',
          payload: const {
            'kind': 'assistant',
            'lifecycle': 'delta',
            'text': 'late',
            'itemId': 'answer',
          },
        ),
      );

      expect(controller.turnActive, isFalse);
      expect(controller.status, contains('outcome unknown'));
      expect(controller.statusWarning, isTrue);
      expect(controller.turns.single.blocks.single.text, 'partial');
      await controller.close();
    },
  );

  test('stop waits for the runtime turn id before cancelling', () async {
    final core = RichFakeCore()..historyCount = 0;
    final startGate = Completer<void>();
    core.startTurnGate = startGate.future;
    final controller = ZommiController(
      core: core,
      desktop: FakeDesktopBridge(),
    );
    await controller.initialize();

    final submission = controller.submit('hold this turn');
    await Future<void>.delayed(Duration.zero);
    expect(controller.activeTurnId, startsWith('flutter:'));
    await controller.interrupt();
    expect(controller.activeTurnStopping, isTrue);
    expect(core.interrupted, isNull);

    startGate.complete();
    await submission;
    expect(core.interrupted, (
      'runtime-codex',
      'session-1',
      'session-1-live-turn',
    ));
    await controller.close();
  });

  test(
    'each session keeps an independent model and reasoning choice',
    () async {
      final core = RichFakeCore()..historyCount = 0;
      final controller = ZommiController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      await controller.initialize();
      controller.setModel('fixture-mini');
      controller.setEffort('medium');

      await controller.switchSession('session-2');
      expect(controller.selectedModel, 'fixture-pro');
      expect(controller.selectedEffort, 'high');
      controller.setModel('fixture-mini');
      controller.setEffort('low');

      await controller.switchSession('session-1');
      expect(controller.selectedModel, 'fixture-mini');
      expect(controller.selectedEffort, 'medium');

      await controller.selectRuntime('runtime-pi');
      controller.setModel('fixture-pro');
      controller.setEffort('low');
      await controller.selectRuntime('runtime-codex');
      expect(controller.selectedModel, 'fixture-mini');
      expect(controller.selectedEffort, 'medium');
      await controller.close();
    },
  );

  test('workspace overrides stay isolated and reach the core', () async {
    final core = RichFakeCore()..historyCount = 0;
    final controller = ZommiController(
      core: core,
      desktop: FakeDesktopBridge(),
    );
    await controller.initialize();

    await controller.setWorkspace('/work/alpha');
    expect(controller.selectedWorkspace, '/work/alpha');
    expect(core.lastCwd, '/work/alpha');

    await controller.switchSession('session-2');
    expect(controller.selectedWorkspace, isEmpty);
    await controller.setWorkspace('/work/beta');
    await controller.switchSession('session-1');
    expect(controller.selectedWorkspace, '/work/alpha');
    await controller.close();
  });

  test('Hermes model catalog survives an empty reconnect response', () async {
    const hermes = RuntimeTarget(
      id: 'runtime-hermes',
      runtimeId: 'hermes',
      adapterId: 'hermes-gateway',
      displayName: 'Hermes',
      protocolName: 'Hermes Gateway',
      executablePath: '/usr/bin/hermes',
      executionHost: {
        'id': 'native:linux',
        'kind': 'native',
        'displayName': 'Linux',
      },
      capabilityHints: RichFakeCore.capabilities,
    );
    final core = RichFakeCore()
      ..historyCount = 0
      ..activeTargetId = hermes.id
      ..discoveredTargets.add(hermes)
      ..modelCatalogByRuntime[hermes.id] = RichFakeCore.models;
    final controller = ZommiController(
      core: core,
      desktop: FakeDesktopBridge(),
    );
    await controller.initialize();
    expect(controller.activeRuntime?.id, hermes.id);
    expect(controller.models, RichFakeCore.models);
    expect(controller.modelSelectionSupported, isTrue);

    await controller.selectRuntime('runtime-pi');
    core.modelCatalogByRuntime[hermes.id] = const [];
    await controller.selectRuntime(hermes.id);
    expect(controller.activeRuntime?.id, hermes.id);
    expect(controller.models, RichFakeCore.models);
    expect(controller.modelSelectionSupported, isTrue);
    await controller.close();
  });

  test('runtime round trip consolidates canonical thinking sections', () async {
    final core = RichFakeCore()..historyCount = 0;
    final controller = ZommiController(
      core: core,
      desktop: FakeDesktopBridge(),
    );
    await controller.initialize();
    await controller.submit('inspect once');
    core.emit(
      _event(
        1,
        'item.update',
        payload: const {
          'kind': 'thinking',
          'lifecycle': 'delta',
          'text': 'Reading context',
          'itemId': 'live-thinking',
        },
      ),
    );
    core.historyBySession['runtime-codex\u0000session-1'] = {
      'thread': {
        'id': 'session-1',
        'turns': [
          {
            'id': 'canonical-turn',
            'items': [
              {
                'type': 'userMessage',
                'content': [
                  {'type': 'text', 'text': 'inspect once'},
                ],
              },
              {
                'id': 'commentary-1',
                'type': 'agentMessage',
                'phase': 'commentary',
                'text': 'Reading context',
              },
              {
                'id': 'reasoning-1',
                'type': 'reasoning',
                'summary': ['Comparing the selected page'],
              },
            ],
          },
        ],
      },
    };

    await controller.selectRuntime('runtime-pi');
    await controller.selectRuntime('runtime-codex');
    final thinking = controller.turns.last.blocks.where(
      (block) => block.kind == TranscriptKind.thinking,
    );
    expect(thinking, hasLength(1));
    expect(thinking.single.text, contains('Reading context'));
    expect(thinking.single.text, contains('Comparing the selected page'));
    await controller.close();
  });

  test(
    'running transcript survives leaving and reopening its session',
    () async {
      final core = RichFakeCore()..historyCount = 1;
      final controller = ZommiController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      await controller.initialize();
      await controller.submit('keep my live message');
      core.emit(
        _event(
          1,
          'item.update',
          payload: const {
            'kind': 'assistant',
            'lifecycle': 'delta',
            'text': 'still streaming',
            'itemId': 'answer-live',
          },
        ),
      );
      expect(controller.turns.last.blocks.single.text, 'still streaming');

      await controller.switchSession('session-2');
      core.emit(
        _event(
          2,
          'turn.completed',
          sessionId: 'session-1',
          payload: const {'status': 'completed'},
        ),
      );
      await controller.switchSession('session-1');
      expect(controller.turns, hasLength(2));
      expect(controller.turns.last.userText, 'keep my live message');
      expect(controller.turns.last.blocks.single.text, 'still streaming');
      expect(controller.turnActive, isFalse);
      await controller.close();
    },
  );

  test('background runtimes keep the global working state alive', () async {
    final core = RichFakeCore()..historyCount = 0;
    final controller = ZommiController(
      core: core,
      desktop: FakeDesktopBridge(),
    );
    await controller.initialize();
    core.emit(
      _event(
        1,
        'turn.started',
        runtimeTargetId: 'runtime-codex',
        sessionId: 'session-1',
        turnId: 'codex-background',
        payload: const {'status': 'inProgress'},
      ),
    );
    await controller.selectRuntime('runtime-pi');
    expect(controller.anyTurnActive, isTrue);
    expect(controller.turnActive, isFalse);

    core.emit(
      _event(
        2,
        'turn.completed',
        runtimeTargetId: 'runtime-codex',
        sessionId: 'session-1',
        turnId: 'codex-background',
        payload: const {'status': 'completed'},
      ),
    );
    expect(controller.anyTurnActive, isFalse);
    await controller.close();
  });

  test('runtime switching keeps the global activity signal alive', () async {
    final core = RichFakeCore()..historyCount = 0;
    final controller = ZommiController(
      core: core,
      desktop: FakeDesktopBridge(),
    );
    await controller.initialize();
    final gate = Completer<void>();
    core.connectGate = gate.future;

    final switching = controller.selectRuntime('runtime-pi');
    await Future<void>.delayed(Duration.zero);
    expect(controller.runtimeBusy, isTrue);
    expect(controller.anyTurnActive || controller.runtimeBusy, isTrue);

    gate.complete();
    await switching;
    expect(controller.runtimeBusy, isFalse);
    expect(controller.anyTurnActive || controller.runtimeBusy, isFalse);
    await controller.close();
  });

  test('undetected runtime targets are excluded from the main list', () async {
    final core = RichFakeCore()..historyCount = 0;
    core.discoveredTargets.add(
      const RuntimeTarget(
        id: 'runtime-missing',
        runtimeId: 'missing',
        adapterId: 'pi-rpc',
        displayName: 'Missing runtime',
        protocolName: 'Pi RPC',
        executablePath: '/missing/pi',
        executionHost: {'id': 'native:linux', 'kind': 'native'},
        status: 'unavailable',
      ),
    );
    final controller = ZommiController(
      core: core,
      desktop: FakeDesktopBridge(),
    );
    await controller.initialize();
    expect(
      controller.visibleRuntimeTargets.map((target) => target.id),
      isNot(contains('runtime-missing')),
    );
    await controller.close();
  });

  test('WSL file picker paths normalize to the CLI path only', () {
    expect(
      normalizeRuntimeExecutablePath(
        r'\\wsl.localhost\Ubuntu\home\example\.local\bin\codex',
        const {'kind': 'wsl', 'name': 'Ubuntu'},
      ),
      '/home/example/.local/bin/codex',
    );
    expect(
      normalizeRuntimeExecutablePath(r'C:\tools\codex.exe', const {
        'kind': 'native',
      }),
      r'C:\tools\codex.exe',
    );
    expect(
      normalizeWorkspacePath(r'C:\Users\example\source', const {
        'kind': 'wsl',
        'name': 'Ubuntu',
      }),
      '/mnt/c/Users/example/source',
    );
  });
}

CoreEvent _event(
  int sequence,
  String name, {
  String runtimeTargetId = 'runtime-codex',
  String sessionId = 'session-1',
  String turnId = 'session-1-live-turn',
  required Map<String, Object?> payload,
}) => CoreEvent(
  name: name,
  sequence: sequence,
  runtimeTargetId: runtimeTargetId,
  sessionId: sessionId,
  turnId: turnId,
  clientOperationId: 'flutter:test',
  payload: payload,
);
