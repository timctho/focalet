import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focalet_flutter/core/core_bridge.dart';
import 'package:focalet_flutter/state/focalet_controller.dart';
import 'package:focalet_flutter/state/focalet_models.dart';
import 'package:focalet_flutter/focalet_app.dart';
import 'package:focalet_flutter/widgets/transcript_view.dart';

import 'test_support.dart';

void main() {
  late RichFakeCore core;
  late FocaletController controller;
  var sequence = 0;

  Future<void> initialize() async {
    core = RichFakeCore()
      ..historyCount = 0
      ..uniqueTurnIds = true;
    controller = FocaletController(core: core, desktop: FakeDesktopBridge());
    addTearDown(controller.close);
    await controller.initialize();
    sequence = 0;
  }

  Future<void> complete(int index, {String status = 'completed'}) async {
    final turn = core.startedTurns[index];
    core.emit(
      CoreEvent(
        name: 'turn.completed',
        sequence: ++sequence,
        runtimeTargetId: turn['runtimeTargetId']! as String,
        sessionId: turn['sessionId']! as String,
        turnId: turn['turnId']! as String,
        clientOperationId: turn['clientOperationId'] as String?,
        payload: {'status': status},
      ),
    );
    await Future<void>.delayed(Duration.zero);
  }

  test(
    'follow-ups send once, in order, even when completion precedes receipt',
    () async {
      await initialize();
      final gate = Completer<void>();
      core.startTurnGate = gate.future;
      final first = controller.submit('one');
      await controller.submit('two');
      await controller.submit('three');
      expect(core.startedTurns.map((turn) => turn['message']), ['one']);
      expect(controller.queuedMessages.map((message) => message.text), [
        'two',
        'three',
      ]);
      await complete(0);
      expect(core.startedTurns, hasLength(1));
      gate.complete();
      await first;
      await Future<void>.delayed(Duration.zero);
      expect(core.startedTurns.map((turn) => turn['message']), ['one', 'two']);
      await complete(
        0,
      ); // A duplicate completion must not release message three.
      expect(controller.activeTurnId, core.startedTurns[1]['turnId']);
      expect(core.startedTurns, hasLength(2));
      await complete(1);
      expect(core.startedTurns.map((turn) => turn['message']), [
        'one',
        'two',
        'three',
      ]);
      await complete(2);
      expect(controller.turnActive, isFalse);
      expect(controller.queuedMessages, isEmpty);
    },
  );

  test('queued context and settings stay bound to the original chat', () async {
    await initialize();
    await controller.submit('first');
    controller.selectedModel = 'queued-model';
    controller.selectedEffort = 'low';
    controller.selectedWorkspace = '/queued-workspace';
    controller.selectedProfile = 'queued-profile';
    controller.addAttachment(
      ContextAttachment(
        id: 'source',
        token: '',
        snapshot: const {
          'selection': ['queued source'],
        },
      ),
    );
    controller.addAttachment(
      ContextAttachment(
        id: 'image',
        token: '',
        imageDataUrl: 'data:image/png;base64,cXVldWVk',
      ),
    );
    await controller.submit('follow-up', attachmentOrder: ['image', 'source']);
    expect(controller.attachments, isEmpty);
    await controller.switchSession('session-2');
    controller.selectedWorkspace = '/other-workspace';
    controller.updateComposerValue(
      const TextEditingValue(text: 'unsent draft'),
    );
    controller.addAttachment(
      ContextAttachment(
        id: 'other',
        token: '',
        snapshot: const {
          'selection': ['other source'],
        },
      ),
    );
    await complete(0);
    final sent = core.startedTurns.last;
    expect(sent['sessionId'], 'session-1');
    expect(sent['runtimeTargetId'], 'runtime-codex');
    expect(sent['model'], 'queued-model');
    expect(sent['effort'], 'low');
    expect(sent['cwd'], '/queued-workspace');
    expect(sent['profile'], 'queued-profile');
    expect(sent['images'], ['data:image/png;base64,cXVldWVk']);
    expect(sent['snapshots'].toString(), contains('queued source'));
    expect(sent['snapshots'].toString(), isNot(contains('other source')));
    expect(controller.composerValue.text, 'unsent draft');
    expect(controller.attachments.single.id, 'other');
    expect(controller.queuedMessages, isEmpty);
  });

  test(
    'Stop pauses follow-ups, removal and explicit resume preserve order',
    () async {
      await initialize();
      await controller.submit('one');
      await controller.submit('remove me');
      await controller.submit('keep me');
      await controller.interrupt();
      await complete(
        0,
      ); // Some runtimes complete normally after receiving Stop.
      expect(core.startedTurns, hasLength(1));
      expect(controller.queuePaused, isTrue);
      controller.removeQueuedMessage(controller.queuedMessages.first.id);
      controller.resumeQueuedMessages();
      await Future<void>.delayed(Duration.zero);
      expect(core.startedTurns.map((turn) => turn['message']), [
        'one',
        'keep me',
      ]);
    },
  );

  for (final status in ['failed', 'interrupted', 'unknown']) {
    test('$status pauses the queue for explicit resume', () async {
      await initialize();
      await controller.submit('one');
      await controller.submit('two');
      await complete(0, status: status);
      expect(controller.queuePaused, isTrue);
      expect(core.startedTurns, hasLength(1));
      controller.resumeQueuedMessages();
      await Future<void>.delayed(Duration.zero);
      expect(core.startedTurns, hasLength(2));
    });
  }

  for (final rejected in [false, true]) {
    test(
      'start ${rejected ? 'rejection' : 'failure'} retains follow-ups without retrying',
      () async {
        await initialize();
        final gate = Completer<void>();
        core.startTurnGate = gate.future;
        core.startTurnFails = !rejected;
        core.startTurnAccepted = !rejected;
        final first = controller.submit('one');
        await controller.submit('two');
        gate.complete();
        await first;
        expect(controller.turnActive, isFalse);
        expect(controller.queuePaused, isTrue);
        expect(controller.queuedMessages.single.text, 'two');
        expect(core.startedTurns, hasLength(1));
      },
    );
  }

  testWidgets('a rejected queued start preserves the newer composer draft', (
    tester,
  ) async {
    final core = RichFakeCore()
      ..historyCount = 0
      ..uniqueTurnIds = true;
    await tester.pumpWidget(
      FocaletApp(core: core, desktop: FakeDesktopBridge()),
    );
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('focalet-composer'));
    await tester.enterText(field, 'first');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.enterText(field, 'queued');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.enterText(field, 'newer draft');
    await tester.pump();
    core.startTurnError = const CoreProtocolException('session-busy', 'Busy');
    core.emit(
      const CoreEvent(
        name: 'turn.completed',
        sequence: 1,
        runtimeTargetId: 'runtime-codex',
        sessionId: 'session-1',
        turnId: 'session-1-live-turn-1',
        payload: {'status': 'completed'},
      ),
    );
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, 'newer draft');
    expect(find.text('Paused'), findsOneWidget);
    expect(find.text('queued'), findsOneWidget);
  });

  testWidgets(
    'response shows only Stop while Enter queues; idle Send and Resume return',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(640, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final core = RichFakeCore()
        ..historyCount = 0
        ..uniqueTurnIds = true;
      await tester.pumpWidget(
        FocaletApp(core: core, desktop: FakeDesktopBridge()),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('focalet-composer'));
      final send = find.byKey(const ValueKey('send-message'));
      await tester.enterText(field, 'one');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(core.startedTurns.single['message'], 'one');
      expect(find.byKey(const ValueKey('stop-turn')), findsOneWidget);
      expect(send, findsNothing);
      expect(find.byTooltip('Queue message (Enter)'), findsNothing);
      await tester.enterText(field, 'two');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.enterText(field, 'three');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      expect(find.text('2 queued'), findsOneWidget);
      expect(core.startedTurns, hasLength(1));
      await tester.tap(find.byTooltip('Remove queued message 1'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('stop-turn')));
      await tester.pump();
      core.emit(
        const CoreEvent(
          name: 'turn.completed',
          sequence: 1,
          runtimeTargetId: 'runtime-codex',
          sessionId: 'session-1',
          turnId: 'session-1-live-turn-1',
          payload: {'status': 'interrupted'},
        ),
      );
      await tester.pump();
      expect(find.text('Paused'), findsOneWidget);
      expect(send, findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('resume-message-queue')));
      await tester.pump();
      expect(core.startedTurns.last['message'], 'three');
      expect(send, findsNothing);
      expect(find.byKey(const ValueKey('message-queue')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'queue aligns with the transcript and composer at narrow and wide sizes',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final core = RichFakeCore()..historyCount = 0;
      await tester.binding.setSurfaceSize(const Size(1500, 900));
      await tester.pumpWidget(
        FocaletApp(core: core, desktop: FakeDesktopBridge()),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('focalet-composer'));
      await tester.enterText(field, 'Active request');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.enterText(field, 'Queued request');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      for (final width in [1500.0, 640.0]) {
        await tester.binding.setSurfaceSize(Size(width, 900));
        await tester.pump();
        final queue = tester.getRect(
          find.byKey(const ValueKey('message-queue')),
        );
        final composer = tester.getRect(
          find.byKey(const ValueKey('message-composer-shell')),
        );
        final user = tester.getRect(
          find.byKey(
            ValueKey(
              'user-message-${tester.widget<ConversationTurnView>(find.byType(ConversationTurnView)).turn.id}',
            ),
          ),
        );
        expect(queue.left, closeTo(composer.left, .1));
        expect(queue.right, closeTo(composer.right, .1));
        expect(queue.right, closeTo(user.right, .1));
        expect(queue.width, lessThanOrEqualTo(864));
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}
