import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/desktop/region_selection.dart';
import 'package:zommi_flutter/widgets/region_capture_editor.dart';

Future<CapturedDisplay> display() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 100, 80),
    Paint()..color = Colors.white,
  );
  canvas.drawRect(
    const Rect.fromLTWH(12, 12, 10, 10),
    Paint()..color = Colors.black,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(100, 80);
  picture.dispose();
  return CapturedDisplay(
    image: image,
    bounds: const Rect.fromLTWH(-50, 20, 50, 40),
    windows: [source],
    observedAt: DateTime.utc(2026, 9, 23),
  );
}

const source = <String, Object?>{
  'nativeWindowId': 'fixture',
  'processId': 24,
  'processStartToken': 'original',
  'windowTitle': 'Fixture',
  'application': 'Fixture',
  'platform': 'linux',
  'bounds': {'x': -50, 'y': 20, 'width': 50, 'height': 40},
};

class _ChangingBrowser implements NativeCaptureClient {
  final methods = <String>[];
  @override
  Future<Map<String, Object?>> request(
    String method, {
    Map<String, Object?> parameters = const {},
    void Function()? onReady,
  }) async {
    methods.add(method);
    return {
      'available': method == 'observe',
      'limitation': 'The browser document changed.',
    };
  }

  @override
  Future<void> close() async {}
}

class _SessionBackend implements UnixRegionBackend, UnixCaptureSession {
  bool fail = false;
  int releases = 0;
  @override
  Future<List<CapturedDisplay>> captureDisplays() async {
    if (fail) throw StateError('Screen sharing disconnected.');
    return [await display()];
  }

  @override
  Future<Map<String, Object?>> observe(Rect bounds) async =>
      throw StateError('Source disconnected.');
  @override
  Future<void> release() async {
    releases++;
  }

  @override
  Future<void> close() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Wayland accepts sparse one-level RGB rounding but rejects content changes', () async {
    Future<String> png(int count, int delta) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(Colors.white, BlendMode.src);
      canvas.drawRect(
        Rect.fromLTWH(0, 0, count.toDouble(), 1),
        Paint()
          ..isAntiAlias = false
          ..color = Color.fromARGB(255, 255 - delta, 255, 255),
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(100, 80);
      try {
        final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        return 'data:image/png;base64,${base64Encode(data.buffer.asUint8List())}';
      } finally {
        image.dispose();
        picture.dispose();
      }
    }

