import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Two soft lights chase clockwise around the active thinking section. It repaints
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
      final rect = bounds.deflate(1);
      final r = rect.shortestSide.clamp(0.0, 18.0) / 2;
      final corner = Radius.circular(r);
      _outline = RRect.fromRectAndRadius(rect, corner);
      // Explicitly follow top → right → bottom → left in screen coordinates.
      _perimeter =
          (Path()
                ..moveTo(rect.left + r, rect.top)
                ..lineTo(rect.right - r, rect.top)
                ..arcToPoint(Offset(rect.right, rect.top + r), radius: corner)
                ..lineTo(rect.right, rect.bottom - r)
                ..arcToPoint(
                  Offset(rect.right - r, rect.bottom),
                  radius: corner,
                )
                ..lineTo(rect.left + r, rect.bottom)
                ..arcToPoint(Offset(rect.left, rect.bottom - r), radius: corner)
                ..lineTo(rect.left, rect.top + r)
                ..arcToPoint(Offset(rect.left + r, rect.top), radius: corner)
                ..close())
              .computeMetrics()
              .single;
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

    // Keep a bright leading edge and a fading tail behind each light. Painting
    // only that trailing path makes the direction clear even on a short panel.
    final radius = (size.width * .30).clamp(120.0, 280.0);
    final tailLength = radius.clamp(0.0, _perimeter.length * .24);
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
      final trail = Path();
      final start = distance - tailLength;
      if (start < 0) {
        trail.addPath(
          _perimeter.extractPath(_perimeter.length + start, _perimeter.length),
          Offset.zero,
        );
      }
      trail.extendWithPath(
        _perimeter.extractPath(start.clamp(0.0, _perimeter.length), distance),
        Offset.zero,
      );
      _paintLight(canvas, trail, shader, dark);
    }
  }

  void _paintLight(Canvas canvas, Path trail, ui.Shader shader, bool dark) {
    // Blur only the thin painted edge, never the desktop or transcript. The
    // opaque center stays still and legible, without a backdrop filter/layer.
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..shader = shader;
    canvas.drawPath(
      trail,
      paint
        ..strokeWidth = 6
        ..color = Colors.white.withValues(alpha: dark ? .48 : .30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawPath(
      trail,
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
