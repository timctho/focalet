import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/widgets/content_views.dart';
import 'package:zommi_flutter/theme/zommi_typography.dart';

void main() {
  const destination =
      'https://example.com/source?q=one%20two&mode=full#section';
  const plainDestination = 'https://example.com/source?q=one&mode=full#section';
  for (final compact in [false, true]) {
    for (final (linkText, target) in [
      ('[Source]($destination)', destination),
      ('<$destination>', destination),
      (plainDestination, plainDestination),
    ]) {
      testWidgets(
        'right-click copies the link destination without opening it: $compact $linkText',
        (tester) async {
          final copied = <String>[];
          final opened = <String>[];
          String? clipboard;
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          messenger.setMockMethodCallHandler(SystemChannels.platform, (
            call,
          ) async {
            if (call.method == 'Clipboard.setData') {
              clipboard = (call.arguments as Map)['text'] as String;
            }
            return null;
          });
          addTearDown(
            () => messenger.setMockMethodCallHandler(
              SystemChannels.platform,
              null,
            ),
          );
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: CopyableMarkdown(
                  text: 'Plain $linkText',
                  compact: compact,
                  onCopy: (value) async => copied.add(value),
                  onOpenLink: (value) async => opened.add(value),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final link = find.byKey(ValueKey('markdown-link-$target'));
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          addTearDown(mouse.removePointer);
          await mouse.addPointer(location: Offset.zero);
          await mouse.moveTo(tester.getCenter(link));
          await tester.pump(const Duration(milliseconds: 400));
          await tester.tap(
            link,
            kind: PointerDeviceKind.mouse,
            buttons: kSecondaryMouseButton,
          );
          await tester.pumpAndSettle();
          expect(find.text('Copy'), findsOneWidget);
          expect(find.text('Select all'), findsOneWidget);
          expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
          expect(find.byType(PopupMenuItem<bool>), findsNothing);
          expect(copied, isEmpty);
          expect(opened, isEmpty);
          await tester.tap(find.text('Copy'));
          await tester.pumpAndSettle();
          expect(copied, [target]);
          expect(opened, isEmpty);
          expect(find.text('Copy'), findsNothing);

          await tester.tap(
            link,
            kind: PointerDeviceKind.mouse,
            buttons: kSecondaryMouseButton,
          );
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.text('Copy'), findsNothing);
          expect(copied, [target]);
          await tester.tap(
            link,
            kind: PointerDeviceKind.mouse,
            buttons: kSecondaryMouseButton,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Select all'));
          await tester.pumpAndSettle();
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pump();
          expect(
            clipboard,
            'Plain ${linkText.startsWith('[Source]') ? 'Source' : target}',
          );
          // Copy now applies to the selected message, using the same menu.
          await tester.tap(
            link,
            kind: PointerDeviceKind.mouse,
            buttons: kSecondaryMouseButton,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Copy'));
          await tester.pumpAndSettle();
          expect(copied, [target]);
          await tester.tap(link);
          await tester.pump();
          expect(opened, [target]);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.windows),
      );
    }
  }

  for (final compact in [false, true]) {
    testWidgets('links use a hand cursor over selectable glyphs: $compact', (
      tester,
    ) async {
      final opened = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CopyableMarkdown(
              text: 'Plain [Source](https://example.com/source)',
              compact: compact,
              onCopy: (_) async {},
              onOpenLink: (link) async => opened.add(link),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final link = find.byKey(
        const ValueKey('markdown-link-https://example.com/source'),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(link));
      await tester.pump();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.click,
      );
      await tester.tap(link);
      await tester.pump();
      expect(opened, ['https://example.com/source']);
      await mouse.removePointer();
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }

  for (final markdown in [
    'Before `highlighted code` after.',
    '> Before `highlighted code` after.',
    '| Example |\n| --- |\n| Before `highlighted code` after. |',
  ]) {
    testWidgets('selection stays visible over inline code in $markdown', (
      tester,
    ) async {
      const boundaryKey = ValueKey('selection-pixels');
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            textSelectionTheme: const TextSelectionThemeData(
              selectionColor: chatSelectionColor,
            ),
          ),
          home: Scaffold(
            body: RepaintBoundary(
              key: boundaryKey,
              child: SizedBox(
                width: 650,
                child: CopyableMarkdown(
                  text: markdown,
                  onCopy: (_) async {},
                  onOpenLink: (_) async {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final paragraph = tester.renderObject<RenderParagraph>(
        find.byWidgetPredicate(
          (widget) =>
              widget is RichText &&
              widget.text.toPlainText() == 'Before highlighted code after.',
        ),
      );
      final box = paragraph
          .getBoxesForSelection(
            const TextSelection(baseOffset: 7, extentOffset: 23),
          )
          .single;
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(boundaryKey),
      );
      final origin = boundary.globalToLocal(
        paragraph.localToGlobal(Offset(box.left, box.top)),
      );
      Future<({Uint8List bytes, int width})> pixels() async =>
          (await tester.runAsync(() async {
            final image = await boundary.toImage();
            final data = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            final width = image.width;
            image.dispose();
            return (bytes: data!.buffer.asUint8List(), width: width);
          }))!;
      final before = await pixels();
      final all = paragraph
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 30),
          )
          .single;
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.down(
        paragraph.localToGlobal(Offset(all.left + 1, all.toRect().center.dy)),
      );
      await mouse.moveTo(
        paragraph.localToGlobal(Offset(all.right - 1, all.toRect().center.dy)),
      );
      await mouse.up();
      await tester.pumpAndSettle();
      final after = await pixels();
      var difference = 0;
      var strongestDifference = 0;
      var samples = 0;
      for (
        var y = origin.dy.ceil() + 1;
        y < origin.dy + box.bottom - box.top - 1;
        y++
      ) {
        for (
          var x = origin.dx.ceil() + 2;
          x < origin.dx + box.right - box.left - 2;
          x++
        ) {
          final offset = (y * before.width + x) * 4;
          for (var channel = 0; channel < 3; channel++) {
            final delta =
                (before.bytes[offset + channel] - after.bytes[offset + channel])
                    .abs();
            difference += delta;
            if (delta > strongestDifference) strongestDifference = delta;
            samples++;
          }
        }
      }
      // The solid test glyphs stay unchanged; the selection tint around them
      // must show both a distinct color and coverage over the code background.
      expect(strongestDifference, greaterThan(40));
      expect(difference / samples, greaterThan(3));
      await mouse.removePointer();
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }

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

    final link = find.byKey(
      const ValueKey('markdown-link-https://example.com/source'),
    );
    await mouse.moveTo(tester.getCenter(link));
    await tester.tap(
      link,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select all'));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(
      clipboard,
      stringContainsInOrder([
        sentence,
        'Second paragraph stays readable.',
        'Source',
        'copy this code',
      ]),
    );
    await mouse.removePointer();
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
