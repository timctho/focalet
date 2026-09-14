import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A flowing signal behind the active thinking section. The painter repaints
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
    duration: const Duration(seconds: 6),
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
    Color(0xff28cdeb),
    Color(0xff8472f4),
    Color(0xffed79b5),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final angle = phase.value * math.pi * 2;
    final height = math.min(size.height, 80.0);
    for (var index = 0; index < _colors.length; index++) {
      final offset = angle + index * math.pi * 2 / 3;
      final center = Offset(
        size.width * (.5 + .35 * math.sin(offset)),
        height * (.5 + .2 * math.cos(offset)),
      );
      final bounds = Rect.fromCenter(
        center: center,
        width: size.width * .95,
        height: height * 2.4,
      );
      canvas.drawRect(
        bounds,
        Paint()
          ..shader = RadialGradient(
            colors: [
              _colors[index].withValues(alpha: dark ? .28 : .20),
              _colors[index].withValues(alpha: 0),
            ],
          ).createShader(bounds),
      );
      final wave = Path();
      for (var step = 0; step <= 48; step++) {
        final x = size.width * step / 48;
        final y =
            height *
            (.58 +
                .18 * math.sin(step / 48 * math.pi * 2 + offset) +
                .08 * math.sin(step / 48 * math.pi * 4 - angle));
        if (step == 0) {
          wave.moveTo(x, y);
        } else {
          wave.lineTo(x, y);
        }
      }
      canvas.drawPath(
        wave,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = height * .22
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, height * .15)
          ..color = _colors[index].withValues(alpha: dark ? .36 : .22),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ThinkingFlowPainter oldDelegate) =>
      oldDelegate.dark != dark || oldDelegate.phase != phase;
}
