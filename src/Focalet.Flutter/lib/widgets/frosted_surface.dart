import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// An opaque app surface; desktop content cannot affect the panel colors.
class FocaletGlassBackdrop extends StatelessWidget {
  const FocaletGlassBackdrop({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      ColoredBox(color: Theme.of(context).colorScheme.surface, child: child);
}

/// Static tint and highlights give glass depth without animated refraction.
/// Only floating panels blur content behind them; the shell and composer don't.
class FrostedSurface extends StatelessWidget {
  const FrostedSurface({
    required this.child,
    this.radius = 24,
    this.padding = EdgeInsets.zero,
    this.opacity,
    this.color,
    this.blurBackground = true,
    this.showBorder = true,
    this.borderSide,
    super.key,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final double? opacity;
  final Color? color;
  final bool blurBackground;
  final bool showBorder;
  final BorderSide? borderSide;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final tint = color ?? scheme.surface;
    final alpha = opacity ?? (dark ? .66 : .72);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        enabled: blurBackground,
        filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.lerp(
                  tint,
                  Colors.white,
                  dark ? .07 : .12,
                )!.withValues(alpha: alpha),
                tint.withValues(alpha: alpha),
                tint.withValues(alpha: (alpha - .12).clamp(0, 1)),
              ],
              stops: const [0, .4, 1],
            ),
            border: showBorder
                ? Border.fromBorderSide(
                    borderSide ??
                        BorderSide(
                          color: Colors.white.withValues(
                            alpha: dark ? .13 : .65,
                          ),
                        ),
                  )
                : null,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-.85, -1),
                radius: 1.25,
                colors: [
                  Colors.white.withValues(alpha: dark ? .06 : .22),
                  Colors.white.withValues(alpha: 0),
                ],
              ),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: Padding(padding: padding, child: child),
            ),
          ),
        ),
      ),
    );
  }
}
