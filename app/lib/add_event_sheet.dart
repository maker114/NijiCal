import 'package:flutter/material.dart';

import 'app_state.dart';
import 'model.dart';
import 'theme.dart';

/// 手动添加一条日程：游戏、类型、标题、起止时间、备注。
/// 底部的「保存」固定在屏幕下方，内容区单独滚动——否则键盘弹出时按钮会被挡住。
Future<void> showAddEventSheet(BuildContext context, AppState state) async {
  final games = state.allGames;
  if (games.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('先在游戏库里添加一款游戏，再手动添加日程')),
    );
    return;
  }

  var gameId = games.first.id;
  var type = kManualTypes.first;
  var start = DateTime.now().add(const Duration(hours: 2));
  DateTime? end;
  final titleCtrl = TextEditingController();
  final noteCtrl = TextEditingController();

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppShapes.sheetRadius)),
    ),
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheetState) {
        final theme = Theme.of(sheetContext);
        final keyboard = MediaQuery.of(sheetContext).viewInsets.bottom;
        String fmt(DateTime d) =>
            '${d.month} 月 ${d.day} 日 ${d.hour.toString().padLeft(2, '0')}:'
            '${d.minute.toString().padLeft(2, '0')}';

        Future<DateTime?> pick(DateTime initial) async {
          final date = await showDatePicker(
            context: sheetContext,
            initialDate: initial,
            firstDate: DateTime.now().subtract(const Duration(days: 365)),
            lastDate: DateTime.now().add(const Duration(days: 730)),
            helpText: '选择日期',
          );
          if (date == null || !sheetContext.mounted) return null;
          final time = await showTimePicker(
            context: sheetContext,
            initialTime: TimeOfDay.fromDateTime(initial),
            helpText: '选择时间',
          );
          if (time == null) return null;
          return DateTime(date.year, date.month, date.day, time.hour, time.minute);
        }

        Future<void> save() async {
          final title = titleCtrl.text.trim();
          if (title.isEmpty) {
            ScaffoldMessenger.of(sheetContext).showSnackBar(
              const SnackBar(content: Text('标题不能为空')),
            );
            return;
          }
          final id = 'manual-${DateTime.now().millisecondsSinceEpoch}';
          await state.addManualEvent(GameEvent(
            id: id,
            gameId: gameId,
            type: type,
            title: title,
            start: start,
            end: end,
            status: EventStatus.confirmed,
            confidence: 100,
            summary: noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim(),
            fetchedAt: DateTime.now(),
            sourceName: '手动添加',
            tags: const ['手动'],
            revisions: const [],
          ));
          if (!sheetContext.mounted) return;
          Navigator.of(sheetContext).pop();
          ScaffoldMessenger.of(sheetContext).showSnackBar(
            const SnackBar(content: Text('已添加，刷新不会覆盖它')),
          );
        }

        return Padding(
          padding: EdgeInsets.only(bottom: keyboard),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('手动添加日程', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 14),
                      Text('游戏', style: theme.textTheme.labelLarge),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final g in games)
                            ChoiceChip(
                              label: Text(g.short),
                              selected: gameId == g.id,
                              selectedColor: state.gameAccentOf(g).withValues(alpha: 0.22),
                              onSelected: (_) => setSheetState(() => gameId = g.id),
                            ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Text('类型', style: theme.textTheme.labelLarge),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final t in kManualTypes)
                            ChoiceChip(
                              label: Text(t),
                              selected: type == t,
                              onSelected: (_) => setSheetState(() => type = t),
                            ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: titleCtrl,
                        textInputAction: TextInputAction.done,
                        decoration: const InputDecoration(
                          labelText: '标题',
                          hintText: '例如：3.5 版本前瞻直播',
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: () async {
                            final picked = await pick(start);
                            if (picked != null) setSheetState(() => start = picked);
                          },
                          child: Text('开始 ${fmt(start)}'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () async {
                                final picked = await pick(end ?? start);
                                if (picked != null) setSheetState(() => end = picked);
                              },
                              child: Text(end == null ? '结束时间（可选）' : '结束 ${fmt(end!)}'),
                            ),
                          ),
                          if (end != null)
                            IconButton(
                              tooltip: '清除结束时间',
                              onPressed: () => setSheetState(() => end = null),
                              icon: const Icon(Icons.close, size: 18),
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: noteCtrl,
                        maxLines: 2,
                        decoration: const InputDecoration(labelText: '备注（可选）'),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
              // 固定在底部：键盘弹出时也不会被挡住
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: save,
                    child: const Text('保存'),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

/// 手动添加时可选的类型
const kManualTypes = <String>[
  '前瞻直播',
  '版本更新',
  '停服维护',
  '活动开始',
  '活动结束',
  '卡池开始',
  '卡池结束',
  '兑换码截止',
  '补偿领取截止',
];
