import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/state/zommi_models.dart';

import 'test_support.dart';

CoreEvent recovered({String sessionId = 'session-1'}) => CoreEvent(
  name: 'runtime.recovered',
  sequence: 4,
  runtimeTargetId: 'runtime-codex',
  payload: {
    'previousSessionId': 'session-1',
    'connection': {
      'runtimeTargetId': 'runtime-codex',
      'sessionId': sessionId,
      'protocolVersion': 1,
      'models': RichFakeCore.models,
      'sessions': [
        {'id': sessionId, 'name': 'Recovered chat'},
      ],
      'sessionMetadata': {'cwd': '/workspace'},
    },
  },
);

void main() {
  test(
    'recovery preserves selected chat, settings, and interrupted transcript',
    () async {
      final core = RichFakeCore()..historyCount = 0;
      final controller = ZommiController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      controller.selectedWorkspace = '/chosen/workspace';
      controller.selectedEffort = 'xhigh';
      await controller.submit('keep this message');
      final operationId = controller.turns.single.id;
      core.emit(
        CoreEvent(
          name: 'turn.completed',
          sequence: 2,
          runtimeTargetId: 'runtime-codex',
          sessionId: 'session-1',
          turnId: 'session-1-live-turn',
          clientOperationId: operationId,
          payload: const {'status': 'unknown'},
        ),
      );
      core.emit(
        const CoreEvent(
          name: 'runtime.status',
          sequence: 3,
          runtimeTargetId: 'runtime-codex',
          payload: {'status': 'recovering', 'message': 'Reconnecting'},
        ),
      );
      core.emit(recovered());
      expect(controller.activeSessionId, 'session-1');
      expect(controller.turnActive, isFalse);
      expect(controller.turns.single.userText, 'keep this message');
      expect(
        controller.turns.single.blocks
            .where((block) => block.kind == TranscriptKind.error)
            .single
            .text,
        contains('not resent'),
      );
      expect(controller.selectedWorkspace, '/chosen/workspace');
      expect(controller.selectedEffort, 'xhigh');
      expect(controller.status, 'Codex connection restored');
    },
  );

  test(
    'background recovery does not select its chat over another runtime',
    () async {
      final core = RichFakeCore()..historyCount = 0;
      final controller = ZommiController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      await controller.selectRuntime('runtime-pi');
      final sessionId = controller.activeSessionId;
      final status = controller.status;
      core.emit(recovered());
      expect(controller.activeRuntime?.id, 'runtime-pi');
      expect(controller.activeSessionId, sessionId);
      expect(controller.status, status);
    },
  );

  test(
    'an unpersisted empty chat can adopt the replacement session id',
    () async {
      final core = RichFakeCore()..historyCount = 0;
      final controller = ZommiController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      core.emit(recovered(sessionId: 'fresh-empty-chat'));
      expect(controller.activeSessionId, 'fresh-empty-chat');
      expect(controller.turns, isEmpty);
    },
  );
}
