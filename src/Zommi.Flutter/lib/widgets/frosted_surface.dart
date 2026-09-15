import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// A static, softly lit backdrop. Messages scroll above this single layer.
class ZommiGlassBackdrop extends StatelessWidget {
  const ZommiGlassBackdrop({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? [
                  const Color(0xff515f7e),
                  const Color(0xff373950),
                  const Color(0xff242936),
                ]
              : [
                  const Color(0xffdce6fa),
                  const Color(0xffeeebfa),
                  const Color(0xffe4edf2),
                ],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(.9, -.85),
                    radius: 1.15,
                    colors: [
                      scheme.primary.withValues(alpha: dark ? .28 : .14),
                      scheme.primary.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// Blur only bounded chrome surfaces, never individual transcript rows.
class FrostedSurface extends StatelessWidget {
  const FrostedSurface({
    required this.child,
    this.radius = 24,
    this.padding = EdgeInsets.zero,
    this.opacity,
    this.blurBackground = true,
    super.key,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final double? opacity;
  final bool blurBackground;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final tint = scheme.surface;
    final alpha = opacity ?? (dark ? .66 : .72);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        enabled: blurBackground,
        filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                tint.withValues(alpha: alpha),
                tint.withValues(alpha: (alpha - .12).clamp(0, 1)),
              ],
            ),
            border: Border.all(
              color: Colors.white.withValues(alpha: dark ? .13 : .65),
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}
