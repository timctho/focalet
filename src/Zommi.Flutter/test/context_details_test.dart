import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/widgets/overlay_panels.dart';

Map<String, Object?> snapshot({
  bool tree = false,
  bool dom = false,
  bool grid = false,
}) => {
  'windowTitle': 'Captured window',
  'source': {
    'provider': tree ? 'windows-uia-region' : 'windows-screen-region',
    'nativeWindowId': '123',
    'processId': 456,
    'windowBounds': {'x': -11, 'y': -11, 'width': 2422, 'height': 1550},
  },
  'region': {
    'status': tree ? 'aligned' : 'image-only',
    'screenBounds': {'x': 310, 'y': 354, 'width': 231, 'height': 355},
    'mapping': {
      'coordinateSpace': 'desktop-physical-pixels',
      'imageBounds': {'x': 0, 'y': 0, 'width': 231, 'height': 355},
    },
  },
  if (tree)
    'accessibilityTree': {
      'truncated': true,
      'roots': [
        {
          'role': 'Document',
          'children': [
            {'role': 'Hyperlink', 'name': 'Source'},
          ],
        },
      ],
    },
  if (dom)
    'dom': {
      'elements': [
        {'tag': 'a', 'href': 'https://example.com'},
      ],
    },
  if (grid)
    'spatialContext': {
      'cells': [
        for (var row = 0; row < 6; row++)
          {
            'rowIndex': row,
            'columnIndex': 1,
            'columnHeaders': ['Region'],
          },
      ],
    },
  'limitation': 'Only enclosed elements are included.',
};

void main() {
  test('image-only metadata still exposes coordinates and table context', () {
    final attachment = ContextAttachment(
      id: 'a',
      token: '[A]',
      previewText: 'Image only',
      snapshot: snapshot(grid: true),
    );
    expect(
      attachment.captureSummary,
      contains('Window: x=-11, y=-11, 2422 × 1550'),
    );
    expect(
      attachment.captureSummary,
      contains('Selection: x=310, y=354, 231 × 355'),
    );
    expect(attachment.captureSummary, contains('desktop-physical-pixels'));
    expect(attachment.captureSummary, contains('HTML DOM: not captured'));
    expect(
      attachment.captureSummary,
      contains('Accessibility tree: not captured'),
    );
    expect(attachment.captureSummary, contains('Table location: 6 cells'));
    expect(
      attachment.captureSummary,
      contains('Only enclosed elements are included.'),
    );
    expect(jsonDecode(attachment.capturedDetailsText), attachment.snapshot);
    expect(
      contextHandoffSnapshots([attachment]).single['spatialContext'],
      attachment.snapshot!['spatialContext'],
    );
  });

  test(
    'DOM and accessibility summaries report available and truncated structure',
    () {
      final attachment = ContextAttachment(
        id: 'b',
        token: '[B]',
        snapshot: snapshot(tree: true, dom: true),
      );
      expect(attachment.captureSummary, contains('HTML DOM: included'));
      expect(
        attachment.captureSummary,
        contains('Accessibility tree: 2 nodes'),
      );
      expect(attachment.captureSummary, contains('Structure was truncated'));
      expect(attachment.captureSummary, contains('structure may be partial'));
    },
  );

  testWidgets(
    'capture text stays in Details until expanded, including text-only captures',
    (tester) async {
      final data = snapshot(tree: true, grid: true);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ContextPreviewPanel(
                attachment: ContextAttachment(
                  id: 'b',
                  token: '[B]',
                  snapshot: data,
                  previewText: 'Short preview',
                ),
                onClose: () {},
                onPointerEnter: () {},
                onPointerExit: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Captured window', findRichText: true), findsNothing);
      expect(
        find.byKey(const ValueKey('context-capture-summary')),
        findsNothing,
      );
      expect(find.text('Short preview'), findsNothing);
      expect(find.byKey(const ValueKey('context-captured-json')), findsNothing);
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      final summary = tester.widget<SelectableText>(
        find.byKey(const ValueKey('context-capture-summary')),
      );
      expect(summary.data, contains('Accessibility tree: 2 nodes'));
      expect(find.text('Short preview'), findsOneWidget);
      final json = tester.widget<SelectableText>(
        find.byKey(const ValueKey('context-captured-json')),
      );
      expect(jsonDecode(json.data!), data);
      expect(tester.takeException(), isNull);
    },
  );
}