    final original = await png(0, 0);
    final noise = await png(10, 1);
    expect(await sameCapturedPixels(original, noise), isFalse);
    expect(
      await sameCapturedPixels(original, noise, allowRoundingNoise: true),
      isTrue,
    );
    expect(
      await sameCapturedPixels(
        original,
        await png(10, 2),
        allowRoundingNoise: true,
      ),
      isFalse,
    );
    expect(
      await sameCapturedPixels(
        original,
        await png(21, 1),
        allowRoundingNoise: true,
      ),
      isFalse,
    );
  });
  test(
    'capture releases sharing after cancellation and failure, then can retry',
    () async {
      final backend = _SessionBackend();
      final provider = UnixCaptureProvider(
        backend: backend,
        browser: _ChangingBrowser(),
        editor: (_) async => [],
      );
      addTearDown(provider.close);
      expect(await provider.selectContext(), isEmpty);
      expect(backend.releases, 1);
      backend.fail = true;
      await expectLater(provider.selectContext(), throwsStateError);
      expect(backend.releases, 2);
      backend.fail = false;
      expect(await provider.selectContext(), isEmpty);
      expect(backend.releases, 3);
    },
  );
  test(
    'source disconnect retains the frozen annotated image and releases sharing',
    () async {
      final backend = _SessionBackend();
      final provider = UnixCaptureProvider(
        backend: backend,
        browser: _ChangingBrowser(),
        editor: (frames) async {
          final region = SelectedRegion(
            frames.single,
            const Rect.fromLTWH(10, 10, 30, 20),
          );
          region.addStroke(
            RegionStroke(
              tool: RegionDrawingTool.pen,
              color: Colors.blue,
              width: 2,
              points: const [Offset(12, 12), Offset(20, 20)],
            ),
          );
          return [region];
        },
      );
      addTearDown(provider.close);
      final result = (await provider.selectContext()).single.image!;
      expect(result.alignment?['status'], 'image-only');
      expect(
        result.snapshot?['imageAnnotations'],
        containsPair('strokeCount', 1),
      );
      expect(result.dataUrl, startsWith('data:image/png;base64,'));
      expect(backend.releases, 1);
    },
  );
  test('regions keep physical pixels, negative screen origins, limits and independent drawing histories', () async {
    final frame = await display();
    addTearDown(frame.image.dispose);
    final session = RegionSelectionSession([frame]);
    addTearDown(session.dispose);
    expect(session.addRegion(const Rect.fromLTWH(10, 10, 30, 20)), isTrue);
    expect(session.addRegion(const Rect.fromLTWH(10, 10, 30, 20)), isFalse);
    final a = session.selected!;
    expect(frame.screenRect(a.pixels), const Rect.fromLTWH(-45, 25, 15, 10));
    expect(frame.sourceAt(a.pixels), source);
    expect(session.addRegion(const Rect.fromLTWH(50, 10, 30, 20)), isTrue);
    final b = session.selected!;
    a.addStroke(
      RegionStroke(
        tool: RegionDrawingTool.pen,
        color: Colors.red,
        width: 4,
        points: const [Offset(14, 15), Offset(35, 15)],
      ),
    );
    b.addStroke(
      RegionStroke(
        tool: RegionDrawingTool.rectangle,
        color: Colors.blue,
        width: 2,
        points: const [Offset(55, 12), Offset(75, 25)],
      ),
    );
    a.undo();
    expect(a.strokes, isEmpty);
    expect(b.strokes.length, 1);
    a.redo();
    expect(a.strokes.length, 1);
    final original =
        'data:image/png;base64,${base64Encode(await a.render(annotated: false))}';
    final annotated = 'data:image/png;base64,${base64Encode(await a.render())}';
    expect(await sameCapturedPixels(original, annotated), isFalse);
    expect(await sameCapturedPixels(original, original), isTrue);
    expect(
      a.addStroke(
        RegionStroke(
          tool: RegionDrawingTool.pen,
          color: Colors.red,
          width: double.nan,
          points: const [Offset.zero],
        ),
      ),
      isFalse,
    );
    for (var index = 0; index < 6; index++) {
      expect(session.addRegion(Rect.fromLTWH(index * 10.0, 40, 8, 8)), isTrue);
    }
    expect(session.addRegion(const Rect.fromLTWH(70, 40, 8, 8)), isFalse);
    session.finish(cancel: true);
    expect(await session.result, isEmpty);
  });

  test('native context is retained only with unchanged pixels and window identity', () async {
    final frame = await display();
    addTearDown(frame.image.dispose);
    final selected = SelectedRegion(frame, const Rect.fromLTWH(10, 10, 30, 20));
    final image =
        'data:image/png;base64,${base64Encode(await selected.render(annotated: false))}';
    var calls = 0;
    var window = Map<String, Object?>.of(source);
    Future<Map<String, Object?>> observe(Rect bounds) async {
      calls++;
      expect(bounds, const Rect.fromLTWH(-45, 25, 15, 10));
      return {
        'stable': true,
        'source': window,
        'dataUrl': image,
        'regionContext': {
          'elements': [
            {
              'id': 'label',
              'role': 'label',
              'text': 'Observed label',
              'bounds': {'x': 2, 'y': 2, 'width': 10, 'height': 10},
            },
          ],
        },
      };
    }

    final aligned = await enrichSelectedRegion(selected, observe);
    expect(calls, 2);
    expect(aligned.alignment?['status'], 'aligned');
    expect(
      imageAttachmentFromSelection(aligned, 'a').snapshot?['regionContext'],
      isNotNull,
    );
    window['processStartToken'] = 'replacement-process';
    final stale = await enrichSelectedRegion(selected, observe);
    expect(stale.alignment?['status'], 'image-only');
    expect(stale.snapshot?['regionContext'], isNull);
    expect(stale.dataUrl, image);
  });

  test('drawings survive a changed source without attaching newer metadata', () async {
    final frame = await display();
    addTearDown(frame.image.dispose);
    final selected = SelectedRegion(frame, const Rect.fromLTWH(10, 10, 30, 20));
    final frozen =
        'data:image/png;base64,${base64Encode(await selected.render(annotated: false))}';
    selected.addStroke(
      RegionStroke(
        tool: RegionDrawingTool.arrow,
        color: Colors.red,
        width: 4,
        points: const [Offset(12, 12), Offset(30, 25)],
      ),
    );
    final expected =
        'data:image/png;base64,${base64Encode(await selected.render())}';
    final captured = await enrichSelectedRegion(
      selected,
      (_) async => {
        'stable': true,
        'source': source,
        'dataUrl': expected,
        'regionContext': {
          'elements': [
            {'text': 'Newer content'},
          ],
        },
      },
    );
    expect(await sameCapturedPixels(captured.dataUrl, expected), isTrue);
    expect(await sameCapturedPixels(captured.dataUrl, frozen), isFalse);
    final attachment = imageAttachmentFromSelection(captured, 'drawn');
    expect(attachment.snapshot?['regionContext'], isNull);
    expect(
      attachment.snapshot?['imageAnnotations'],
      containsPair('strokeCount', 1),
    );
    expect(
      attachment.snapshot?['region'],
      containsPair('status', 'image-only'),
    );
  });

  testWidgets('capture above the shell supports tool hover and stroke menu', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final frame = (await tester.runAsync(display))!;
    addTearDown(frame.image.dispose);
    final session = RegionSelectionSession([frame]);
    addTearDown(session.dispose);
    var finished = false;
    session.result.then((_) => finished = true);
    session.addRegion(const Rect.fromLTWH(10, 10, 30, 20));
    await tester.pumpWidget(
      MaterialApp(
        home: const SizedBox(),
        builder: (context, child) => Stack(
          children: [
            child!,
            Positioned.fill(child: RegionCaptureOverlay(session: session)),
          ],
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    for (final label in [
      'Pen (P)',
      'Arrow (A)',
      'Rectangle (R)',
      'Ellipse (O)',
      'Highlighter (H)',
      'Delete region',
    ]) {
      await mouse.moveTo(tester.getCenter(find.byTooltip(label)));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('region-capture-canvas')),
        findsOneWidget,
      );
      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const ValueKey('stroke-width-menu')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(MenuItemButton, '16 px'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('region-capture-canvas')), findsOneWidget);
    expect(find.widgetWithText(MenuItemButton, '16 px'), findsNothing);
    expect(session.regions, hasLength(1));
    expect(
      finished,
      isFalse,
      reason: "Escape in the menu must not finish capture",
    );
    await tester.tap(find.byKey(const ValueKey('stroke-width-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('16 px').last);
    await tester.pumpAndSettle();
    expect(session.strokeWidth, 16);
    await mouse.moveTo(tester.getCenter(find.byTooltip('Pen (P)')));
    await tester.pump(const Duration(seconds: 1));
    await mouse.down(tester.getCenter(find.byTooltip('Pen (P)')));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(session.tool, RegionDrawingTool.pen);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'shared editor supports selection, drawing, undo, redo and attach',
    (tester) async {
      final frame = await tester.runAsync(display);
      addTearDown(frame!.image.dispose);
      final session = RegionSelectionSession([frame]);
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(home: RegionCaptureEditor(session: session)),
      );
      final canvas = find.byKey(const ValueKey('region-capture-canvas'));
      final area = tester.getRect(canvas);
      final start = area.center - const Offset(90, 50);
      final gesture = await tester.startGesture(start);
      await gesture.moveBy(const Offset(180, 100));
      await gesture.up();
      await tester.pump();
      expect(session.regions.length, 1);
      expect(find.text('A'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.pump();
      expect(session.tool, RegionDrawingTool.pen);
      final pen = await tester.startGesture(area.center - const Offset(20, 10));
      await pen.moveBy(const Offset(35, 15));
      await pen.up();
      await tester.pump();
      expect(session.selected!.strokes.length, 1);
      expect(session.selected!.strokes.single.color, const Color(0xffff686b));
      final red = (await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(
          await session.selected!.render(),
        );
        final image = (await codec.getNextFrame()).image;
        try {
          final rgba = (await image.toByteData())!.buffer.asUint8List();
          return [
            for (var i = 0; i < rgba.length; i += 4)
              if (rgba[i] == 255 && rgba[i + 1] == 104 && rgba[i + 2] == 107) i,
          ];
        } finally {
          image.dispose();
          codec.dispose();
        }
      }))!;
      expect(
        red,
        isNotEmpty,
        reason: 'The exported crop must contain the default red stroke.',
      );
      await tester.tap(find.byTooltip('Undo'));
      await tester.pump();
      expect(session.selected!.strokes, isEmpty);
      await tester.tap(find.byTooltip('Redo'));
      await tester.pump();
      expect(session.selected!.strokes.length, 1);
      await tester.tap(find.text('Attach'));
      await tester.pump();
      expect(await session.result, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('toolbar follows the selected crop and stays within the canvas', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final frame = (await tester.runAsync(display))!;
    final otherDisplay = (await tester.runAsync(display))!;
    addTearDown(frame.image.dispose);
    addTearDown(otherDisplay.image.dispose);
    final session = RegionSelectionSession([frame, otherDisplay]);
    addTearDown(session.dispose);
    session.addRegion(const Rect.fromLTWH(10, 10, 20, 10));
    await tester.pumpWidget(
      MaterialApp(home: RegionCaptureEditor(session: session)),
    );
    final canvas = find.byKey(const ValueKey('region-capture-canvas'));
    final toolbar = find.byKey(
      const ValueKey('region-drawing-toolbar-viewport'),
    );
    Rect crop() {
      final area = tester.getRect(canvas);
      final fitted = applyBoxFit(BoxFit.contain, frame.pixels.size, area.size);
      final image = Alignment.center.inscribe(fitted.destination, area);
      final pixels = session.selected!.pixels;
      final scale = image.width / frame.image.width;
      return Rect.fromLTWH(
        image.left + pixels.left * scale,
        image.top + pixels.top * scale,
        pixels.width * scale,
        pixels.height * scale,
      );
    }

    final first = tester.getRect(toolbar);
    expect(first.left, closeTo(crop().left, .01));
    expect(first.top, closeTo(crop().bottom + 12, .01));
    session.addRegion(const Rect.fromLTWH(70, 65, 20, 10));
    await tester.pump();
    final second = tester.getRect(toolbar);
    expect(second, isNot(first));
    expect(second.bottom, closeTo(crop().top - 12, .01));
    expect(tester.getRect(canvas).contains(second.topLeft), isTrue);
    expect(tester.getRect(canvas).contains(second.bottomRight), isTrue);
    await tester.tap(find.widgetWithText(ChoiceChip, 'A'));
    await tester.pump();
    expect(tester.getRect(toolbar), first);
    session.change(() => session.displayIndex = 1);
    session.addRegion(const Rect.fromLTWH(40, 40, 20, 10));
    await tester.pump();
    session.removeSelected();
    await tester.pump();
    expect(session.displayIndex, 0);
    expect(tester.getRect(toolbar), second);
    // Palette selection survives switching regions, and toolbar taps never
    // create another selection through the canvas underneath.
    await tester.tap(find.byTooltip('Drawing color ff2196f3'));
    await tester.pump();
    session.select(0);
    await tester.pump();
    expect(session.color, Colors.blue);
    expect(session.regions, hasLength(2));
    await tester.binding.setSurfaceSize(const Size(400, 320));
    await tester.pumpAndSettle();
    final compact = tester.getRect(toolbar);
    expect(tester.getRect(canvas).contains(compact.topLeft), isTrue);
    expect(tester.getRect(canvas).contains(compact.bottomRight), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('closing keys release before the editor gives up its window', (
    tester,
  ) async {
    final frame = (await tester.runAsync(display))!;
    addTearDown(frame.image.dispose);
    for (final key in [
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.escape,
      LogicalKeyboardKey.enter,
    ]) {
      final session = RegionSelectionSession([frame]);
      session.addRegion(const Rect.fromLTWH(10, 10, 30, 20));
      var finished = false;
      session.result.then((_) => finished = true);
      await tester.pumpWidget(
        MaterialApp(home: RegionCaptureEditor(session: session)),
      );
      await tester.sendKeyDownEvent(key);
      await tester.pump();
      expect(finished, isFalse);
      await tester.sendKeyUpEvent(key);
      await tester.pump();
      expect(finished, isTrue);
      expect(
        HardwareKeyboard.instance.logicalKeysPressed,
        isNot(contains(key)),
      );
      expect(
        await session.result,
        key == LogicalKeyboardKey.escape ? isEmpty : hasLength(1),
      );
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    }
  });

  test('failed DOM confirmation discards all semantic metadata and releases the host', () async {
    final frame = await display();
    addTearDown(frame.image.dispose);
    final region = SelectedRegion(frame, const Rect.fromLTWH(10, 10, 30, 20));
    final png =
        'data:image/png;base64,${base64Encode(await region.render(annotated: false))}';
    final browser = _ChangingBrowser();
    final result = await enrichSelectedRegion(
      region,
      (_) async => {
        'stable': true,
        'source': source,
        'dataUrl': png,
        'browserViewport': source['bounds'],
        'regionContext': {
          'elements': [
            {'text': 'Native fallback'},
          ],
        },
      },
      browser: browser,
    );
    expect(result.alignment?['status'], 'image-only');
    expect(result.snapshot?['regionContext'], isNull);
    expect(result.snapshot?['dom'], isNull);
    expect(result.dataUrl, png);
    expect(browser.methods, ['observe', 'confirm', 'release']);
  });
}
