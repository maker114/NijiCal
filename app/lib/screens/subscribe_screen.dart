import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/prefs.dart';

import 'llm_settings_page.dart';
import 'settings_pages.dart';

/// 订阅：按 GuideLine 的设置页做成二级菜单，每一项点进去才是具体设置。
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
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  SettingRow(
                    icon: Icons.notifications_none,
                    title: '本地提醒',
                    subtitle: state.remindersOn
                        ? '开启 · 已排 ${state.scheduledCount} 条'
                        : '关闭 · 打开后由系统通知提醒',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ReminderPage(
                          state: state,
                          onEnableReminders: onEnableReminders,
                          onReschedule: onReschedule,
                        ),
                      ),
                    ),
                  ),
                  const Divider(height: 1, indent: 56),
                  const _LlmRow(),
                  const Divider(height: 1, indent: 56),
                  SettingRow(
                    icon: Icons.login,
                    title: 'B 站账号',
                    subtitle: '登录、刷新官号动态',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => BiliAccountPage(state: state, onReschedule: onReschedule),
                      ),
                    ),
                  ),
                  const Divider(height: 1, indent: 56),
                  SettingRow(
                    icon: Icons.ios_share,
                    title: '导出到系统日历',
                    subtitle: '${state.reminderScope.length} 条，导出 .ics',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => ExportPage(state: state)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  SettingRow(
                    icon: Icons.view_agenda_outlined,
                    title: '显示结束时间',
                    subtitle: state.showEndTime ? '列表显示起止区间' : '只显示开始时间',
                    trailing: Switch.adaptive(
                      value: state.showEndTime,
                      onChanged: state.setShowEndTime,
                    ),
                    onTap: () => state.setShowEndTime(!state.showEndTime),
                  ),
                  const Divider(height: 1, indent: 56),
                  SettingRow(
                    icon: Icons.info_outline,
                    title: '关于',
                    subtitle: '版本、数据来源与边界',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => AboutPage(state: state)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '所有设置只存在本机，不上传。',
              style: theme.textTheme.labelSmall,
              textAlign: TextAlign.center,
            ),
          ],
        );
      },
    );
  }
}

/// 大模型一行：显示是否已配置，点进去改
class _LlmRow extends StatefulWidget {
  const _LlmRow();

  @override
  State<_LlmRow> createState() => _LlmRowState();
}

class _LlmRowState extends State<_LlmRow> {
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
    final configured = (cfg['apiKey'] ?? '').trim().isNotEmpty;
    return SettingRow(
      icon: Icons.auto_awesome_outlined,
      title: '大模型解析',
      subtitle: configured ? '已配置 · ${cfg['model']}' : '未配置，动态不会被解析',
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const LlmSettingsPage()),
        );
        await _load();
      },
    );
  }
}
