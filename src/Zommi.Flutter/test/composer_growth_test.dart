import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'test_support.dart';

void main() {
  testWidgets(
    'an inline context expands its line without covering adjacent text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(720, 620));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final desktop = FakeDesktopBridge()
        ..nextContext = ContextAttachment(
          id: 'tall-context',
          token: '',
          snapshot: {
            'selection': ['Selected content'],
          },
        );
      await tester.pumpWidget(
        ZommiApp(core: RichFakeCore()..historyCount = 0, desktop: desktop),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('zommi-composer'));
      await tester.enterText(field, 'Above\n\nBelow');
      await tester.pump();
      final plainBounds = tester.getRect(field);
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      editable.widget.controller.selection = const TextSelection.collapsed(
        offset: 6,
      );
      await tester.tap(find.byKey(const ValueKey('select-content')));
      await tester.pumpAndSettle();
      final tile = tester.getRect(
        find.byKey(const ValueKey('composer-inline-tile-tall-context')),
      );
      final render = editable.renderEditable;
      Rect textBounds(int start, int end) {
        final box = render
            .getBoxesForSelection(
              TextSelection(baseOffset: start, extentOffset: end),
            )
            .first
            .toRect();
        return box.shift(render.localToGlobal(Offset.zero));
      }

      final above = textBounds(0, 5);
      final below = textBounds(8, 13);
      expect(above.bottom, lessThanOrEqualTo(tile.top));
      expect(tile.bottom, lessThanOrEqualTo(below.top));
      final fieldBounds = tester.getRect(field);
      expect(fieldBounds.contains(tile.topLeft), isTrue);
      expect(fieldBounds.contains(tile.bottomRight), isTrue);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('composer-inline-tile-tall-context')),
          matching: find.byType(IconButton),
        ),
      );
      await tester.pumpAndSettle();
      expect(editable.widget.controller.text, 'Above\n\nBelow');
      expect(tester.getRect(field), plainBounds);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'every added line grows the composer upward with fixed controls',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(720, 620));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ZommiApp(
          core: RichFakeCore()..historyCount = 0,
          desktop: FakeDesktopBridge(),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('zommi-composer'));
      final shell = find.byKey(const ValueKey('message-composer-shell'));
      final send = find.byKey(const ValueKey('send-message'));
      await tester.enterText(field, 'First line');
      await tester.pump();
      final first = tester.getRect(shell);
      final sendFirst = tester.getRect(send);
      await tester.enterText(field, 'First line\nSecond line');
      await tester.pump();
      final second = tester.getRect(shell);
      // Every extra line needs room of its own; controls must not mask its growth.
      expect(first.top - second.top, greaterThanOrEqualTo(10));
      expect(second.bottom, closeTo(first.bottom, .1));
      expect(tester.getRect(send).center.dy, closeTo(sendFirst.center.dy, .1));
      var previous = second;
      for (var lines = 3; lines <= 5; lines++) {
        await tester.enterText(
          field,
          List.filled(lines, 'One line').join('\n'),
        );
        await tester.pump();
        final grown = tester.getRect(shell);
        expect(previous.top - grown.top, greaterThanOrEqualTo(10));
        expect(grown.bottom, closeTo(first.bottom, .1));
        expect(
          tester.getRect(send).center.dy,
          closeTo(sendFirst.center.dy, .1),
        );
        previous = grown;
      }
      await tester.enterText(field, List.filled(12, 'One line').join('\n'));
      await tester.pumpAndSettle();
      expect(tester.getRect(shell), previous);
      await tester.enterText(field, 'First line');
      await tester.pump();
      expect(tester.getRect(shell), first);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'soft wrapping and attachments grow above the anchored send button',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(720, 620));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final desktop = FakeDesktopBridge()
        ..nextContext = ContextAttachment(
          id: 'card-context',
          token: '',
          snapshot: {
            'selection': ['Twelve selected cards'],
          },
        );
      await tester.pumpWidget(
        ZommiApp(core: RichFakeCore()..historyCount = 0, desktop: desktop),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('zommi-composer'));
      final shell = find.byKey(const ValueKey('message-composer-shell'));
      final send = find.byKey(const ValueKey('send-message'));
      final bottom = tester.getRect(shell).bottom;
      final sendPosition = tester.getRect(send).center;
      final initialHeight = tester.getSize(shell).height;
      await tester.enterText(
        field,
        List.filled(14, 'Compare these cards').join(' '),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(shell).height, greaterThan(initialHeight));
      expect(tester.getRect(shell).bottom, closeTo(bottom, .1));
      expect(tester.getRect(send).center, sendPosition);
      await tester.enterText(field, 'Compare\nthese cards');
      await tester.tap(find.byKey(const ValueKey('select-content')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('composer-inline-tile-card-context')),
        findsOneWidget,
      );
      expect(tester.getRect(shell).bottom, closeTo(bottom, .1));
      expect(tester.getRect(send).center, sendPosition);
      expect(tester.takeException(), isNull);
    },
  );
}
