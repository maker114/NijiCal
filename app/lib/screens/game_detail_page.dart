import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import '../model.dart';
import '../sheets.dart';
import '../theme.dart';
import '../widgets.dart';

/// 游戏详情：更新时间、UID、已追踪条数、详细日程，以及这款游戏的设置项。
class GameDetailPage extends StatelessWidget {
  const GameDetailPage({super.key, required this.state, required this.game});

  final AppState state;
  final Game game;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final accent = state.gameAccentOf(game);
        final events = state.eventsOf(game.id);
        final uid = state.bindings[game.id];
        final updated = events
            .map((e) => e.fetchedAt)
            .whereType<DateTime>()
            .fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);

        return Scaffold(
          appBar: AppBar(title: Text(game.name)),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  child: Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(AppShapes.nestedRadius),
                        ),
                        child: Text(
                          game.initial,
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: accent),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(game.name, style: theme.textTheme.titleMedium),
                            const SizedBox(height: 2),
                            Text(
                              '已追踪 ${events.length} 条日程',
                              style: theme.textTheme.labelSmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('状态', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 10),
                      _row(
                        theme,
                        '更新时间',
                        updated == null ? '还没刷新过' : mdhm(updated),
                      ),
                      const SizedBox(height: 8),
                      _row(theme, 'UID', uid ?? '未绑定'),
                      const SizedBox(height: 8),
                      _row(theme, '版本', game.versionCurrent ?? '未接入'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('设置', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Text('标识色', style: theme.textTheme.bodySmall),
                          const SizedBox(width: 12),
                          for (final preset in accentPresets)
                            GestureDetector(
                              onTap: () => state.setGameAccent(game.id, preset.seed.toARGB32()),
                              child: Container(
                                width: 22,
                                height: 22,
                                margin: const EdgeInsets.only(right: 8),
                                decoration: BoxDecoration(
                                  color: preset.seed,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: preset.seed.toARGB32() == accent.toARGB32()
                                        ? theme.colorScheme.onSurface
                                        : Colors.transparent,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: () => showBindSheet(context, state, game),
                          style: OutlinedButton.styleFrom(
                            shape: AppShapes.pill,
                            side: BorderSide.none,
                            backgroundColor: theme.colorScheme.surfaceContainerHighest,
                            padding: const EdgeInsets.symmetric(vertical: 13),
                          ),
                          child: Text(uid == null ? '绑定官号 UID' : '修改 / 解绑 UID'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text('详细日程', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              if (events.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: EmptyState(
                    title: '还没有日程',
                    body: '绑定官号后，在订阅页从 B 站刷新，事件会落到这里。',
                    icon: Icons.event_busy,
                  ),
                )
              else
                Card(
                  child: Column(
                    children: [
                      for (final event in events)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Column(
                            children: [
                              EventRow(
                                event: event,
                                game: game,
                                onTap: () => showDetailSheet(context, state, event),
                              ),
                              const Divider(height: 1),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _row(ThemeData theme, String key, String value) {
    return Row(
      children: [
        Text(key, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const Spacer(),
        Text(value, style: theme.textTheme.bodySmall),
      ],
    );
  }
}
