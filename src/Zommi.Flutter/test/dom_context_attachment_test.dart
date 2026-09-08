import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/state/zommi_models.dart';

void main() {
  const bounds = <String, Object?>{
    'x': -600,
    'y': 200,
    'width': 300,
    'height': 160,
  };
  final alignment = <String, Object?>{
    'status': 'aligned',
    'screenBounds': bounds,
    'mapping': {
      'coordinateSpace': 'browser-viewport-css-pixels',
      'screenBounds': {'x': -800, 'y': 100, 'width': 1200, 'height': 800},
      'viewportBounds': {'x': 0, 'y': 0, 'width': 800, 'height': 533.33},
      'imageBounds': {'x': 0, 'y': 0, 'width': 300, 'height': 160},
    },
  };
  final snapshot = <String, Object?>{
    'source': {
      'provider': 'browser-dom',
      'nativeWindowId': '42',
      'tabId': 'tab-a',
      'documentId': 'doc-a',
    },
    'region': alignment,
    'dom': {
      'mode': 'region',
      'elements': [
        {'text': 'Only the chosen comment'},
      ],
    },
  };
  test(
    'an aligned image retains its exact region, source and coordinate mapping',
    () {
      final attachment = imageAttachmentFromSelection(
        ImageSelection(
          dataUrl: 'data:image/png;base64,YQ==',
          bounds: bounds,
          snapshot: snapshot,
          alignment: alignment,
          previewText: 'Only the chosen comment',
        ),
        'region-a',
      );
      expect(attachment.snapshot, snapshot);
      expect(attachment.previewText, 'Only the chosen comment');
      expect(attachment.bounds?['x'], -600);
    },
  );
  test('a mismatching region discards structured content and explains image-only capture', () {
    final attachment = imageAttachmentFromSelection(
      ImageSelection(
        dataUrl: 'data:image/png;base64,YQ==',
        bounds: {...bounds, 'x': 100},
        snapshot: snapshot,
        alignment: alignment,
      ),
      'region-b',
    );
    expect(attachment.snapshot?['dom'], isNull);
    expect(attachment.snapshot?['source'], isNull);
    expect(attachment.previewText, startsWith('Image only'));
    expect(
      attachment.snapshot?['region'],
      containsPair('status', 'image-only'),
    );
  });
  test(
    'a linked image without text keeps its URL in the preview and handoff',
    () {
      final linked = {
        ...snapshot,
        'dom': {
          'mode': 'region',
          'elements': [
            {
              'role': 'img',
              'text': '',
              'href': 'https://shop.example/products/a',
            },
            {
              'role': 'img',
              'text': '',
              'href': 'https://shop.example/products/b',
            },
          ],
        },
      };
      final attachment = imageAttachmentFromSelection(
        ImageSelection(
          dataUrl: 'data:image/png;base64,YQ==',
          bounds: bounds,
          snapshot: linked,
          alignment: alignment,
          previewText: 'Link: https://shop.example/products/a',
        ),
        'linked-images',
      );
      expect(attachment.excerpt, 'https://shop.example/products/a');
      expect(
        attachment.previewText,
        contains('https://shop.example/products/a'),
      );
      expect(
        contextHandoffSnapshots([attachment]).single['dom'],
        linked['dom'],
      );
      expect(contextHandoffSnapshots([attachment]).single['imageIndex'], 1);
    },
  );
  test('an image-only canvas retains verified source geometry but no inferred text', () {
    final imageOnly = {
      ...alignment,
      'status': 'image-only',
      'reason': 'Canvas pixels',
    };
    final attachment = imageAttachmentFromSelection(
      ImageSelection(
        dataUrl: 'data:image/png;base64,YQ==',
        bounds: bounds,
        alignment: imageOnly,
        snapshot: {
          ...snapshot,
          'region': imageOnly,
          'selection': ['Unrelated selection'],
        },
      ),
      'canvas',
    );
    expect(attachment.snapshot?['source'], snapshot['source']);
    expect(attachment.snapshot?['region'], imageOnly);
    expect(attachment.snapshot?['dom'], isNull);
    expect(attachment.snapshot?['selection'], isNull);
    expect(attachment.previewText, startsWith('Image with screen location'));
  });
  test('desktop pixels preserve mapping and observation time even without a single source window', () {
    final geometry = {
      ...alignment,
      'status': 'image-only',
      'reason': 'Spans windows',
    };
    final attachment = imageAttachmentFromSelection(
      ImageSelection(
        dataUrl: 'data:image/png;base64,YQ==',
        bounds: bounds,
        alignment: geometry,
        snapshot: {
          'snapshotId': 'captured-frame',
          'observedAtUtc': '2026-09-08T18:00:00Z',
          'expiresAtUtc': '2026-09-08T18:00:30Z',
          'region': geometry,
        },
      ),
      'attachment-id',
    );
    final handoff = contextHandoffSnapshots([attachment]).single;
    expect(handoff['region'], geometry);
    expect(handoff['snapshotId'], 'captured-frame');
    expect(handoff['observedAtUtc'], '2026-09-08T18:00:00Z');
    expect(handoff['imageIndex'], 1);
    expect(handoff['source'], isNull);
    expect(handoff['dom'], isNull);
  });
  test('legacy pointer snapshots are never presented as image-region text', () {
    final attachment = imageAttachmentFromSelection(
      const ImageSelection(
        dataUrl: 'data:image/png;base64,YQ==',
        bounds: bounds,
        snapshot: {
          'selection': ['Unrelated pointer content'],
        },
      ),
      'legacy',
    );
    expect(attachment.snapshot?['selection'], isNull);
    expect(attachment.previewText, contains('No aligned text'));
  });
  test(
    'each image keeps its index when text contexts are interleaved or removed',
    () {
      final image = imageAttachmentFromSelection(
        ImageSelection(
          dataUrl: 'data:image/png;base64,YQ==',
          bounds: bounds,
          snapshot: snapshot,
          alignment: alignment,
        ),
        'image',
      );
      final plain = ContextAttachment(
        id: 'plain',
        token: '',
        snapshot: {
          'selection': ['Text'],
        },
      );
      final snapshots = contextHandoffSnapshots([plain, image, plain, image]);
      expect(snapshots[1]['imageIndex'], 1);
      expect(snapshots[3]['imageIndex'], 2);
      expect(contextHandoffSnapshots([plain, image]).last['imageIndex'], 1);
      expect(snapshot.containsKey('imageIndex'), isFalse);
    },
  );
}
