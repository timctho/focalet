import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/widgets/inline_attachment_composer.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'test_support.dart';

ContextAttachment selected(String id, String text) => ContextAttachment(
  id: id,
  token: '',
  snapshot: {
    'windowTitle': 'Comment source',
    'selection': [text],
  },
  previewText: text,
);

void main() {
  testWidgets(
    'a confirmed selection batch inserts all chips in order and keeps the draft',
    (tester) async {
      const png =
          'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
      final core = RichFakeCore()..historyCount = 0;
      final desktop = FakeDesktopBridge()
        ..nextSelections = [
          for (final row in [1, 3])
            ContextAttachment(
              id: 'row-$row',
              token: '',
              imageDataUrl: png,
              bounds: {
                'x': 411,
                'y': 400 + row * 70,
                'width': 302,
                'height': 50,
              },
              snapshot: {
                'selection': ['Row $row'],
                'spatialContext': {
                  'cells': [
                    {
                      'dataRowNumber': row,
                      'columnHeaders': ['Database Alias'],
                    },
                  ],
                },
              },
            ),
        ];
      await tester.binding.setSurfaceSize(const Size(1000, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(ZommiApp(core: core, desktop: desktop));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('zommi-composer')),
        'Compare these rows',
      );
      await tester.tap(find.byKey(const ValueKey('select-content')));
      await tester.pumpAndSettle();
      final composer =
          tester
                  .widget<TextField>(
                    find.byKey(const ValueKey('zommi-composer')),
                  )
                  .controller!
              as InlineAttachmentTextController;
      expect(composer.inlineAttachments.map((item) => item.id), [
        'row-1',
        'row-3',
      ]);
      expect(composer.inlineAttachments.map((item) => item.token), [
        '[A]',
        '[B]',
      ]);
      expect(composer.messageText, 'Compare these rows');
      // Removing all inline chips starts a fresh batch at A, including its
      // preview labels and the contextLabel later sent with each image.
      await tester.enterText(
        find.byKey(const ValueKey('zommi-composer')),
        'Compare these rows',
      );
      await tester.pumpAndSettle();
      expect(composer.inlineAttachments, isEmpty);
      await tester.tap(find.byKey(const ValueKey('select-content')));
      await tester.pumpAndSettle();
      expect(composer.inlineAttachments.map((item) => item.reference), [
        'A',
        'B',
      ]);
      desktop.nextSelections = [];
      await tester.tap(find.byKey(const ValueKey('select-content')));
      await tester.pumpAndSettle();
      expect(composer.inlineAttachments, hasLength(2));
      await tester.tap(find.byKey(const ValueKey('send-message')));
      await tester.pump();
      expect(core.lastImages, [png, png]);
      expect(core.lastSnapshots.map((item) => item['imageIndex']), [1, 2]);
      expect(core.lastSnapshots.map((item) => item['contextLabel']), [
        'A',
        'B',
      ]);
      expect((core.lastSnapshots.last['spatialContext'] as Map)['cells'], [
        {
          'dataRowNumber': 3,
          'columnHeaders': ['Database Alias'],
        },
      ]);
    },
  );

  test('adjustment to several selections keeps the original reference and appends the rest', () async {
    final desktop = FakeDesktopBridge()
      ..nextSelections = [
        selected('new-a', 'First replacement'),
        selected('new-b', 'Second replacement'),
      ];
    final controller = ZommiController(
      core: RichFakeCore()..historyCount = 0,
      desktop: desktop,
    );
    addTearDown(controller.close);
    await controller.initialize();
    controller.addAttachment(selected('old', 'Original'));
    await controller.addPointerContext(replacingId: 'old');
    expect(controller.attachments.map((item) => item.id), ['old', 'new-b']);
    expect(controller.attachments.map((item) => item.token), ['[A]', '[B]']);
    expect(controller.attachments.first.excerpt, 'First replacement');
  });

  test('a pending adjustment cannot submit the old context or start a second picker', () async {
    final core = RichFakeCore()..historyCount = 0;
    final selection = Completer<ContextAttachment?>();
    final desktop = FakeDesktopBridge()..selectionGate = selection.future;
    final controller = ZommiController(core: core, desktop: desktop);
    addTearDown(controller.close);
    await controller.initialize();
    controller.addAttachment(selected('a', 'Original'));
    final pending = controller.addPointerContext(replacingId: 'a');
    await controller.addPointerContext();
    await controller.submit('Explain A');
    expect(core.lastMessage, isNull);
    expect(
      desktop.calls.where((call) => call == 'selectPointerContext'),
      hasLength(1),
    );
    selection.complete(null);
    await pending;
    expect(controller.attachments.single.excerpt, 'Original');
    expect(controller.selectingContent, isFalse);
  });

  test('references survive removal and image replacement and reach the agent with the matching image', () async {
    final core = RichFakeCore()..historyCount = 0;
    final desktop = FakeDesktopBridge();
    final controller = ZommiController(core: core, desktop: desktop);
    addTearDown(controller.close);
    await controller.initialize();
    controller.addAttachment(selected('a', 'First'));
    controller.addAttachment(selected('b', 'Second'));
    controller.removeAttachment('a');
    controller.addAttachment(selected('c', 'Third'));
    expect(controller.attachments.map((item) => item.token), ['[B]', '[C]']);
    desktop.nextContext = ContextAttachment(
      id: 'image',
      token: '',
      imageDataUrl: 'data:image/png;base64,YQ==',
      snapshot: {
        'region': {'status': 'image-only'},
        'windowTitle': 'Chart',
      },
    );
    await controller.addPointerContext(replacingId: 'b');
    await controller.submit('Compare B and C');
    expect(core.lastImages, ['data:image/png;base64,YQ==']);
    expect(core.lastSnapshots.first['contextLabel'], 'B');
    expect(core.lastSnapshots.first['imageIndex'], 1);
    expect(core.lastSnapshots.last['contextLabel'], 'C');
  });

  test(
    'selection failure preserves the attachment and releases the picker',
    () async {
      final desktop = FakeDesktopBridge()
        ..selectionGate = Future<ContextAttachment?>.error(
          StateError('Window changed'),
        );
      final controller = ZommiController(
        core: RichFakeCore()..historyCount = 0,
        desktop: desktop,
      );
      addTearDown(controller.close);
      controller.addAttachment(selected('a', 'Keep this'));
      await controller.addPointerContext(replacingId: 'a');
      expect(controller.attachments.single.excerpt, 'Keep this');
      expect(controller.status, contains('Window changed'));
      expect(controller.selectingContent, isFalse);
    },
  );
}
