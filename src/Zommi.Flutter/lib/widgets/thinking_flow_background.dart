import 'dart:ui' as ui;

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
  Size? _size;
  late RRect _outline;
  late ui.PathMetric _perimeter;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final dark = colors.brightness == Brightness.dark;
    final bounds = Offset.zero & size;
    if (_size != size) {
      _size = size;
      _outline = RRect.fromRectAndRadius(
        bounds.deflate(1),
        const Radius.circular(9),
      );
      _perimeter = (Path()..addRRect(_outline)).computeMetrics().single;
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(bounds, const Radius.circular(10)),
      Paint()..color = colors.surfaceContainerLow,
    );
    canvas.drawRRect(
      _outline,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = .8
        ..color = colors.primary.withValues(alpha: dark ? .12 : .10),
    );

    // Two localized lights visibly travel instead of tinting the whole edge.
    // Distance along the rounded rectangle keeps their speed steady even on a
    // wide, collapsed panel; a closed path makes the repeat seamless.
    final radius = (size.width * .23).clamp(90.0, 220.0);
    for (var light = 0; light < 2; light++) {
      final distance = ((phase.value + light * .5) % 1) * _perimeter.length;
      final center = _perimeter.getTangentForOffset(distance)!.position;
      final color = light == 0
          ? (dark ? const Color(0xff8ccaff) : const Color(0xff4285cf))
          : (dark ? const Color(0xffd3a5f2) : const Color(0xffaa64bb));
      final shader = ui.Gradient.radial(
        center,
        radius,
        [
          Color.lerp(color, Colors.white, dark ? .35 : .08)!,
          color,
          color.withValues(alpha: .45),
          color.withValues(alpha: 0),
        ],
        const [0, .25, .55, 1],
      );
      _paintLight(canvas, shader, dark);
    }
  }

  void _paintLight(Canvas canvas, ui.Shader shader, bool dark) {
    // Blur only the thin painted edge, never the desktop or transcript. The
    // opaque center stays still and legible, without a backdrop filter/layer.
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..shader = shader;
    canvas.drawRRect(
      _outline,
      paint
        ..strokeWidth = 6
        ..color = Colors.white.withValues(alpha: dark ? .48 : .30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawRRect(
      _outline,
      paint
        ..strokeWidth = 1.2
        ..color = Colors.white.withValues(alpha: dark ? .90 : .72)
        ..maskFilter = null,
    );
  }

  @override
  bool shouldRepaint(covariant _ThinkingFlowPainter oldDelegate) =>
      oldDelegate.colors != colors || oldDelegate.phase != phase;
}
