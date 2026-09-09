import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Opt-in release/profile instrumentation. No message text or images are logged.
/// Samples stay in memory until scrolling has stopped, avoiding hot-path I/O.
final class ScrollPerformance {
  ScrollPerformance._(this.path);

  static ScrollPerformance? _instance;
  final String path;
  final List<ui.FrameTiming> _frames = [];
  final List<int> _inputs = [];
  final Map<String, int> _counts = {};
  final Map<String, int> _costs = {};
  Timer? _idle;
  bool _ready = false;
  double? _firstOffset;
  double? _lastOffset;
  double _travel = 0;
  int _sequence = 0;

  static bool get enabled => _instance != null;

  static void initialize() {
    final path = Platform.environment['ZOMMI_SCROLL_TRACE']?.trim();
    if (path == null || path.isEmpty || _instance != null) return;
    final recorder = _instance = ScrollPerformance._(path);
    SchedulerBinding.instance.addTimingsCallback(recorder._onFrames);
  }

  static void ready(int turns) {
    final recorder = _instance;
    if (recorder == null || recorder._ready || turns == 0) return;
    recorder._ready = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      recorder._write({
        'event': 'ready',
        'mode': kReleaseMode
            ? 'release'
            : kProfileMode
            ? 'profile'
            : 'debug',
        'turns': turns,
        'physicalWidth': view.physicalSize.width,
        'physicalHeight': view.physicalSize.height,
        'devicePixelRatio': view.devicePixelRatio,
      });
    });
  }

  static void count(String name) {
    final recorder = _instance;
    if (recorder == null || recorder._inputs.isEmpty) return;
    recorder._counts.update(name, (value) => value + 1, ifAbsent: () => 1);
  }

  static T measure<T>(String name, T Function() operation) {
    final recorder = _instance;
    if (recorder == null || recorder._inputs.isEmpty) return operation();
    final watch = Stopwatch()..start();
    try {
      return operation();
    } finally {
      recorder._costs.update(
        name,
        (value) => value + watch.elapsedMicroseconds,
        ifAbsent: () => watch.elapsedMicroseconds,
      );
    }
  }

  void _input(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    _inputs.add(DateTime.now().microsecondsSinceEpoch);
    _idle?.cancel();
    // FrameTiming callbacks are batched by the engine. Leave time for the last
    // raster result before serializing a sample, outside the scrolling interval.
    _idle = Timer(const Duration(milliseconds: 900), _flush);
  }

  void _onFrames(List<ui.FrameTiming> timings) {
    if (_inputs.isNotEmpty) _frames.addAll(timings);
  }

  bool _scroll(ScrollNotification notification) {
    if (_inputs.isEmpty || notification.depth != 0) return false;
    final offset = notification.metrics.pixels;
    _firstOffset ??= offset;
    if (_lastOffset case final previous?) _travel += (offset - previous).abs();
    _lastOffset = offset;
    return false;
  }

  void _flush() {
    if (_inputs.isEmpty) return;
    final start = _inputs.first;
    final end = _inputs.last + 250000;
    final frames = _frames.where((frame) {
      final finish = frame.timestampInMicroseconds(
        ui.FramePhase.rasterFinishWallTime,
      );
      return finish >= start && finish <= end;
    }).toList();
    final latencies = <int>[];
    for (final input in _inputs) {
      for (final frame in frames) {
        final finish = frame.timestampInMicroseconds(
          ui.FramePhase.rasterFinishWallTime,
        );
        final buildStart =
            finish -
            (frame.timestampInMicroseconds(ui.FramePhase.rasterFinish) -
                frame.timestampInMicroseconds(ui.FramePhase.buildStart));
        if (buildStart >= input) {
          latencies.add(finish - input);
          break;
        }
      }
    }
    _write({
      'event': 'scroll',
      'sample': ++_sequence,
      'inputCount': _inputs.length,
      'durationUs': _inputs.last - start,
      'frameCount': frames.length,
      'buildUs': frames
          .map((frame) => frame.buildDuration.inMicroseconds)
          .toList(),
      'rasterUs': frames
          .map((frame) => frame.rasterDuration.inMicroseconds)
          .toList(),
      'totalUs': frames.map((frame) => frame.totalSpan.inMicroseconds).toList(),
      // Receipt in Flutter to a subsequent frame's raster completion. This
      // excludes OS dispatch before receipt and display presentation afterward.
      'receiptToRasterUs': latencies,
      'firstOffset': _firstOffset,
      'lastOffset': _lastOffset,
      'travel': _travel,
      'counts': Map.of(_counts),
      'costUs': Map.of(_costs),
    });
    _frames.clear();
    _inputs.clear();
    _counts.clear();
    _costs.clear();
    _firstOffset = _lastOffset = null;
    _travel = 0;
  }

  void _write(Map<String, Object?> event) {
    unawaited(
      File(path).writeAsString('${jsonEncode(event)}\n', mode: FileMode.append),
    );
  }
}

class ScrollPerformanceBoundary extends StatelessWidget {
  const ScrollPerformanceBoundary({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final recorder = ScrollPerformance._instance;
    if (recorder == null) return child;
    return Listener(
      onPointerSignal: recorder._input,
      child: NotificationListener<ScrollNotification>(
        onNotification: recorder._scroll,
        child: child,
      ),
    );
  }
}
