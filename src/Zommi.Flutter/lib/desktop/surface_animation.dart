import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

abstract interface class DesktopSurfaceAnimator {
  SurfaceAnimationController get surfaceAnimation;
}

final class SurfaceAnimationController extends ValueNotifier<Rect?> {
  SurfaceAnimationController() : super(null);

  final frameKey = GlobalKey();

  Future<void> handleNativeFrameRequest(MethodCall call) async {
    if (call.method != 'renderSurfaceFrame') throw MissingPluginException();
    WidgetsBinding.instance.scheduleForcedFrame();
  }

  Future<({int width, int height, Uint8List rgba})> captureFrame({
    required double pixelRatio,
  }) async {
    await WidgetsBinding.instance.endOfFrame;
    final boundary = frameKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) {
      throw StateError('The surface frame is not attached.');
    }
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) throw StateError('The surface frame is unavailable.');
      return (
        width: image.width,
        height: image.height,
        rgba: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    } finally {
      image.dispose();
    }
  }

  Future<void> animate({
    required Rect from,
    required Rect to,
    required bool maximized,
    required Duration duration,
    required double Function(double) ease,
    required Future<void> Function(bool rememberPlacement) freeze,
    required Future<void> Function(Rect bounds, bool maximized) resize,
  }) async {
    final canvas = from.expandToInclude(to);
    final localFrom = from.shift(-canvas.topLeft);
    final localTo = to.shift(-canvas.topLeft);
    await freeze(true);
    value = localFrom;
    try {
      await resize(canvas, false);
      final completed = Completer<void>();
      var elapsed = Duration.zero;
      var previous = Duration.zero;
      late final Ticker ticker;
      ticker = Ticker((timestamp) {
        final delta = timestamp - previous;
        previous = timestamp;
        elapsed += Duration(microseconds: delta.inMicroseconds.clamp(0, 32000));
        final progress = (elapsed.inMicroseconds / duration.inMicroseconds)
            .clamp(0.0, 1.0);
        value = Rect.lerp(localFrom, localTo, ease(progress));
        if (progress == 1) {
          ticker.stop();
          completed.complete();
        }
      });
      try {
        ticker.start();
        await completed.future;
      } finally {
        ticker.dispose();
      }
      await freeze(false);
      value = null;
      await resize(to, maximized);
    } catch (_) {
      value = null;
      await resize(to, maximized);
      rethrow;
    }
  }
}

class SurfaceAnimationHost extends StatelessWidget {
  const SurfaceAnimationHost({
    required this.animation,
    required this.builder,
    super.key,
  });

  final SurfaceAnimationController animation;
  final Widget Function(BuildContext context, Size size) builder;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    key: animation.frameKey,
    child: LayoutBuilder(
      builder: (context, constraints) => ValueListenableBuilder<Rect?>(
        valueListenable: animation,
        builder: (context, bounds, _) {
          final panel = bounds ?? Offset.zero & constraints.biggest;
          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fromRect(
                rect: panel,
                child: builder(context, panel.size),
              ),
            ],
          );
        },
      ),
    ),
  );
}
