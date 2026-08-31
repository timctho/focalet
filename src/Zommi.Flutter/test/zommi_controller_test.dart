import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/state/zommi_models.dart';

import 'test_support.dart';

void main() {
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
    await Future<void>.delayed(Duration.zero);

    expect(observations.first.$1, 1);
    expect(observations.first.$2, isNot(contains('showPanel')));
    expect(
      desktop.calls,
      containsAllInOrder(['surface:true:false', 'showPanel']),
    );
    expect(controller.attachments.single.token, '[example.com]');
    await controller.close();
  });

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
}

CoreEvent _event(
  int sequence,
  String name, {
  required Map<String, Object?> payload,
}) => CoreEvent(
  name: name,
  sequence: sequence,
  runtimeTargetId: 'runtime-codex',
  sessionId: 'session-1',
  turnId: 'session-1-live-turn',
  clientOperationId: 'flutter:test',
  payload: payload,
);
