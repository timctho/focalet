import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'test_support.dart';

void main() {
  testWidgets(
    'Up recalls recent messages, Down restores empty, edits keep normal arrows',
    (tester) async {
      final core = RichFakeCore()..historyCount = 0;
      await tester.pumpWidget(
        ZommiApp(core: core, desktop: FakeDesktopBridge()),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('zommi-composer'));
      final input = tester.widget<TextField>(field).controller!;
      for (final text in ['first\nmessage', 'second', 'third']) {
        await tester.enterText(field, text);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
      }
      for (final text in [
        'third',
        'second',
        'first\nmessage',
        'first\nmessage',
      ]) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        expect(input.text, text);
      }
      for (final text in ['second', 'third', '']) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(input.text, text);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      await tester.enterText(field, 'edited\nmessage');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(input.text, 'edited\nmessage');
      expect(input.selection.extentOffset, lessThan(input.text.length));
      await tester.enterText(field, '');
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(input.text, isEmpty);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '中文',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(input.text, contains('中文'));
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '中文',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(core.startedTurns, hasLength(1));
      expect(input.text, contains('中文'));
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('each chat recalls its own history and retains its draft', (
    tester,
  ) async {
    final core = RichFakeCore()..historyCount = 0;
    await tester.pumpWidget(ZommiApp(core: core, desktop: FakeDesktopBridge()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final field = find.byKey(const ValueKey('zommi-composer'));
    await tester.enterText(field, 'chat one');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.byKey(const ValueKey('session-runtime-codex-session-2')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(field);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    await tester.enterText(field, 'chat two');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.enterText(field, 'unfinished draft');
    await tester.tap(
      find.byKey(const ValueKey('session-runtime-codex-session-1')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(field);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(tester.widget<TextField>(field).controller!.text, 'chat one');
    await tester.tap(
      find.byKey(const ValueKey('session-runtime-codex-session-2')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.widget<TextField>(field).controller!.text,
      'unfinished draft',
    );
    await tester.enterText(field, '');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(tester.widget<TextField>(field).controller!.text, 'chat two');
  });

  test('history is bounded and includes previously loaded messages', () async {
    final core = RichFakeCore()..historyCount = 2;
    final controller = ZommiController(
      core: core,
      desktop: FakeDesktopBridge(),
    );
    addTearDown(controller.close);
    await controller.initialize();
    expect(controller.composerHistory, isNotEmpty);
    for (var index = 0; index < 25; index++) {
      await controller.submit('message $index');
    }
    expect(controller.composerHistory, hasLength(composerHistoryLimit));
    expect(controller.composerHistory.first, 'message 24');
    expect(controller.composerHistory.last, 'message 5');
  });
}
