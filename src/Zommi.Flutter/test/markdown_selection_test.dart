import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/widgets/content_views.dart';

void main() {
  testWidgets('rich replies retain mouse selection, links and copy actions', (
    tester,
  ) async {
    String? clipboard;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    const sentence = 'Alpha bold text 選取測試.';
    const reply =
        'Alpha **bold text** 選取測試.\n\n'
        'Second paragraph stays readable.\n\n'
        '[Source](https://example.com/source)\n\n'
        '```text\ncopy this code\n```';
    final copied = <String>[];
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 650,
            child: CopyableMarkdown(
              text: reply,
              onCopy: (value) async => copied.add(value),
              onOpenLink: (value) async => opened.add(value),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final paragraph = tester.renderObject<RenderParagraph>(
      find.byWidgetPredicate(
        (widget) => widget is RichText && widget.text.toPlainText() == sentence,
      ),
    );
    final boxes = paragraph.getBoxesForSelection(
      const TextSelection(baseOffset: 0, extentOffset: sentence.length),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    final start = paragraph.localToGlobal(
      Offset(boxes.first.left + 1, (boxes.first.top + boxes.first.bottom) / 2),
    );
    final end = paragraph.localToGlobal(
      Offset(boxes.last.right - 1, (boxes.last.top + boxes.last.bottom) / 2),
    );
    await mouse.down(start);
    await mouse.moveTo(end);
    await mouse.up();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(clipboard, sentence);

    await tester.tap(
      find.byKey(const ValueKey('markdown-link-https://example.com/source')),
    );
    await tester.pump();
    expect(opened, ['https://example.com/source']);
    await tester.tap(find.byTooltip('Copy code'));
    await tester.pump();
    expect(copied.single.trim(), 'copy this code');
    final fullCopy = find.byKey(ValueKey('copy-${reply.hashCode}'));
    await mouse.moveTo(tester.getCenter(fullCopy));
    await tester.pumpAndSettle();
    await tester.tap(fullCopy);
    await tester.pump();
    expect(copied.last, reply);
    await tester.pump(const Duration(seconds: 2));
    await mouse.removePointer();
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
