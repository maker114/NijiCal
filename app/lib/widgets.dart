import 'dart:io';

import 'package:flutter/material.dart';

import 'format.dart';
import 'motion.dart';
import 'services/avatar_store.dart';
import 'model.dart';
import 'theme.dart';

/// 小胶囊标签（游戏 / 类型 / 状态）。
class Tag extends StatelessWidget {
  const Tag({super.key, required this.text, this.color, this.dot, this.dense = false});

  final String text;
  final Color? color;
  final Color? dot;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = color ?? scheme.onSurfaceVariant;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 10, vertical: dense ? 2 : 3),
      decoration: BoxDecoration(
        color: ink.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppShapes.pillRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot != null) ...[
            Container(width: 6, height: 6, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
            const SizedBox(width: 5),
          ],
          Text(
            text,
            style: TextStyle(
              fontSize: dense ? 10.5 : 11.5,
              height: 1.3,
              fontWeight: FontWeight.w500,
              color: ink,
            ),
          ),
        ],
      ),
    );
  }
}

/// 分组小标题（照 GuideLine 的 SectionHeader：主题色、labelLarge）。
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(text, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
    );
  }
}

/// 可选中的筛选胶囊。
class ChoicePill extends StatelessWidget {
  const ChoicePill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.dot,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? dot;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      customBorder: AppShapes.pill,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? scheme.secondaryContainer : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppShapes.pillRadius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (dot != null) ...[
              Container(width: 7, height: 7, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 空状态：图标 + 一句标题 + 一句补充。
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.title, this.body, this.icon});

  final String title;
  final String? body;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: Column(
        children: [
          if (icon != null) ...[
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.10), shape: BoxShape.circle),
              child: Icon(icon, color: scheme.primary, size: 24),
            ),
            const SizedBox(height: 14),
          ],
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          if (body != null) ...[
            const SizedBox(height: 6),
            Text(body!, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

/// 一条事件的行（日历下方列表 / 详情入口）。
///
/// 照 GuideLine 的 TaskTile 语汇：**平铺行 + 分隔线**，不做卡片堆叠。
class EventRow extends StatelessWidget {
  const EventRow({
    super.key,
    required this.event,
    required this.game,
    required this.onTap,
    this.accent,
    this.showEnd = false,
  });

  final GameEvent event;
  final Game? game;
  final VoidCallback onTap;

  /// 游戏标识色（可被用户改过），不传就退回数据里的默认色
  final Color? accent;

  /// 关闭时只显示开始时间；打开才显示起止区间
  final bool showEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final urgency = urgencyOf(event.due);
    final accentColor = UrgencyColors.ofContext(context).of(urgency);
    final countdown = countdownOf(event.due);
    final gameColor = accent ?? game?.accent ?? scheme.primary;
    // 开始类事件带着原区间（displayEnd），直接把「开始 → 结束」显示出来
    final rangeEnd = event.end ?? event.displayEnd;
    final timeText = event.start != null && rangeEnd != null
        ? eventRangeShort(event.start, rangeEnd)
        : (event.start != null
            ? '开始 ${shortDate(event.start!)} ${hm(event.start!)}'
            : '截止 ${shortDate(event.due)} ${hm(event.due)}');

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GameAvatar(game: game, color: gameColor, size: 38),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    event.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: event.predicted
                        ? theme.textTheme.titleSmall?.copyWith(color: scheme.primary)
                        : theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${event.predicted ? '预测 · ' : ''}${event.type} · $timeText',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  urgencyLabel(urgency),
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: accentColor),
                ),
                const SizedBox(height: 2),
                _CountdownText(countdown: countdown.text, scheme: scheme, theme: theme),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 游戏头像：有缓存过的官号头像就显示头像，否则退回首字色块
class GameAvatar extends StatelessWidget {
  const GameAvatar({super.key, required this.game, required this.color, this.size = 38});

  final Game? game;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final path = game == null ? null : AvatarStore.pathOf(game!.id);
    final radius = BorderRadius.circular(AppShapes.nestedRadius);

    if (path != null) {
      return ClipRRect(
        borderRadius: radius,
        child: Image.file(
          File(path),
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _fallback(radius),
        ),
      );
    }
    return _fallback(radius);
  }

  Widget _fallback(BorderRadius radius) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: radius),
      child: Text(
        game?.initial ?? '·',
        style: TextStyle(fontSize: size * 0.4, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }
}

/// 倒计时文本：数字做滚动，前后缀原样保留
class _CountdownText extends StatelessWidget {
  const _CountdownText({required this.countdown, required this.scheme, required this.theme});

  final String countdown;
  final ColorScheme scheme;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final style = theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    final match = RegExp(r'(\d+)').firstMatch(countdown);
    if (match == null) return Text(countdown, style: style);
    final number = int.tryParse(match.group(1)!) ?? 0;
    final prefix = countdown.substring(0, match.start);
    final suffix = countdown.substring(match.end);
    return RollingNumber(value: number, prefix: prefix, suffix: suffix, style: style);
  }
}