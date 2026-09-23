import 'package:flutter/material.dart';

class RuntimeLogo extends StatelessWidget {
  const RuntimeLogo({required this.runtimeId, this.size = 14, super.key});

  final String runtimeId;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (runtimeId == 'grok') {
      return Icon(Icons.auto_awesome_rounded, size: size);
    }
    const brands = {'codex', 'hermes', 'pi', 'openclaw', 'opencode', 'claude'};
    return brands.contains(runtimeId)
        ? Image.asset(
            'assets/runtime_icons/$runtimeId.png',
            width: size,
            height: size,
            excludeFromSemantics: true,
            // Monochrome marks need a light foreground on dark rows.
            color:
                (runtimeId == 'codex' ||
                        runtimeId == 'pi' ||
                        runtimeId == 'opencode') &&
                    Theme.of(context).brightness == Brightness.dark
                ? Theme.of(context).colorScheme.onSurface
                : null,
            filterQuality: FilterQuality.medium,
          )
        : Icon(Icons.terminal_rounded, size: size);
  }
}

/// A rounded window with the sessions pane on its left.
class SessionSidebarIcon extends StatelessWidget {
  const SessionSidebarIcon({super.key});

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size.square(18),
    painter: _SidebarPainter(IconTheme.of(context).color ?? Colors.black),
  );
}

class _SidebarPainter extends CustomPainter {
  const _SidebarPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final outline = RRect.fromRectAndRadius(
      bounds.deflate(1),
      const Radius.circular(3.5),
    );
    final divider = size.width * 0.37;
    final paint = Paint()..color = color;
    canvas.save();
    canvas.clipRRect(outline);
    canvas.drawRect(
      Rect.fromLTRB(1, 1, divider, size.height - 1),
      Paint()..color = color.withValues(alpha: 0.12),
    );
    canvas.restore();
    paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    canvas.drawRRect(outline, paint);
    canvas.drawLine(
      Offset(divider, 1),
      Offset(divider, size.height - 1),
      paint,
    );
  }

  @override
  bool shouldRepaint(_SidebarPainter oldDelegate) => color != oldDelegate.color;
}
