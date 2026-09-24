import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

enum RegionDrawingTool { select, pen, arrow, rectangle, ellipse, highlighter }

/// Pixels and window identities are frozen before the editor is presented.
final class CapturedDisplay {
  CapturedDisplay({
    required this.image,
    required this.bounds,
    required this.windows,
    required this.observedAt,
    this.label = 'Desktop',
    this.screenCoordinatesKnown = true,
  });

  final ui.Image image;
  final Rect bounds;
  final List<Map<String, Object?>> windows;
  final DateTime observedAt;
  final String label;
  final bool screenCoordinatesKnown;
  Rect get pixels =>
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());

  Rect screenRect(Rect pixels) => Rect.fromLTWH(
    bounds.left + pixels.left * bounds.width / image.width,
    bounds.top + pixels.top * bounds.height / image.height,
    pixels.width * bounds.width / image.width,
    pixels.height * bounds.height / image.height,
  );

  Map<String, Object?>? sourceAt(Rect pixels) {
    if (!screenCoordinatesKnown) return null;
    final region = screenRect(pixels);
    // Windows are in front-to-back order. Any foreground overlap prevents
    // borrowing metadata from a covered window behind it.
    for (final window in windows) {
      final bounds = regionRect(window['bounds']);
      if (!bounds.overlaps(region)) continue;
      return window['obstruction'] != true && bounds.intersect(region) == region
          ? window
          : null;
    }
    return null;
  }
}

Rect regionRect(Object? value) {
  if (value is! Map) return Rect.zero;
  double number(String key) => (value[key] as num?)?.toDouble() ?? 0;
  return Rect.fromLTWH(
    number('x'),
    number('y'),
    number('width'),
    number('height'),
  );
}

Map<String, double> regionRectJson(Rect value) => {
  'x': value.left,
  'y': value.top,
  'width': value.width,
  'height': value.height,
};

final class RegionStroke {
  RegionStroke({
    required this.tool,
    required this.color,
    required this.width,
    required List<Offset> points,
  }) : points = List.unmodifiable(points);
  final RegionDrawingTool tool;
  final Color color;
  final double width;
  final List<Offset> points;
}

final class SelectedRegion {
  SelectedRegion(this.display, this.pixels);
  final CapturedDisplay display;
  final Rect pixels;
  final List<RegionStroke> _strokes = [];
  final List<RegionStroke> _undone = [];
  List<RegionStroke> get strokes => List.unmodifiable(_strokes);
  bool get canUndo => _strokes.isNotEmpty;
  bool get canRedo => _undone.isNotEmpty;

  bool addStroke(RegionStroke stroke) {
    if (_strokes.length >= 256 ||
        stroke.points.isEmpty ||
        stroke.points.length > 4096 ||
        !stroke.width.isFinite ||
        stroke.width <= 0 ||
        stroke.width > 64 ||
        stroke.tool == RegionDrawingTool.select ||
        stroke.points.any(
          (point) => !point.dx.isFinite || !point.dy.isFinite,
        )) {
      return false;
    }
    if (stroke.tool != RegionDrawingTool.pen &&
        stroke.tool != RegionDrawingTool.highlighter &&
        (stroke.points.length != 2 ||
            stroke.points.first == stroke.points.last)) {
      return false;
    }
    _strokes.add(stroke);
    _undone.clear();
    return true;
  }

  void undo() {
    if (canUndo) _undone.add(_strokes.removeLast());
  }

  void redo() {
    if (canRedo) _strokes.add(_undone.removeLast());
  }

  Future<Uint8List> render({bool annotated = true}) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final size = pixels.size;
    canvas.clipRect(Offset.zero & size);
    canvas.drawImageRect(display.image, pixels, Offset.zero & size, Paint());
    if (annotated) {
      canvas.translate(-pixels.left, -pixels.top);
      for (final stroke in _strokes) {
        drawRegionStroke(canvas, stroke);
      }
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      size.width.round(),
      size.height.round(),
    );
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        throw StateError('Could not encode the selected image.');
      }
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image.dispose();
      picture.dispose();
    }
  }

  Map<String, Object?> get annotationInfo => {
    'version': 1,
    'source': 'user',
    'bakedIntoImage': true,
    'coordinateSpace': 'image-pixels',
    'strokeCount': _strokes.length,
    'tools': _strokes.map((stroke) => stroke.tool.name).toSet().toList(),
  };
}

