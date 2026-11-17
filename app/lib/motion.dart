import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 动效基元：全 App 共用一套时长与曲线，并提供「系统要求减少动效」时的降级。
///
/// 参考了 reactbits 里的 CountUp / Shimmer / ShinyText / 逐项入场 / 按压反馈几个思路，
/// 但都用 Flutter 原生实现——那边是 React 组件，没法直接搬。
class Motion {
  static const fast = Duration(milliseconds: 130);
  static const normal = Duration(milliseconds: 220);
  static const slow = Duration(milliseconds: 380);

  static const curve = Curves.easeOutCubic;
  static const spring = Cubic(0.22, 1.2, 0.36, 1);

  /// 系统开了「移除动画」时，全部降级成直给
  static bool enabled(BuildContext context) {
    final disable = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return !disable;
  }

  static Duration of(BuildContext context, Duration d) =>
      enabled(context) ? d : Duration.zero;
}


/// 按压缩放：给可点区域一点「按下去」的反馈
class PressScale extends StatefulWidget {
  const PressScale({
    super.key,
    required this.child,
    this.onTap,
    this.scale = 0.975,
    this.behavior = HitTestBehavior.opaque,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double scale;
  final HitTestBehavior behavior;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final animate = Motion.enabled(context);
    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down && animate ? widget.scale : 1,
        duration: animate ? Motion.fast : Duration.zero,
        curve: Motion.curve,
        child: widget.child,
      ),
    );
  }
}

/// 逐项入场：淡入 + 轻微上移，按 index 错开
class FadeSlideIn extends StatefulWidget {
  const FadeSlideIn({
    super.key,
    required this.child,
    this.index = 0,
    this.offset = 10,
  });

  final Widget child;
  final int index;
  final double offset;

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn> {
  bool _shown = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // 最多错开 8 项，避免长列表末尾等太久
    final delay = Duration(milliseconds: 24 * math.min(widget.index, 8));
    _timer = Timer(delay, () {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final animate = Motion.enabled(context);
    return AnimatedOpacity(
      opacity: _shown ? 1 : 0,
      duration: animate ? Motion.normal : Duration.zero,
      curve: Motion.curve,
      child: AnimatedSlide(
        offset: _shown ? Offset.zero : Offset(0, widget.offset / 100),
        duration: animate ? Motion.normal : Duration.zero,
        curve: Motion.curve,
        child: widget.child,
      ),
    );
  }
}

/// 数字滚动：值变化时旧值上滑淡出、新值下方滑入
class RollingNumber extends StatelessWidget {
  const RollingNumber({
    super.key,
    required this.value,
    this.style,
    this.suffix = '',
    this.prefix = '',
  });

  final int value;
  final TextStyle? style;
  final String suffix;
  final String prefix;

  @override
  Widget build(BuildContext context) {
    final animate = Motion.enabled(context);
    return AnimatedSwitcher(
      duration: animate ? Motion.normal : Duration.zero,
      switchInCurve: Motion.curve,
      switchOutCurve: Motion.curve,
      transitionBuilder: (child, animation) => ClipRect(
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.45),
            end: Offset.zero,
          ).animate(animation),
          child: FadeTransition(opacity: animation, child: child),
        ),
      ),
      child: Text(
        '$prefix$value$suffix',
        key: ValueKey<int>(value),
        style: style,
      ),
    );
  }
}

/// 骨架屏：灰块 + 扫光
class Skeleton extends StatefulWidget {
  const Skeleton({
    super.key,
    this.width,
    this.height = 12,
    this.radius = 6,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = scheme.surfaceContainerHighest;
    final highlight = Color.lerp(base, scheme.surface, 0.6)!;
    if (!Motion.enabled(context)) {
      return Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(color: base, borderRadius: BorderRadius.circular(widget.radius)),
      );
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          gradient: LinearGradient(
            begin: Alignment(-1 - 2 * _c.value, 0),
            end: Alignment(1 - 2 * _c.value, 0),
            colors: [base, highlight, base],
            stops: const [0.35, 0.5, 0.65],
          ),
        ),
      ),
    );
  }
}

/// 列表骨架：几行占位，用在首次加载
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.rows = 6});

  final int rows;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      itemCount: rows,
      separatorBuilder: (_, _) => const SizedBox(height: 18),
      itemBuilder: (context, i) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Skeleton(width: 38, height: 38, radius: 12),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Skeleton(width: i.isEven ? 220 : 170, height: 14),
                const SizedBox(height: 8),
                const Skeleton(width: 140, height: 10),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 光泽扫过：用在「预测」这类需要一点点强调的标题上，别多用
class ShinyText extends StatefulWidget {
  const ShinyText({super.key, required this.text, this.style});

  final String text;
  final TextStyle? style;

  @override
  State<ShinyText> createState() => _ShinyTextState();
}

class _ShinyTextState extends State<ShinyText> with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600))
      ..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style ?? Theme.of(context).textTheme.titleSmall!;
    if (!Motion.enabled(context)) return Text(widget.text, style: style);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value * 2 - 1;
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (rect) => LinearGradient(
            begin: Alignment(t - 0.6, 0),
            end: Alignment(t + 0.6, 0),
            colors: [
              style.color ?? Colors.black,
              Color.lerp(style.color ?? Colors.black, Colors.white, 0.55)!,
              style.color ?? Colors.black,
            ],
            stops: const [0.35, 0.5, 0.65],
          ).createShader(rect),
          child: Text(widget.text, style: style),
        );
      },
    );
  }
}
