import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focalet_flutter/state/focalet_models.dart';
import 'package:focalet_flutter/widgets/inline_attachment_composer.dart';
import 'package:focalet_flutter/focalet_app.dart';

import 'test_support.dart';

void main() {
  testWidgets(
    'IME underlines only the composing text beside inline attachments',
    (tester) async {
      final attachment = ContextAttachment(
        id: 'selected',
        token: '',
        previewText: 'Selected row',
      );
      final controller = InlineAttachmentTextController(
        onAttachmentRemoved: (_) {},
      );
      addTearDown(controller.dispose);
      controller.value = const TextEditingValue(
        text: '前文',
        selection: TextSelection.collapsed(offset: 2),
      );
      controller.syncAttachments([attachment]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TextField(controller: controller)),
        ),
      );
      await tester.showKeyboard(find.byType(TextField));
      final draft = '前文$inlineAttachmentMarker中文輸入後文';
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: draft,
          selection: const TextSelection.collapsed(offset: 7),
          composing: const TextRange(start: 3, end: 7),
        ),
      );
      await tester.pump();

      List<String> underlined(InlineSpan span) {
        final result = <String>[];
        span.visitChildren((child) {
          if (child is TextSpan &&
              child.style?.decoration?.contains(TextDecoration.underline) ==
                  true) {
            result.add(child.text ?? '');
          }
          return true;
        });
        return result;
      }

      final render = tester
          .state<EditableTextState>(find.byType(EditableText))
          .renderEditable;
      expect(underlined(render.text!), ['中文輸入']);
      expect(controller.value.composing, const TextRange(start: 3, end: 7));
      expect(controller.text, draft);
      expect(find.byType(InlineAttachmentTile), findsOneWidget);

      final context = tester.element(find.byType(TextField));
      expect(
        underlined(
          controller.buildTextSpan(context: context, withComposing: false),
        ),
        isEmpty,
      );
      tester.testTextInput.updateEditingValue(
        controller.value.copyWith(composing: TextRange.empty),
      );
      await tester.pump();
      expect(underlined(render.text!), isEmpty);
      expect(controller.text, draft);
      expect(find.byType(InlineAttachmentTile), findsOneWidget);

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'plain Chinese composition remains underlined across app updates',
    (tester) async {
      await tester.pumpWidget(
        FocaletApp(
          core: RichFakeCore()..historyCount = 0,
          desktop: FakeDesktopBridge(),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('focalet-composer'));
      await tester.showKeyboard(field);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '正在輸入',
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange(start: 2, end: 4),
        ),
      );
      await tester.pump();
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      final composingSpan = (editable.renderEditable.text! as TextSpan)
          .children!
          .whereType<TextSpan>()
          .last;
      expect(composingSpan.text, '輸入');
      expect(composingSpan.style?.decoration, TextDecoration.underline);
      await tester.tap(find.byKey(const ValueKey('app-settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('XL'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).style?.fontSize, 17);
      expect(
        editable.widget.controller.value.composing,
        const TextRange(start: 2, end: 4),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