void drawRegionStroke(Canvas canvas, RegionStroke stroke) {
  if (stroke.points.isEmpty) return;
  final paint = Paint()
    ..color = stroke.tool == RegionDrawingTool.highlighter
        ? stroke.color.withValues(alpha: .3)
        : stroke.color
    ..strokeWidth = stroke.width
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final start = stroke.points.first;
  final end = stroke.points.last;
  final path = Path()..moveTo(start.dx, start.dy);
  switch (stroke.tool) {
    case RegionDrawingTool.select:
      return;
    case RegionDrawingTool.rectangle:
      canvas.drawRect(Rect.fromPoints(start, end), paint);
      return;
    case RegionDrawingTool.ellipse:
      canvas.drawOval(Rect.fromPoints(start, end), paint);
      return;
    case RegionDrawingTool.arrow:
      path.lineTo(end.dx, end.dy);
      final delta = end - start;
      if (delta.distance > 0) {
        final unit = delta / delta.distance;
        final length = (stroke.width * 4).clamp(12.0, 40.0);
        final base = end - unit * length;
        final wing = Offset(-unit.dy, unit.dx) * length * .45;
        path.moveTo((base + wing).dx, (base + wing).dy);
        path.lineTo(end.dx, end.dy);
        path.lineTo((base - wing).dx, (base - wing).dy);
      }
    case RegionDrawingTool.pen:
    case RegionDrawingTool.highlighter:
      if (stroke.points.length == 1) {
        canvas.drawCircle(
          start,
          stroke.width / 2,
          paint..style = PaintingStyle.fill,
        );
        return;
      }
      for (final point in stroke.points.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
  }
  canvas.drawPath(path, paint);
}

final class RegionSelectionSession extends ChangeNotifier {
  RegionSelectionSession(this.displays);
  final List<CapturedDisplay> displays;
  final List<SelectedRegion> regions = [];
  final Completer<List<SelectedRegion>> _result = Completer();
  Future<List<SelectedRegion>> get result => _result.future;
  int displayIndex = 0;
  int selectedIndex = -1;
  RegionDrawingTool tool = RegionDrawingTool.select;
  Color? color;
  double strokeWidth = 4;
  SelectedRegion? get selected =>
      selectedIndex >= 0 && selectedIndex < regions.length
      ? regions[selectedIndex]
      : null;
  CapturedDisplay get display => displays[displayIndex];

  bool addRegion(Rect rect) {
    final clipped = rect.intersect(display.pixels);
    if (clipped.isEmpty || regions.length >= 8) return false;
    final pixels = Rect.fromLTRB(
      clipped.left.floorToDouble(),
      clipped.top.floorToDouble(),
      clipped.right.ceilToDouble(),
      clipped.bottom.ceilToDouble(),
    );
    if (pixels.width < 4 ||
        pixels.height < 4 ||
        regions.any(
          (item) => item.display == display && item.pixels == pixels,
        )) {
      return false;
    }
    regions.add(SelectedRegion(display, pixels));
    selectedIndex = regions.length - 1;
    notifyListeners();
    return true;
  }

  void select(int index) {
    selectedIndex = index;
    displayIndex = displays.indexOf(regions[index].display);
    notifyListeners();
  }

  void removeSelected() {
    if (selected == null) return;
    regions.removeAt(selectedIndex);
    selectedIndex = regions.isEmpty
        ? -1
        : (selectedIndex - 1).clamp(0, regions.length - 1);
    notifyListeners();
  }

  void change(void Function() update) {
    update();
    notifyListeners();
  }

  void finish({bool cancel = false}) {
    if (!_result.isCompleted && (cancel || regions.isNotEmpty)) {
      _result.complete(cancel ? const [] : List.unmodifiable(regions));
    }
  }
}

final activeRegionSelection = ValueNotifier<RegionSelectionSession?>(null);
