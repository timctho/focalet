import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:focalet_flutter/core/core_bridge.dart';
import 'package:focalet_flutter/state/focalet_controller.dart';

import 'test_support.dart';

void main() {
  test(
    'a history read started before rewind cannot restore the removed suffix',
    () async {
      final core = _DelayedHistoryCore()..historyCount = 3;
      final controller = FocaletController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      final original = controller.turns[1];
      final staleHistory = await core.readSession(
        runtimeTargetId: 'runtime-codex',
        sessionId: 'session-1',
      );
      final gate = Completer<void>();
      core.nextReadGate = gate;
      core.emit(
        const CoreEvent(
          name: 'session.refreshed',
          sequence: 1,
          runtimeTargetId: 'runtime-codex',
          sessionId: 'session-1',
          payload: {
            'connection': {
              'runtimeTargetId': 'runtime-codex',
              'sessionId': 'session-1',
              'protocolVersion': 1,
            },
          },
        ),
      );
      await core.readStarted.future;
      expect(await controller.resendMessage(original, 'Replacement'), isTrue);
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(controller.turns.map((turn) => turn.userText), [
        'history user 1',
        'Replacement',
      ]);
      core.emit(
        CoreEvent(
          name: 'session.refreshed',
          sequence: 2,
          runtimeTargetId: 'runtime-codex',
          sessionId: 'session-1',
          payload: {
            'connection': {
              'runtimeTargetId': 'runtime-codex',
              'sessionId': 'session-1',
              'protocolVersion': 1,
              'history': staleHistory,
            },
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.turns.map((turn) => turn.userText), [
        'history user 1',
        'Replacement',
      ]);
    },
  );

  for (final index in [0, 1, 2]) {
    test(
      'edit at index $index keeps only the prefix and the replacement',
      () async {
        final core = RichFakeCore()..historyCount = 3;
        final controller = FocaletController(
          core: core,
          desktop: FakeDesktopBridge(),
        );
        addTearDown(controller.close);
        await controller.initialize();
        final before = controller.turns.toList();
        expect(
          await controller.resendMessage(before[index], 'Replacement'),
          isTrue,
        );
        expect(controller.turns.map((turn) => turn.userText), [
          ...before.take(index).map((turn) => turn.userText),
          'Replacement',
        ]);
        expect(
          core.rewindRequests.single['turnId'],
          before[index].runtimeTurnId,
        );
        expect(
          core.rewindRequests.single['expectedLastTurnId'],
          before.last.runtimeTurnId,
        );
        final active = controller.activeTurnId;
        core.emit(
          CoreEvent(
            name: 'item.update',
            sequence: 100,
            runtimeTargetId: 'runtime-codex',
            sessionId: 'session-1',
            turnId: before.last.runtimeTurnId,
            payload: const {
              'kind': 'assistant',
              'itemId': 'late',
              'text': 'Removed reply',
            },
          ),
        );
        core.emit(
          CoreEvent(
            name: 'turn.completed',
            sequence: 101,
            runtimeTargetId: 'runtime-codex',
            sessionId: 'session-1',
            turnId: before.last.runtimeTurnId,
            payload: const {'status': 'completed'},
          ),
        );
        expect(controller.turns, hasLength(index + 1));
        expect(controller.turns.last.blocks, isEmpty);
        expect(controller.activeTurnId, active);
      },
    );
  }

  test('a failed rewind leaves the conversation and composer intact', () async {
    final core = RichFakeCore()
      ..historyCount = 3
      ..rewindFails = true;
    final controller = FocaletController(
      core: core,
      desktop: FakeDesktopBridge(),
    );
    addTearDown(controller.close);
    await controller.initialize();
    final before = controller.turns.toList();
    controller.updateComposerValue(
      const TextEditingValue(text: 'Separate draft'),
    );
    expect(await controller.resendMessage(before[1], 'Replacement'), isFalse);
    expect(controller.turns, before);
    expect(controller.composerValue.text, 'Separate draft');
    expect(core.startedTurns, isEmpty);
    expect(controller.sessionBusy, isFalse);
    expect(controller.status, contains('Could not resend'));
  });

  test(
    'rewind is single flight and locks session switching until resend',
    () async {
      final gate = Completer<void>();
      final core = RichFakeCore()
        ..historyCount = 3
        ..rewindGate = gate.future;
      final controller = FocaletController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      final original = controller.turns[1];
      final pending = controller.resendMessage(original, 'Replacement');
      await Future<void>.delayed(Duration.zero);
      expect(controller.turns, hasLength(3));
      expect(controller.sessionBusy, isTrue);
      expect(await controller.resendMessage(original, 'Double click'), isFalse);
      await controller.switchSession('other-chat');
      expect(controller.activeSessionId, 'session-1');
      gate.complete();
      expect(await pending, isTrue);
      expect(core.rewindRequests, hasLength(1));
      expect(core.startedTurns.single['message'], 'Replacement');
    },
  );

  test(
    'unsupported runtimes do not silently append an edited message',
    () async {
      final core = RichFakeCore()..historyCount = 3;
      final controller = FocaletController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      controller.capabilities.remove('session.rewind.v1');
      expect(controller.messageEditingSupported, isFalse);
      expect(
        await controller.resendMessage(controller.turns[1], 'Replacement'),
        isFalse,
      );
      expect(core.rewindRequests, isEmpty);
      expect(core.startedTurns, isEmpty);
      expect(controller.turns, hasLength(3));
    },
  );
}

class _DelayedHistoryCore extends RichFakeCore {
  Completer<void>? nextReadGate;
  final readStarted = Completer<void>();

  @override
  Future<Map<String, Object?>> readSession({
    required String runtimeTargetId,
    required String sessionId,
  }) async {
    final gate = nextReadGate;
    nextReadGate = null;
    final snapshot = await super.readSession(
      runtimeTargetId: runtimeTargetId,
      sessionId: sessionId,
    );
    if (gate != null) {
      readStarted.complete();
      await gate.future;
    }
    return snapshot;
  }
}
