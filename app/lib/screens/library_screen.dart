import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import '../model.dart';
import '../sheets.dart';
import '../theme.dart';
import '../widgets.dart';

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
    final events = state.eventsOf(game.id);
    final upcoming = events.where((e) => !e.due.isBefore(DateTime.now())).toList();
    final next = upcoming.isEmpty ? null : upcoming.first;
    final bound = state.bindings[game.id];

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: game.accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(AppShapes.nestedRadius),
                  ),
                  child: Text(
                    game.initial,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: game.accent),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(game.name, style: theme.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text(
                        '${events.length} 条日程${next != null ? ' · 最近 ${shortDate(next.due)}' : ''}',
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => showBindSheet(context, state, game),
                  child: Text(bound == null ? '绑定官号' : '已绑定'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _kv(context, '当前版本', game.versionCurrent ?? '未接入')),
                Expanded(child: _kv(context, '下一版本', game.versionNext ?? '未接入')),
                Expanded(
                  child: _kv(
                    context,
                    '最近事件',
                    next == null ? '—' : next.type,
                    align: CrossAxisAlignment.end,
                  ),
                ),
              ],
            ),
            if (bound != null) ...[
              const SizedBox(height: 8),
              Text('UID $bound', style: theme.textTheme.labelSmall),
            ],
          ],
        ),
      ),
    );
  }

  Widget _kv(BuildContext context, String key, String value, {CrossAxisAlignment align = CrossAxisAlignment.start}) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: align,
      children: [
        Text(key, style: theme.textTheme.labelSmall),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface),
        ),
      ],
    );
  }
}
