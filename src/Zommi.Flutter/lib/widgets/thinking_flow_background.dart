import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A soft color glow behind the active thinking section. The painter repaints
/// independently of the transcript, and stops when motion or tickers are off.
class ThinkingFlowBackground extends StatefulWidget {
  const ThinkingFlowBackground({super.key});

  @override
  State<ThinkingFlowBackground> createState() => _ThinkingFlowBackgroundState();
}

class _ThinkingFlowBackgroundState extends State<ThinkingFlowBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _phase = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 12),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _phase.stop();
    } else if (!_phase.isAnimating) {
      _phase.repeat();
    }
  }

  @override
  void dispose() {
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: RepaintBoundary(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: CustomPaint(
            painter: _ThinkingFlowPainter(
              phase: _phase,
              dark: Theme.of(context).brightness == Brightness.dark,
            ),
          ),
        ),
      ),
    ),
  );
}

class _ThinkingFlowPainter extends CustomPainter {
  _ThinkingFlowPainter({required this.phase, required this.dark})
    : _glows = [
        for (final color in _colors)
          RadialGradient(
            radius: .62,
            colors: [
              for (final strength in [1.0, .90, .54, .19, .035, 0.0])
                color.withValues(alpha: strength * (dark ? .24 : .18)),
            ],
            stops: const [0, .2, .4, .6, .8, 1],
          ),
      ],
      super(repaint: phase);

  final Animation<double> phase;
  final bool dark;
  final List<RadialGradient> _glows;
  static const _colors = [
    Color(0xff75c9bc),
    Color(0xffa89ae4),
    Color(0xffdb9fbd),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final angle = phase.value * math.pi * 2;
    const bounds = Rect.fromLTWH(0, 0, 1, 1);
    final paint = Paint();

    // Normalized coordinates stretch the soft radial falloff into broad glows
    // at any panel size, without a blur filter or an offscreen saveLayer.
    canvas.save();
    canvas.scale(size.width, size.height);
    for (var index = 0; index < _glows.length; index++) {
      final orbit = angle + index * math.pi * 2 / _glows.length;
      final center = Offset(
        .18 + index * .32 + .13 * math.sin(orbit),
        .50 + .16 * math.cos(orbit),
      );
      // Sine/cosine preserve position and velocity at the loop boundary.
      // Constant opacity avoids a distracting pulse as the colors drift.
      paint.shader = _glows[index].createShader(
        bounds.shift(center - const Offset(.5, .5)),
      );
      canvas.drawRect(bounds, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ThinkingFlowPainter oldDelegate) =>
      oldDelegate.dark != dark || oldDelegate.phase != phase;
}
