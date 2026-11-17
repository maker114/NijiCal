import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import '../model.dart';
import '../sheets.dart';
import '../theme.dart';
import '../widgets.dart';
import 'game_detail_page.dart';

/// 游戏库：搜索 + 每款游戏的官号绑定入口。
class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final games = state.games;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            TextField(
              onChanged: state.setSearch,
              style: Theme.of(context).textTheme.bodyMedium,
              decoration: const InputDecoration(
                hintText: '搜索游戏…',
                prefixIcon: Icon(Icons.search, size: 20),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '已绑定 ${state.boundCount} 个官号 · 绑定只存在本机',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const SizedBox(height: 12),
            if (games.isEmpty)
              const EmptyState(title: '没有匹配的游戏', body: '换个关键词试试。', icon: Icons.search_off)
            else
              for (final game in games) ...[
                _GameCard(game: game, state: state),
                const SizedBox(height: 10),
              ],
          ],
        );
      },
    );
  }
}

class _GameCard extends StatelessWidget {
  const _GameCard({required this.game, required this.state});

  final Game game;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = state.gameAccentOf(game);
    final events = state.eventsOf(game.id);
    final upcoming = events.where((e) => !e.due.isBefore(DateTime.now())).toList();
    final next = upcoming.isEmpty ? null : upcoming.first;
    final bound = state.bindings[game.id];

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => GameDetailPage(state: state, game: game)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标识色：左侧竖条 + 图标底色，一眼区分四个号
              Container(
                width: 4,
                height: 44,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(AppShapes.nestedRadius),
                ),
                child: Text(
                  game.initial,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: accent),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(game.name, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Text(
                      next == null
                          ? '暂无日程'
                          : '最近：${next.title} · ${shortDate(next.due)} ${hm(next.due)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall,
                    ),
                    // 绑定提示只在未绑定这种“异常态”出现
                    if (bound == null) ...[
                      const SizedBox(height: 6),
                      Text(
                        '还没有绑定官号，刷新时不会拉这个号',
                        style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.error),
                      ),
                    ],
                  ],
                ),
              ),
              if (bound == null)
                TextButton(
                  onPressed: () => showBindSheet(context, state, game),
                  child: const Text('绑定'),
                )
              else
                Icon(Icons.chevron_right, size: 20, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
