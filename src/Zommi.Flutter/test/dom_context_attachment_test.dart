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
  test('frozen annotated images retain provenance and time without stale source context', () {
    final geometry = {...alignment, 'status': 'image-only'};
    final annotations = {
      'source': 'user',
      'bakedIntoImage': true,
      'strokeCount': 2,
      'tools': ['pen', 'arrow'],
    };
    final attachment = imageAttachmentFromSelection(
      ImageSelection(
        dataUrl: 'data:image/png;base64,YQ==',
        bounds: bounds,
        alignment: geometry,
        snapshot: {
          'region': geometry,
          'observedAtUtc': '2026-09-20T12:00:00Z',
          'imageAnnotations': annotations,
          'regionContext': {'text': 'must not survive'},
        },
      ),
      'annotated',
    );
    final handoff = contextHandoffSnapshots([attachment]).single;
    expect(handoff['imageAnnotations'], annotations);
    expect(handoff['observedAtUtc'], '2026-09-20T12:00:00Z');
    expect(handoff['regionContext'], isNull);
    expect(handoff['source'], isNull);
    expect(handoff['imageIndex'], 1);
  });
  test('a partial cell crop keeps verified row context without claiming whole-cell selected text', () {
    final spatial = {
      'cells': [
        {
          'rowIndex': 1,
          'columnIndex': 1,
          'firstDataRowIndex': 1,
          'dataRowNumber': 1,
          'columnHeaders': ['Database Alias'],
        },
      ],
    };
    final geometry = {...alignment, 'status': 'image-only'};
    ImageSelection selection(Map<String, Object?> selectedBounds) =>
        ImageSelection(
          dataUrl: 'data:image/png;base64,YQ==',
          bounds: selectedBounds,
          alignment: geometry,
          snapshot: {
            ...snapshot,
            'region': geometry,
            'spatialContext': spatial,
            'selection': ['Not fully enclosed'],
          },
        );
    final attachment = imageAttachmentFromSelection(selection(bounds), 'cell');
    expect(attachment.snapshot?['spatialContext'], spatial);
    expect(attachment.snapshot?['selection'], isNull);
    expect(attachment.excerpt, 'Database Alias · row 1');
    expect(
      contextHandoffSnapshots([attachment]).single['spatialContext'],
      spatial,
    );
    final mismatched = imageAttachmentFromSelection(
      selection({...bounds, 'x': 100}),
      'changed',
    );
    expect(mismatched.snapshot?['spatialContext'], isNull);
  });
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
      for (final field in snapshot.keys) {
        expect(attachment.snapshot?[field], snapshot[field]);
      }
      expect(attachment.snapshot?['selectionKind'], 'bbox');
      expect(attachment.snapshot?['capturePlatform'], isNotEmpty);
      expect(attachment.snapshot?['captureHostName'], isNotEmpty);
      expect(attachment.previewText, 'Only the chosen comment');
      expect(attachment.bounds?['x'], -600);
    },
  );
  test('rich bbox context survives the common handoff with actual image dimensions', () {
    final imageAlignment = {
      ...alignment,
      'mapping': {
        ...alignment['mapping'] as Map,
        'imageBounds': {'x': 0, 'y': 0, 'width': 1, 'height': 1},
      },
    };
    final context = {
      'version': 1,
      'coordinateSpace': 'image-pixels',
      'elements': [
        {
          'id': 'e1',
          'nativeIds': {'uiaAutomationId': 'comment'},
          'text': 'Actual rectangle content',
          'state': {'enabled': false},
          'relation': 'intersects',
        },
      ],
    };
    ImageSelection selection(Map<String, Object?> selectedBounds) =>
        ImageSelection(
          dataUrl: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a2ioAAAAASUVORK5CYII=',
          bounds: selectedBounds,
          alignment: imageAlignment,
          snapshot: {
            ...snapshot,
            'region': imageAlignment,
            'regionContext': context,
            'selection': ['Unrelated application selection'],
            'source': {
              ...snapshot['source'] as Map,
              'platform': 'windows',
              'hostName': 'capture-pc',
            },
          },
        );
    final attachment = imageAttachmentFromSelection(selection(bounds), 'bbox');
    final handoff = contextHandoffSnapshots([attachment]).single;
    expect(handoff['regionContext'], context);
    expect(handoff['capturePlatform'], 'windows');
    expect(handoff['captureHostName'], 'capture-pc');
    expect(handoff['imageSize'], {'width': 1, 'height': 1});
    expect(handoff['imageIndex'], 1);
    expect(attachment.excerpt, 'Actual rectangle content');
    expect(attachment.captureSummary, contains('Region context: 1 elements'));
    expect(attachment.captureSummary, contains('image-pixels'));
    final mismatched = imageAttachmentFromSelection(
      selection({...bounds, 'x': 100}),
      'bad',
    );
    expect(mismatched.snapshot?['regionContext'], isNull);
    final wrongImage = imageAttachmentFromSelection(
      ImageSelection(
        dataUrl: selection(bounds).dataUrl,
        bounds: bounds,
        alignment: alignment,
        snapshot: {...snapshot, 'regionContext': context},
      ),
      'wrong-size',
    );
    expect(wrongImage.snapshot?['regionContext'], isNull);
    final unknownOrigin = imageAttachmentFromSelection(
      const ImageSelection(dataUrl: 'data:image/png;base64,YQ=='),
      'unknown',
    );
    expect((unknownOrigin.snapshot?['region'] as Map)['screenBounds'], isNull);
    expect(unknownOrigin.snapshot?['imageSize'], isNull);
  });
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
