import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A soft, flowing edge light around the active thinking section. It repaints
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
    duration: const Duration(seconds: 10),
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
              colors: Theme.of(context).colorScheme,
            ),
          ),
        ),
      ),
    ),
  );
}

class _ThinkingFlowPainter extends CustomPainter {
  _ThinkingFlowPainter({required this.phase, required this.colors})
    : super(repaint: phase);

  final Animation<double> phase;
  final ColorScheme colors;
  static const _colors = [
    Color(0xff63b6f5),
    Color(0xff9c8aef),
    Color(0xffdb9acb),
    Color(0xffe7b394),
    Color(0xff9c8aef),
    Color(0xff63b6f5),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final dark = colors.brightness == Brightness.dark;
    final angle = phase.value * math.pi * 2;
    final bounds = Offset.zero & size;
    final outline = RRect.fromRectAndRadius(
      bounds.deflate(1),
      const Radius.circular(9),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(bounds, const Radius.circular(10)),
      Paint()..color = colors.surfaceContainerLow,
    );

    // A moving color field avoids the uneven speed a rotating sweep has on a
    // very wide panel. Sine/cosine keep color and velocity continuous at repeat.
    final gradient = LinearGradient(
      begin: Alignment(-1.8 + .8 * math.sin(angle), -.6),
      end: Alignment(1.8 + .8 * math.cos(angle), .6),
      colors: _colors,
    ).createShader(bounds);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..shader = gradient;

    // Blur only this thin painted edge, never the desktop or transcript. The
    // center stays quiet and legible; no backdrop filter or saveLayer is used.
    canvas.drawRRect(
      outline,
      paint
        ..strokeWidth = 5
        ..color = Colors.white.withValues(alpha: dark ? .24 : .16)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.drawRRect(
      outline,
      paint
        ..strokeWidth = .8
        ..color = Colors.white.withValues(alpha: dark ? .50 : .36)
        ..maskFilter = null,
    );
  }

  @override
  bool shouldRepaint(covariant _ThinkingFlowPainter oldDelegate) =>
      oldDelegate.colors != colors || oldDelegate.phase != phase;
}
