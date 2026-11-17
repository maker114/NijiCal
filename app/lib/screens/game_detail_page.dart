import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import '../model.dart';
import '../sheets.dart';
import '../theme.dart';
import '../widgets.dart';

/// 游戏详情：更新时间、UID、已追踪条数、详细日程。
/// 设置（标识色 / UID）收在右上角，不占正文。
class GameDetailPage extends StatelessWidget {
  const GameDetailPage({super.key, required this.state, required this.game});

  final AppState state;
  final Game game;

  Future<void> _openSettings(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppShapes.sheetRadius)),
      ),
      builder: (_) => ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final theme = Theme.of(context);
          final accent = state.gameAccentOf(game);
          final uid = state.bindings[game.id];
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('设置', style: theme.textTheme.titleLarge),
                const SizedBox(height: 16),
                Text('标识色', style: theme.textTheme.labelLarge),
                const SizedBox(height: 10),
                Row(
                  children: [
                    for (final preset in accentPresets)
                      GestureDetector(
                        onTap: () => state.setGameAccent(game.id, preset.seed.toARGB32()),
                        child: Container(
                          width: 28,
                          height: 28,
                          margin: const EdgeInsets.only(right: 10),
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
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => showBindSheet(context, state, game),
                    style: OutlinedButton.styleFrom(
                      shape: AppShapes.pill,
                      side: BorderSide.none,
                      backgroundColor: theme.colorScheme.surfaceContainerHighest,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: Text(uid == null ? '绑定官号 UID' : '修改 / 解绑 UID'),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: Text('移除 ${game.name}？'),
                          content: const Text('会同时清掉它的绑定与本地日程，重新添加后可以再刷新回来。'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(dialogContext).pop(false),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.of(dialogContext).pop(true),
                              child: const Text('移除'),
                            ),
                          ],
                        ),
                      );
                      if (ok != true) return;
                      if (!context.mounted) return;
                      Navigator.of(context).pop();
                      await Future<void>.delayed(const Duration(milliseconds: 220));
                      if (!context.mounted) return;
                      Navigator.of(context).pop();
                      state.removeGame(game.id);
                    },
                    style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                    child: const Text('从游戏库移除'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final accent = state.gameAccentOf(game);
        final all = state.eventsOf(game.id);
        final now = DateTime.now();
        final upcoming = all.where((e) => !e.due.isBefore(now)).toList();
        final expired = all.where((e) => e.due.isBefore(now)).toList();
        final uid = state.bindings[game.id];
        final updated = all
            .map((e) => e.fetchedAt)
            .whereType<DateTime>()
            .fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);

        return Scaffold(
          appBar: AppBar(
            title: Text(game.name),
            actions: [
              IconButton(
                tooltip: '设置',
                onPressed: () => _openSettings(context),
                icon: const Icon(Icons.settings_outlined),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  child: Row(
                    children: [
                      GameAvatar(game: game, color: accent, size: 48),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(game.name, style: theme.textTheme.titleMedium),
                            const SizedBox(height: 2),
                            Text('已追踪 ${all.length} 条日程', style: theme.textTheme.labelSmall),
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
                      _row(theme, '更新时间', updated == null ? '还没刷新过' : mdhm(updated)),
                      const SizedBox(height: 8),
                      _row(theme, 'UID', uid ?? '未绑定'),
                      const SizedBox(height: 8),
                      _row(theme, '版本', game.versionCurrent ?? '未接入'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text('详细日程', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              if (upcoming.isEmpty && expired.isEmpty)
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
                      for (final event in upcoming)
                        Column(
                          children: [
                            EventRow(
                              event: event,
                              game: game,
                              accent: accent,
                              onTap: () => showDetailSheet(context, state, event),
                            ),
                            const Divider(height: 1),
                          ],
                        ),
                      if (expired.isNotEmpty) _ExpiredBlock(events: expired, game: game, state: state, accent: accent),
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

/// 过期条目默认折叠
class _ExpiredBlock extends StatefulWidget {
  const _ExpiredBlock({required this.events, required this.game, required this.state, required this.accent});

  final List<GameEvent> events;
  final Game game;
  final AppState state;
  final Color accent;

  @override
  State<_ExpiredBlock> createState() => _ExpiredBlockState();
}

class _ExpiredBlockState extends State<_ExpiredBlock> {
  bool open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        InkWell(
          onTap: () => setState(() => open = !open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                Text('已过期 ${widget.events.length} 条', style: theme.textTheme.labelLarge),
                const Spacer(),
                Icon(open ? Icons.expand_less : Icons.expand_more, size: 20),
              ],
            ),
          ),
        ),
        if (open)
          for (final event in widget.events)
            Column(
              children: [
                EventRow(
                  event: event,
                  game: widget.game,
                  accent: widget.accent,
                  onTap: () => showDetailSheet(context, widget.state, event),
                ),
                const Divider(height: 1),
              ],
            ),
      ],
    );
  }
}
