import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focalet_flutter/core/core_bridge.dart';
import 'package:focalet_flutter/desktop/desktop_bridge.dart';
import 'package:focalet_flutter/focalet_app.dart';

import 'test_support.dart';

void main() {
  testWidgets(
    'approvals queue across chats and expire without losing the next request',
    (tester) async {
      await tester.binding.setSurfaceSize(normalWindowSize);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final core = RichFakeCore();
      await tester.pumpWidget(FocaletApp(core: core));
      await tester.pumpAndSettle();
      var sequence = 0;
      void emit(String name, String chat, String id) => core.emit(
        CoreEvent(
          name: name,
          sequence: ++sequence,
          runtimeTargetId: 'runtime-codex',
          sessionId: chat,
          turnId: 'turn-$chat',
          payload: {
            'approvalId': id,
            'toolCall': {'title': 'Run $id', 'rawInput': 'echo $id'},
            'options': [
              {'optionId': 'allow', 'name': 'Allow once', 'kind': 'allow_once'},
              {'optionId': 'deny', 'name': 'Deny', 'kind': 'reject_once'},
            ],
          },
        ),
      );
      emit('approval.requested', 'background-chat', 'first');
      emit('approval.requested', 'session-1', 'second');
      emit('approval.requested', 'session-1', 'second');
      await tester.pumpAndSettle();
      expect(find.text('Run first'), findsOneWidget);
      expect(find.textContaining('background-chat'), findsOneWidget);
      expect(find.textContaining('2 pending'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('approval-allow')));
      await tester.pumpAndSettle();
      expect(core.approvalResolution, (
        'runtime-codex',
        'background-chat',
        'first',
        'allow',
      ));
      expect(find.text('Run second'), findsOneWidget);
      emit('approval.requested', 'session-1', 'third');
      emit('approval.resolved', 'session-1', 'second');
      await tester.pumpAndSettle();
      expect(find.text('Run third'), findsOneWidget);
      emit('turn.completed', 'session-1', 'unused');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('approval-title')), findsNothing);
      emit('approval.requested', 'background-chat', 'fourth');
      await tester.pumpAndSettle();
      core.emit(
        CoreEvent(
          name: 'runtime.status',
          sequence: ++sequence,
          runtimeTargetId: 'runtime-codex',
          payload: const {'status': 'unavailable'},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('approval-title')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
