import 'dart:math' as math;

import 'package:flutter/widgets.dart';

class ContextPreviewLayout extends SingleChildLayoutDelegate {
  ContextPreviewLayout({required this.anchorRect});

  final Rect anchorRect;
  static const gap = 8.0;
  static const margin = 8.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final anchor = anchorRect;
    final width = math.min(
      380.0,
      math.max(0.0, constraints.maxWidth - margin * 2),
    );
    final availableHeight = math.max(0.0, constraints.maxHeight - margin * 2);
    final fitsBeside =
        anchor.right + gap + width <= constraints.maxWidth - margin ||
        anchor.left - gap - width >= margin;
    final height = fitsBeside
        ? availableHeight
        : math.min(
            availableHeight,
            math.max(
              0.0,
              math.max(
                anchor.top - gap - margin,
                constraints.maxHeight - margin - anchor.bottom - gap,
              ),
            ),
          );
    return BoxConstraints(maxWidth: width, maxHeight: math.min(430.0, height));
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final anchor = anchorRect;
    final maximumLeft = math.max(margin, size.width - margin - childSize.width);
    final maximumTop = math.max(
      margin,
      size.height - margin - childSize.height,
    );
    final alignedTop = anchor.top.clamp(margin, maximumTop);
    if (anchor.right + gap + childSize.width <= size.width - margin) {
      return Offset(anchor.right + gap, alignedTop);
    }
    if (anchor.left - gap - childSize.width >= margin) {
      return Offset(anchor.left - gap - childSize.width, alignedTop);
    }
    final above = anchor.top - gap - childSize.height;
    final below = anchor.bottom + gap;
    return Offset(
      anchor.left.clamp(margin, maximumLeft),
      (above >= margin ? above : below).clamp(margin, maximumTop),
    );
  }

  @override
  bool shouldRelayout(covariant ContextPreviewLayout oldDelegate) =>
      oldDelegate.anchorRect != anchorRect;
}
