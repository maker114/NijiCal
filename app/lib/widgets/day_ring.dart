import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 日期外面那圈**按游戏色分段**的圆环 —— 直接搬自 GuideLine 的 `DayRing`。
///
/// 一条事件一段弧：一天两条各占一半、三条各占三分之一，从 12 点方向顺时针。
/// 颜色取游戏标识色；几条都同色时看起来就是实心环，那也是对的
/// —— 它表达的是"这一天有两条"。
class DayRing extends StatelessWidget {
  const DayRing({super.key, required this.colors, required this.selected, required this.child});

  final List<Color> colors;
  final bool selected;
  final Widget child;

  static const double size = 38;
  static const double strokeWidth = 3;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: DayRingPainter(colors: colors, strokeWidth: strokeWidth),
        child: Center(
          child: Container(
            width: size - strokeWidth * 2 - 2,
            height: size - strokeWidth * 2 - 2,
            alignment: Alignment.center,
            decoration: selected
                ? BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.16),
                    shape: BoxShape.circle,
                  )
                : null,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 把 [colors] 等分成弧画一圈（从 12 点方向顺时针，段间不留缝）。
class DayRingPainter extends CustomPainter {
  const DayRingPainter({required this.colors, required this.strokeWidth});

  final List<Color> colors;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (colors.isEmpty) return;
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: size.width / 2 - strokeWidth / 2,
    );
    final sweep = 2 * math.pi / colors.length;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    for (var i = 0; i < colors.length; i += 1) {
      paint.color = colors[i];
      canvas.drawArc(rect, -math.pi / 2 + i * sweep, sweep, false, paint);
    }
  }

  @override
  bool shouldRepaint(DayRingPainter oldDelegate) =>
      oldDelegate.strokeWidth != strokeWidth || !_same(oldDelegate.colors, colors);

  static bool _same(List<Color> a, List<Color> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i += 1) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
