import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'test_support.dart';

void main() {
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
