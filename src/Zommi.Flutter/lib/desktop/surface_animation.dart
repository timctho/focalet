import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

abstract interface class DesktopSurfaceAnimator {
  SurfaceAnimationController get surfaceAnimation;
}

final class SurfaceAnimationController extends ValueNotifier<Rect?> {
  SurfaceAnimationController() : super(null);

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
        await WidgetsBinding.instance.endOfFrame;
        await WidgetsBinding.instance.endOfFrame;
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
  Widget build(BuildContext context) => LayoutBuilder(
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
  );
}
