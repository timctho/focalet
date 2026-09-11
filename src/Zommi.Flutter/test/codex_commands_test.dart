import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/widgets/inline_attachment_composer.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'test_support.dart';

void main() {
  Future<(ZommiController, RichFakeCore)> setup() async {
    final core = RichFakeCore()..historyCount = 0;
    final controller = ZommiController(
      core: core,
      desktop: FakeDesktopBridge(),
    );
    addTearDown(controller.close);
    await controller.initialize();
    return (controller, core);
  }

  test(
    'clear starts a new chat and keeps the original history and settings',
    () async {
      final (controller, core) = await setup();
      controller.selectedModel = 'fixture-mini';
      controller.selectedEffort = 'medium';
      controller.updateComposerValue(const TextEditingValue(text: '/clear'));
      await controller.submit('/clear');
      expect(core.lastMessage, isNull);
      expect(core.createdSessions, hasLength(1));
      expect(controller.activeSessionId, 'created-session');
      expect(controller.selectedModel, 'fixture-mini');
      expect(controller.selectedEffort, 'medium');
      expect(controller.turns, isEmpty);
      await controller.switchSession('session-1');
      expect(controller.composerValue.text, isEmpty);
      expect(core.openedSessions.last.$2, 'session-1');
    },
  );

  test('failed clear and unknown commands preserve the draft without sending a turn', () async {
    final (controller, core) = await setup();
    core.createSessionFails = true;
    controller.updateComposerValue(const TextEditingValue(text: '/clear'));
    await controller.submit('/clear');
    expect(controller.activeSessionId, 'session-1');
    expect(controller.composerValue.text, '/clear');
    await controller.submit('/clear everything');
    expect(controller.commandResult, contains('without arguments'));
    await controller.submit('/unknown');
    expect(controller.commandResult, contains('Unknown Codex command'));
    await controller.submit('/debug-config');
    expect(controller.commandResult, contains('Unknown Codex command'));
    await controller.submit('/CLEAR');
    expect(controller.commandResult, contains('Unknown Codex command'));
    await controller.submit('/');
    expect(controller.commandResult, contains('/help'));
    expect(core.lastMessage, isNull);
  });

  test(
    'goal lifecycle is structured, edits retain usage, and errors retain input',
    () async {
      final (controller, core) = await setup();
      await controller.submit('/goal Finish the migration\nand tests');
      expect(
        core.goalCommands.last,
        containsPair('objective', 'Finish the migration\nand tests'),
      );
      expect(core.lastMessage, isNull);
      expect(controller.commandResult, contains('Goal · active'));
      core.goals['session-1']!['tokensUsed'] = 42;
      await controller.submit('/goal pause');
      expect(controller.commandResult, contains('Goal · paused'));
      expect(controller.commandResult, contains('42 tokens'));
      await controller.submit('/goal edit');
      expect(
        controller.composerValue.text,
        '/goal Finish the migration\nand tests',
      );
      expect(core.goalCommands.last['action'], 'get');
      await controller.submit('/goal resume');
      expect(controller.commandResult, contains('42 tokens'));
      await controller.submit('/goal clear');
      expect(controller.commandResult, contains('No goal set'));
      core.goalCommandFails = true;
      controller.updateComposerValue(
        const TextEditingValue(text: '/goal test'),
      );
      await controller.submit('/goal test');
      expect(controller.composerValue.text, '/goal test');
      expect(controller.commandResult, contains('Goals are unavailable'));
      expect(core.lastMessage, isNull);
    },
  );

  test('goal events stay scoped to their chat and native goal turns remain distinct', () async {
    final (controller, core) = await setup();
    await controller.submit('/goal First goal');
    core.emit(
      const CoreEvent(
        name: 'goal.updated',
        sequence: 1,
        runtimeTargetId: 'runtime-codex',
        sessionId: 'session-2',
        payload: {
          'goal': {'objective': 'Other goal', 'status': 'active'},
        },
      ),
    );
    expect(controller.commandResult, contains('First goal'));
    for (var i = 1; i <= 2; i++) {
      core.emit(
        CoreEvent(
          name: 'turn.started',
          sequence: i * 2,
          runtimeTargetId: 'runtime-codex',
          sessionId: 'session-1',
          turnId: 'goal-turn-$i',
          payload: const {},
        ),
      );
      core.emit(
        CoreEvent(
          name: 'turn.completed',
          sequence: i * 2 + 1,
          runtimeTargetId: 'runtime-codex',
          sessionId: 'session-1',
          turnId: 'goal-turn-$i',
          payload: const {'status': 'completed'},
        ),
      );
    }
    expect(controller.turns.map((turn) => turn.id), [
      'goal-turn-1',
      'goal-turn-2',
    ]);
    await controller.submit('/clear');
    expect(core.createdSessions, hasLength(1));
    expect(core.goals['session-1']!['status'], 'paused');
  });

  test('goal commands reject oversize objectives and attached context without losing either', () async {
    final (controller, core) = await setup();
    final before = core.goalCommands.length;
    await controller.submit('/goal ${'𐐀' * 4001}');
    expect(controller.commandResult, contains('4,000'));
    controller.addAttachment(
      ContextAttachment(
        id: 'context',
        token: '',
        snapshot: const {
          'selection': ['/goal injected'],
        },
      ),
    );
    await controller.submit('/goal Finish the task');
    expect(controller.commandResult, contains('attached content'));
    expect(controller.attachments, hasLength(1));
    expect(core.goalCommands, hasLength(before));
    expect(core.lastMessage, isNull);
  });

  test('normal messages and other runtimes do not enter the Codex command dispatcher', () async {
    final (controller, core) = await setup();
    await controller.submit('Explain /goal without running it');
    expect(core.lastMessage, 'Explain /goal without running it');
    await controller.selectRuntime('runtime-pi');
    await controller.submit('/goal Something for Pi');
    expect(core.lastMessage, '/goal Something for Pi');
  });

  testWidgets(
    'composer supports slash discovery, goal editing, and pause during a running turn',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final core = RichFakeCore()..historyCount = 0;
      await tester.pumpWidget(
        ZommiApp(core: core, desktop: FakeDesktopBridge()),
      );
      await tester.pumpAndSettle();
      final composer = find.byKey(const ValueKey('zommi-composer'));
      Future<void> command(String text) async {
        await tester.enterText(composer, text);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        // A running session animates its status icon in the default sidebar.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      await tester.enterText(composer, '/');
      await tester.pump();
      expect(find.byKey(const ValueKey('codex-command-menu')), findsOneWidget);
      await command('/goal Finish tests');
      expect(tester.widget<TextField>(composer).controller!.text, isEmpty);
      expect(find.textContaining('Goal · active'), findsOneWidget);
      await command('/goal edit');
      expect(
        tester.widget<TextField>(composer).controller!.text,
        '/goal Finish tests',
      );
      core.emit(
        const CoreEvent(
          name: 'turn.started',
          sequence: 1,
          runtimeTargetId: 'runtime-codex',
          sessionId: 'session-1',
          turnId: 'native-goal-turn',
          payload: {},
        ),
      );
      await tester.pump();
      await command('/goal pause');
      expect(find.textContaining('Goal · paused'), findsOneWidget);
      expect(core.goalCommands.last['action'], 'pause');
      expect(core.lastMessage, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'slash suggestions filter, complete with keyboard or click, and highlight only the command',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(720, 620));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final core = RichFakeCore()..historyCount = 0;
      await tester.pumpWidget(
        ZommiApp(core: core, desktop: FakeDesktopBridge()),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('zommi-composer'));
      InlineAttachmentTextController composer() =>
          tester.widget<TextField>(field).controller!
              as InlineAttachmentTextController;
      final menu = find.byKey(const ValueKey('codex-command-menu'));
      await tester.enterText(field, '/');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('codex-command-/clear')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('codex-command-/goal')), findsOneWidget);
      await tester.enterText(field, '/cl');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('codex-command-/clear')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('codex-command-/goal')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(composer().text, '/clear');
      expect(menu, findsNothing);
      expect(core.createdSessions, isEmpty);

      await tester.enterText(field, '/goal');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('codex-command-/goal pause')),
        findsOneWidget,
      );
      final position = composer().selection;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(composer().selection, position);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(composer().text, '/goal pause');
      expect(core.goalCommands.where((c) => c['action'] == 'pause'), isEmpty);

      await tester.enterText(field, '/goal c');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('codex-command-/goal clear')));
      await tester.pump();
      expect(composer().text, '/goal clear');

      await tester.enterText(field, '/goal Fix the bug');
      await tester.pump();
      expect(menu, findsNothing);
      final span = composer().buildTextSpan(
        context: tester.element(field),
        style: const TextStyle(fontWeight: FontWeight.w400),
        withComposing: true,
      );
      final textSpans = span.children!.whereType<TextSpan>().toList();
      expect(textSpans.first.text, '/goal');
      expect(textSpans.first.style!.fontWeight, FontWeight.w700);
      expect(textSpans.last.text, ' Fix the bug');
      expect(textSpans.last.style!.fontWeight, FontWeight.w400);
      expect(span.toPlainText(), '/goal Fix the bug');

      await tester.enterText(field, '/goal');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(menu, findsNothing);
      expect(composer().text, '/goal');
      expect(tester.takeException(), isNull);
    },
  );
}
