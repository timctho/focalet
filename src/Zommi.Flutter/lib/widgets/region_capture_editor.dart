import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/desktop/region_selection.dart';

/// Shared selection and drawing controls for native Ubuntu/macOS screen frames.
/// Capture is mounted above the shell navigator. Its menus and tooltips need
/// their own navigator/overlay so opening one cannot replace the canvas.
class RegionCaptureOverlay extends StatelessWidget {
  const RegionCaptureOverlay({required this.session, super.key});
  final RegionSelectionSession session;

  @override
  Widget build(BuildContext context) => HeroControllerScope.none(
    child: Navigator(
      key: ObjectKey(session),
      onGenerateRoute: (_) => MaterialPageRoute<void>(
        builder: (_) => RegionCaptureEditor(session: session),
      ),
    ),
  );
}

class RegionCaptureEditor extends StatefulWidget {
  const RegionCaptureEditor({required this.session, super.key});
  final RegionSelectionSession session;
  @override
  State<RegionCaptureEditor> createState() => _RegionCaptureEditorState();
}

class _RegionCaptureEditorState extends State<RegionCaptureEditor> {
  final _focus = FocusNode();
  final _controls = <String, GlobalKey>{};
  GlobalKey _control(String name) => _controls.putIfAbsent(name, GlobalKey.new);
  LogicalKeyboardKey? _closingKey;
  LogicalKeyboardKey? _dismissedMenuKey;
  Offset? _start;
  Offset? _end;
  List<Offset> _points = [];
  Rect _imageBounds = Rect.zero;
  Rect? _reportedBounds;
  final _recorder = FileDesktopAcceptanceRecorder.fromEnvironment();
  RegionSelectionSession get session => widget.session;
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  bool _handleKey(KeyEvent event) {
    final key = event.logicalKey;
    if (_dismissedMenuKey == key) {
      if (event is KeyUpEvent) _dismissedMenuKey = null;
      return true;
    }
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      _closingKey = null;
      // This navigator belongs only to capture. Dismiss its popup directly;
      // desktop key routing can otherwise leave the invisible modal barrier
      // consuming the next tool click after Escape.
      if (event is KeyDownEvent && key == LogicalKeyboardKey.escape) {
        _dismissedMenuKey = key;
        navigator.pop();
        return true;
      }
      return false;
    }
    return _key(_focus, event) == KeyEventResult.handled;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    final recorder = _recorder;
    if (recorder != null) {
      unawaited(
        recorder
            .record('capture.editor.closed', {
              'session': identityHashCode(session).toString(),
            })
            .catchError((Object _) {}),
      );
    }
    _focus.dispose();
    super.dispose();
  }

  Offset _pixel(Offset point) {
    final size = session.display.pixels.size;
    return Offset(
      ((point.dx - _imageBounds.left) * size.width / _imageBounds.width).clamp(
        0,
        size.width,
      ),
      ((point.dy - _imageBounds.top) * size.height / _imageBounds.height).clamp(
        0,
        size.height,
      ),
    );
  }

  RegionStroke _stroke() => RegionStroke(
    tool: session.tool,
    color: session.color ?? Theme.of(context).colorScheme.primary,
    width: session.strokeWidth,
    points:
        session.tool == RegionDrawingTool.pen ||
            session.tool == RegionDrawingTool.highlighter
        ? _points
        : [_start!, _end!],
  );
  void _down(PointerDownEvent event) {
    _focus.requestFocus();
    if (!_imageBounds.contains(event.localPosition)) return;
    final point = _pixel(event.localPosition);
    if (session.tool != RegionDrawingTool.select) {
      final hit = session.regions.lastIndexWhere(
        (region) =>
            region.display == session.display && region.pixels.contains(point),
      );
      if (hit < 0) return;
      session.select(hit);
    }
    setState(() {
      _start = _end = point;
      _points = [point];
    });
  }

  void _move(PointerMoveEvent event) {
    if (_start == null) return;
    setState(() {
      _end = _pixel(event.localPosition);
      if (_points.length < 4096) _points.add(_end!);
    });
  }

  void _up(PointerUpEvent event) {
    if (_start == null) return;
    _end = _pixel(event.localPosition);
    if (session.tool == RegionDrawingTool.select) {
      final rect = Rect.fromPoints(_start!, _end!);
      if (!session.addRegion(rect) && rect.width < 4 && rect.height < 4) {
        final hit = session.regions.lastIndexWhere(
          (region) =>
              region.display == session.display &&
              region.pixels.contains(_end!),
        );
        if (hit >= 0) session.select(hit);
      }
    } else {
      session.change(() => session.selected?.addStroke(_stroke()));
    }
    setState(() {
      _start = _end = null;
      _points = [];
    });
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (_start != null) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      // Wait for key-up before hiding the Wayland surface. Otherwise the
      // release goes to the source window and Flutter retains a pressed Enter,
      // turning the next selection's Enter into an ignored repeat event.
      if (event is KeyDownEvent) _closingKey = key;
      if (event is KeyUpEvent) {
        // A menu may consume key-down and disappear before key-up arrives.
        // Only finish for a key press that began in this capture route.
        if (_closingKey != key) return KeyEventResult.ignored;
        _closingKey = null;
        session.finish(cancel: key == LogicalKeyboardKey.escape);
      }
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final shortcuts = HardwareKeyboard.instance;
    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      session.removeSelected();
    } else if ((shortcuts.isControlPressed || shortcuts.isMetaPressed) &&
        key == LogicalKeyboardKey.keyZ) {
      session.change(
        () => shortcuts.isShiftPressed
            ? session.selected?.redo()
            : session.selected?.undo(),
      );
    } else if ((shortcuts.isControlPressed || shortcuts.isMetaPressed) &&
        key == LogicalKeyboardKey.keyY) {
      session.change(() => session.selected?.redo());
    } else {
      final tool = {
        LogicalKeyboardKey.keyS: RegionDrawingTool.select,
        LogicalKeyboardKey.keyP: RegionDrawingTool.pen,
        LogicalKeyboardKey.keyA: RegionDrawingTool.arrow,
        LogicalKeyboardKey.keyR: RegionDrawingTool.rectangle,
        LogicalKeyboardKey.keyO: RegionDrawingTool.ellipse,
        LogicalKeyboardKey.keyH: RegionDrawingTool.highlighter,
      }[key];
      if (tool == null) return KeyEventResult.ignored;
      session.change(() => session.tool = tool);
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) => Material(
      key: const ValueKey('region-capture-editor'),
      color: const Color(0xff101820),
      child: Focus(
        autofocus: true,
        focusNode: _focus,
        child: Column(
          children: [
            Material(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      session.regions.isEmpty
                          ? 'Drag a box to select content'
                          : '${session.regions.length}/8 selected',
                    ),
                    if (session.displays.length > 1)
                      DropdownButton<int>(
                        value: session.displayIndex,
                        items: [
                          for (var i = 0; i < session.displays.length; i++)
                            DropdownMenuItem(
                              value: i,
                              child: Text(session.displays[i].label),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            session.change(() {
                              session.displayIndex = value;
                              session.tool = RegionDrawingTool.select;
                            });
                          }
                        },
                      ),
                    for (var i = 0; i < session.regions.length; i++)
                      ChoiceChip(
                        label: Text(String.fromCharCode(65 + i)),
                        selected: session.selectedIndex == i,
                        onSelected: (_) => session.select(i),
                      ),
                    TextButton(
                      onPressed: () => session.finish(cancel: true),
                      child: const Text('Cancel'),
                    ),
                    FilledButton.icon(
                      onPressed: session.regions.isEmpty
                          ? null
                          : session.finish,
                      icon: const Icon(Icons.check),
                      label: const Text('Attach'),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final fitted = applyBoxFit(
                    BoxFit.contain,
                    session.display.pixels.size,
                    constraints.biggest,
                  );
                  _imageBounds = Alignment.center.inscribe(
                    fitted.destination,
                    Offset.zero & constraints.biggest,
                  );
                  if (_recorder != null && _reportedBounds != _imageBounds) {
                    _reportedBounds = _imageBounds;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      unawaited(_recordCanvas(context));
                    });
                  }
                  return Listener(
                    onPointerDown: _down,
                    onPointerMove: _move,
                    onPointerUp: _up,
                    onPointerCancel: (_) => setState(() {
                      _start = _end = null;
                      _points = [];
                    }),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.precise,
                      child: CustomPaint(
                        key: const ValueKey('region-capture-canvas'),
                        size: constraints.biggest,
                        painter: _RegionPainter(
                          session: session,
                          imageBounds: _imageBounds,
                          accent: Theme.of(context).colorScheme.primary,
                          dragged:
                              _start != null &&
                                  session.tool == RegionDrawingTool.select
                              ? Rect.fromPoints(_start!, _end!)
                              : null,
                          stroke:
                              _start != null &&
                                  session.tool != RegionDrawingTool.select
                              ? _stroke()
                              : null,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Material(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final (tool, icon, label) in const [
                      (
                        RegionDrawingTool.select,
                        Icons.add_box_outlined,
                        'Add region (S)',
                      ),
                      (RegionDrawingTool.pen, Icons.edit_outlined, 'Pen (P)'),
                      (RegionDrawingTool.arrow, Icons.north_east, 'Arrow (A)'),
                      (
                        RegionDrawingTool.rectangle,
                        Icons.crop_square,
                        'Rectangle (R)',
                      ),
                      (
                        RegionDrawingTool.ellipse,
                        Icons.circle_outlined,
                        'Ellipse (O)',
                      ),
                      (
                        RegionDrawingTool.highlighter,
                        Icons.highlight_alt,
                        'Highlighter (H)',
                      ),
                    ])
                      IconButton.filledTonal(
                        key: _control(label),
                        isSelected: session.tool == tool,
                        tooltip: label,
                        onPressed:
                            tool != RegionDrawingTool.select &&
                                session.selected == null
                            ? null
                            : () => session.change(() => session.tool = tool),
                        icon: Icon(icon),
                      ),
                    const SizedBox(width: 8),
                    for (final color in [
                      Theme.of(context).colorScheme.primary,
                      Colors.red,
                      Colors.orange,
                      Colors.green,
                      Colors.blue,
                      Colors.white,
                      Colors.black,
                    ])
                      IconButton(
                        key: _control('color-${color.toARGB32()}'),
                        tooltip:
                            'Drawing color ${color.toARGB32().toRadixString(16)}',
                        onPressed: () =>
                            session.change(() => session.color = color),
                        icon: Icon(
                          (session.color ??
                                      Theme.of(context).colorScheme.primary) ==
                                  color
                              ? Icons.check_circle
                              : Icons.circle,
                          color: color,
                        ),
                      ),
                    DropdownButton<double>(
                      key: _control('Stroke width'),
                      value: session.strokeWidth,
                      items: [
                        for (final width in [2.0, 4.0, 8.0, 16.0])
                          DropdownMenuItem(
                            value: width,
                            child: Text('${width.toInt()} px'),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          session.change(() => session.strokeWidth = value);
                        }
                      },
                    ),
                    IconButton(
                      key: _control('Undo'),
                      tooltip: 'Undo',
                      onPressed: session.selected?.canUndo == true
                          ? () => session.change(() => session.selected!.undo())
                          : null,
                      icon: const Icon(Icons.undo),
                    ),
                    IconButton(
                      key: _control('Redo'),
                      tooltip: 'Redo',
                      onPressed: session.selected?.canRedo == true
                          ? () => session.change(() => session.selected!.redo())
                          : null,
                      icon: const Icon(Icons.redo),
                    ),
                    IconButton(
                      key: _control('Delete region'),
                      tooltip: 'Delete region',
                      onPressed: session.selected == null
                          ? null
                          : session.removeSelected,
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  Future<void> _recordCanvas(BuildContext context) async {
    try {
      final box = context.findRenderObject() as RenderBox;
      final local = box.localToGlobal(_imageBounds.topLeft);
      final position = await windowManager.getPosition();
      if (!mounted) return;
      await _recorder?.record('capture.editor.ready', {
        'session': identityHashCode(session).toString(),
        'bounds': regionRectJson((local + position) & _imageBounds.size),
        'localBounds': regionRectJson(local & _imageBounds.size),
        'controls': {
          for (final entry in _controls.entries)
            if (entry.value.currentContext?.findRenderObject()
                case final RenderBox control)
              entry.key: regionRectJson(
                control.localToGlobal(Offset.zero) & control.size,
              ),
        },
        'imageWidth': session.display.image.width,
        'imageHeight': session.display.image.height,
      });
    } on Object {
      // Optional diagnostics must never prevent selection or recovery.
    }
  }
}

class _RegionPainter extends CustomPainter {
  _RegionPainter({
    required this.session,
    required this.imageBounds,
    required this.accent,
    this.dragged,
    this.stroke,
  });
  final RegionSelectionSession session;
  final Rect imageBounds;
  final Color accent;
  final Rect? dragged;
  final RegionStroke? stroke;
  @override
  void paint(Canvas canvas, Size size) {
    final display = session.display;
    canvas.save();
    canvas.translate(imageBounds.left, imageBounds.top);
    final scale = imageBounds.width / display.image.width;
    canvas.scale(scale);
    canvas.drawImage(display.image, Offset.zero, Paint());
    canvas.drawRect(display.pixels, Paint()..color = const Color(0x55000000));
    for (var index = 0; index < session.regions.length; index++) {
      final region = session.regions[index];
      if (region.display != display) continue;
      canvas.save();
      canvas.clipRect(region.pixels);
      canvas.drawImage(display.image, Offset.zero, Paint());
      for (final mark in region.strokes) {
        drawRegionStroke(canvas, mark);
      }
      if (region == session.selected && stroke != null) {
        drawRegionStroke(canvas, stroke!);
      }
      canvas.restore();
      canvas.drawRect(
        region.pixels,
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = (index == session.selectedIndex ? 3 : 2) / scale,
      );
      final label = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(65 + index),
          style: TextStyle(
            color: Colors.white,
            backgroundColor: accent,
            fontSize: 20 / scale,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, region.pixels.topLeft);
    }
    if (dragged != null) {
      canvas.drawRect(
        dragged!,
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 / scale,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RegionPainter oldDelegate) => true;
}
