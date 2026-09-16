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
    duration: const Duration(seconds: 8),
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
    : super(repaint: phase);

  final Animation<double> phase;
  final bool dark;
  static const _colors = [
    Color(0xff75c9bc),
    Color(0xffa89ae4),
    Color(0xffdb9fbd),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final angle = phase.value * math.pi * 2;
    final blend = .18 + .14 * math.sin(angle);
    final opacity = (dark ? .30 : .24) + .06 * math.sin(angle);
    final bounds = Offset.zero & size;
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = LinearGradient(
          begin: const Alignment(-1, -.3),
          end: const Alignment(1, .3),
          colors: [
            for (var index = 0; index < _colors.length; index++)
              Color.lerp(
                _colors[index],
                _colors[(index + 1) % _colors.length],
                blend,
              )!.withValues(alpha: index == 1 ? opacity : 0),
          ],
        ).createShader(bounds),
    );
  }

  @override
  bool shouldRepaint(covariant _ThinkingFlowPainter oldDelegate) =>
      oldDelegate.dark != dark || oldDelegate.phase != phase;
}
