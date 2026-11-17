import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/ics_service.dart';
import '../services/prefs.dart';
import '../theme.dart';
import 'bili_pages.dart';
import 'llm_settings_page.dart';
import '../services/reminder_service.dart';

/// 订阅：本地提醒 + 导出日历 + 提醒模板 + 边界说明。
class SubscribeScreen extends StatelessWidget {
  const SubscribeScreen({
    super.key,
    required this.state,
    required this.onEnableReminders,
    required this.onReschedule,
  });

  final AppState state;
  final Future<void> Function() onEnableReminders;
  final Future<void> Function() onReschedule;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final data = state.data!;
        final alarms = data.alarms;

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Card(
              child: SwitchListTile.adaptive(
                value: state.remindersOn,
                onChanged: (v) async {
                  if (v) {
                    await onEnableReminders();
                  } else {
                    state.setReminders(false);
                    await onReschedule();
                  }
                },
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                title: const Text('本地提醒'),
                subtitle: Text(
                  state.remindersOn
                      ? '已排 ${state.scheduledCount} 条 · 由系统闹钟触发，不联网'
                      : '关闭中 · 打开后由系统通知提醒，App 划掉也能收到',
                  style: theme.textTheme.bodySmall,
                ),
                secondary: TextButton(
                  onPressed: () async {
                    await ReminderService.scheduleTest();
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('10 秒后应该弹一条测试通知')),
                    );
                  },
                  child: const Text('测试'),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('数据版本', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 6),
                    Text(
                      '构建于 ${data.builtAt.replaceFirst('T', ' ').substring(0, 16)}'
                      ' · ${data.events.length} 条事件',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '来源：${data.events.map((e) => e.sourceName ?? '未标注').toSet().join('、')}',
                      style: theme.textTheme.labelSmall,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '事件全部来自 B 站动态，经大模型解析后入日历（日历右上角 ↻ 触发刷新）。',
                      style: theme.textTheme.labelSmall,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      state.liveEvents.isEmpty
                          ? '本机刷新：还没跑过（日历页右上角 ↻）'
                          : '本机刷新：${state.liveEvents.length} 条 · '
                              '${state.liveFetchedAt?.toString().substring(5, 16) ?? ''}',
                      style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            const _LlmCard(),
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('B 站动态', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 6),
                    Text(
                      '用你自己的账号只读拉取官号动态（手机号/密码登录）。登录态只存在手机的 WebView 里，App 不读取、不上传 SESSDATA。',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () async {
                              final ok = await Navigator.of(context).push<bool>(
                                MaterialPageRoute(builder: (_) => const BiliLoginPage()),
                              );
                              if (!context.mounted) return;
                              if (ok == true) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('已登录，可以点「从 B 站刷新」')),
                                );
                              }
                            },
                            style: OutlinedButton.styleFrom(
                              shape: AppShapes.pill,
                              side: BorderSide.none,
                              backgroundColor: theme.colorScheme.surfaceContainerHighest,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            child: const Text('登录 B 站'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton(
                            onPressed: () async {
                              if (state.bindings.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('先去游戏库绑定官号 UID')),
                                );
                                return;
                              }
                              final changed = await showDialog<bool>(
                                context: context,
                                barrierDismissible: false,
                                builder: (_) => BiliRefreshDialog(state: state),
                              );
                              if (changed == true) await onReschedule();
                            },
                            child: const Text('从 B 站刷新'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('导出到系统日历', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 6),
                    Text(
                      '导出 .ics 交给系统日历，和厂商自己发的“日历提醒”是同一种东西。',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => IcsService.shareFile(
                          events: state.reminderScope,
                          games: data.gamesById,
                          alarms: alarms,
                        ),
                        child: Text('导出 ${state.reminderScope.length} 条日程'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('提醒提前量', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    for (final entry in alarms.entries)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            Expanded(child: Text(entry.key, style: theme.textTheme.bodyMedium)),
                            Text(entry.value.map(_label).join(' · '), style: theme.textTheme.labelSmall),
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
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('数据与边界', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    Text(
                      '事件来自各游戏官网公告，每条保留来源链接与抓取时间。',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '只做时间整理与提醒，不替代官方公告；标“待确认”的事件请勿据此安排计划。',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '应用不联网、不收集数据；绑定与纠错全部存在本机。',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(
                'v0.1 · MVP · 数据构建于 ${data.builtAt.replaceFirst('T', ' ').substring(0, 16)}',
                style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
              ),
            ),
          ],
        );
      },
    );
  }

  static String _label(int minutes) {
    final v = -minutes;
    if (v % 1440 == 0) return '${v ~/ 1440} 天前';
    if (v % 60 == 0) return '${v ~/ 60} 小时前';
    return '$v 分钟前';
  }
}

/// 大模型解析状态卡片：显示是否已配置，点击进设置页
class _LlmCard extends StatefulWidget {
  const _LlmCard();

  @override
  State<_LlmCard> createState() => _LlmCardState();
}

class _LlmCardState extends State<_LlmCard> {
  Map<String, String> cfg = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final value = await Prefs.loadLlm();
    if (!mounted) return;
    setState(() => cfg = value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final configured = (cfg['apiKey'] ?? '').trim().isNotEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('大模型解析', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              configured
                  ? '已配置：${cfg['model']} · ${cfg['baseUrl']}'
                  : '未配置。没配 key 就不会解析动态，事件不会入库。',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LlmSettingsPage()),
                  );
                  await _load();
                },
                style: OutlinedButton.styleFrom(
                  shape: AppShapes.pill,
                  side: BorderSide.none,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(configured ? '修改配置' : '配置 API Key'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}