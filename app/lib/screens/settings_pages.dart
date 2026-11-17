import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import '../services/ics_service.dart';
import '../services/reminder_service.dart';
import '../theme.dart';
import '../version.dart';
import 'bili_pages.dart';

/// 二级设置里通用的一行
class SettingRow extends StatelessWidget {
  const SettingRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(icon, size: 22, color: theme.colorScheme.onSurfaceVariant),
      title: Text(title, style: theme.textTheme.bodyMedium),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, style: theme.textTheme.labelSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: trailing ?? const Icon(Icons.chevron_right, size: 20),
      onTap: onTap,
    );
  }
}

/// 卡片里的小标题
Widget sectionTitle(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Text(text, style: Theme.of(context).textTheme.labelLarge),
    );

// ---------------------------------------------------------------- 本地提醒

class ReminderPage extends StatelessWidget {
  const ReminderPage({
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
    final theme = Theme.of(context);
    final alarms = state.data!.alarms;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('本地提醒')),
        body: ListView(
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
                title: const Text('开启提醒'),
                subtitle: Text(
                  state.remindersOn
                      ? '已排 ${state.scheduledCount} 条 · 由系统闹钟触发，不联网'
                      : '关闭中 · 打开后由系统通知提醒，App 划掉也能收到',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Card(
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                title: const Text('发一条测试通知'),
                subtitle: Text('10 秒后弹出，用来确认系统没拦通知', style: theme.textTheme.labelSmall),
                trailing: const Icon(Icons.send_outlined, size: 20),
                onTap: () async {
                  await ReminderService.scheduleTest();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('10 秒后应该弹一条测试通知')),
                  );
                },
              ),
            ),
            const SizedBox(height: 18),
            sectionTitle(context, '提醒提前量'),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                child: Column(
                  children: [
                    for (final entry in alarms.entries)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            Expanded(child: Text(entry.key, style: theme.textTheme.bodyMedium)),
                            Text(
                              entry.value.map((m) => -m).map((v) {
                                if (v % 1440 == 0) return '${v ~/ 1440} 天前';
                                if (v % 60 == 0) return '${v ~/ 60} 小时前';
                                return '$v 分钟前';
                              }).join(' · '),
                              style: theme.textTheme.labelSmall,
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- B 站账号

class BiliAccountPage extends StatelessWidget {
  const BiliAccountPage({super.key, required this.state, required this.onReschedule});

  final AppState state;
  final Future<void> Function() onReschedule;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('B 站账号')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '用你自己的账号只读拉取官号动态（手机号 / 密码登录）。'
                      '登录态只存在手机的 WebView 里，App 不读取、不上传 SESSDATA。',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: () async {
                          final ok = await Navigator.of(context).push<bool>(
                            MaterialPageRoute(builder: (_) => const BiliLoginPage()),
                          );
                          if (!context.mounted) return;
                          if (ok == true) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('已登录，可以刷新了')),
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
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
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
              ),
            ),
            const SizedBox(height: 10),
            Card(
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                title: Text(
                  state.liveEvents.isEmpty ? '本机还没有刷新过' : '本机 ${state.liveEvents.length} 条事件',
                  style: theme.textTheme.bodyMedium,
                ),
                subtitle: Text(
                  state.liveFetchedAt == null ? '未刷新' : '上次刷新 ${mdhm(state.liveFetchedAt!)}',
                  style: theme.textTheme.labelSmall,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 导出

class ExportPage extends StatelessWidget {
  const ExportPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final data = state.data!;
        return Scaffold(
          appBar: AppBar(title: const Text('导出到系统日历')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '导出 .ics 交给系统日历，和厂商自己发的“日历提醒”是同一种东西。',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: () => IcsService.shareFile(
                            events: state.reminderScope,
                            games: data.gamesById,
                            alarms: data.alarms,
                          ),
                          child: Text('导出 ${state.reminderScope.length} 条日程'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------- 关于

class AboutPage extends StatelessWidget {
  const AboutPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final data = state.data;
        return Scaffold(
          appBar: AppBar(title: const Text('关于')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('NijiCal', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text('版本 $kAppVersion', style: theme.textTheme.labelSmall),
                      const SizedBox(height: 10),
                      Text(
                        '把二游官方的动态变成能订阅、能提醒、能追溯的日程。',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              sectionTitle(context, '数据'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        data == null
                            ? '数据未加载'
                            : '构建于 ${data.builtAt.replaceFirst('T', ' ').substring(0, 16)}'
                                ' · 内置 ${data.events.length} 条',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '事件全部来自 B 站官号动态，经大模型规范化为游戏 / 版本 / 类型 / 时间 / 标签。',
                        style: theme.textTheme.labelSmall,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        state.liveEvents.isEmpty
                            ? '本机刷新：还没跑过'
                            : '本机刷新：${state.liveEvents.length} 条 · '
                                '${state.liveFetchedAt == null ? '' : mdhm(state.liveFetchedAt!)}',
                        style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              sectionTitle(context, '边界'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  child: Text(
                    '只做时间整理与提醒，不替代官方公告；标“待确认”的事件请勿据此安排计划。'
                    '标题与时间由大模型从原文抽取，可能出错，详情页保留了来源链接可回查。',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
