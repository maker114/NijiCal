import 'package:flutter/material.dart';

import '../services/auto_refresh.dart';
import '../services/power_helper.dart';
import '../services/prefs.dart';
import '../theme.dart';

/// 自动刷新设置：开关、每天的时间点（就是「次数」）、以及后台保活引导。
class AutoRefreshPage extends StatefulWidget {
  const AutoRefreshPage({super.key, required this.onChanged});

  /// 自动刷新跑完后，让外壳重排提醒 / 重载数据
  final Future<void> Function() onChanged;

  @override
  State<AutoRefreshPage> createState() => _AutoRefreshPageState();
}

class _AutoRefreshPageState extends State<AutoRefreshPage> {
  bool enabled = false;
  List<String> times = const ['12:30', '19:30'];
  String? lastSlot;
  bool ignoringBattery = false;
  bool busy = false;
  String? message;
  String lastResult = '';
  DateTime? lastResultAt;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final e = await Prefs.loadAutoEnabled();
    final t = await Prefs.loadAutoTimes();
    final last = await Prefs.loadAutoLastSlot();
    final res = await Prefs.loadAutoResult();
    final ignoring = await PowerHelper.isIgnoringBattery();
    if (!mounted) return;
    setState(() {
      enabled = e;
      times = t;
      lastSlot = last;
      lastResult = res.text;
      lastResultAt = res.at;
      ignoringBattery = ignoring;
    });
  }

  Future<void> _saveTimes() async {
    await Prefs.saveAutoTimes(times);
    await AutoRefresh.reschedule();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _addTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 12, minute: 30),
    );
    if (picked == null) return;
    final text = '${picked.hour.toString().padLeft(2, '0')}:'
        '${picked.minute.toString().padLeft(2, '0')}';
    if (times.contains(text)) return;
    setState(() => times = [...times, text]..sort());
    await _saveTimes();
  }

  Future<void> _removeTime(String value) async {
    setState(() => times = times.where((t) => t != value).toList());
    await _saveTimes();
  }

  Future<void> _runNow() async {
    setState(() {
      busy = true;
      message = null;
    });
    final result = await AutoRefresh.runNow(mark: false);
    if (!mounted) return;
    setState(() {
      busy = false;
      message = result.message;
    });
    await widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('自动刷新')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Card(
            child: SwitchListTile.adaptive(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              value: enabled,
              onChanged: (v) async {
                await Prefs.saveAutoEnabled(v);
                await AutoRefresh.reschedule();
                if (!mounted) return;
                setState(() => enabled = v);
              },
              title: const Text('每天定时刷新'),
              subtitle: Text(
                enabled ? '到点自动拉一次 B 站动态并解析' : '关闭中',
                style: theme.textTheme.bodySmall,
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
                  Row(
                    children: [
                      Text('时间点（每天 ${times.length} 次）', style: theme.textTheme.titleSmall),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: _addTime,
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('添加'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final t in times)
                        InputChip(
                          label: Text(t),
                          onDeleted: () => _removeTime(t),
                          shape: const StadiumBorder(),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'WorkManager 每 15 分钟醒一次，到点后 25 分钟内补跑，不保证分秒准点。',
                    style: theme.textTheme.labelSmall,
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
                  Text('后台保活（国产系统必做）', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    'App 被划掉后，系统会限制后台唤醒。不设置这两项，定时刷新可能不触发。',
                    style: theme.textTheme.labelSmall,
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final ok = await PowerHelper.openAutoStart();
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(ok ? '已打开系统页面，请允许自启动' : '没能打开系统页面，请手动到「设置 → 应用管理 → NijiCal」允许自启动')),
                        );
                      },
                      icon: const Icon(Icons.rocket_launch_outlined, size: 18),
                      label: const Text('去开启「自启动」'),
                      style: OutlinedButton.styleFrom(
                        shape: AppShapes.pill,
                        side: BorderSide.none,
                        backgroundColor: theme.colorScheme.surfaceContainerHighest,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        await PowerHelper.requestIgnoreBattery();
                        await Future<void>.delayed(const Duration(seconds: 1));
                        await _load();
                      },
                      icon: Icon(
                        ignoringBattery ? Icons.battery_saver : Icons.battery_alert,
                        size: 18,
                      ),
                      label: Text(ignoringBattery ? '已忽略电池优化' : '申请忽略电池优化'),
                      style: OutlinedButton.styleFrom(
                        shape: AppShapes.pill,
                        side: BorderSide.none,
                        backgroundColor: theme.colorScheme.surfaceContainerHighest,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
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
                  Text(
                    lastSlot == null ? '还没自动跑过' : '上次自动运行：$lastSlot',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (lastResult.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      '结果：$lastResult'
                      '${lastResultAt == null ? '' : '（${lastResultAt!.month} 月 ${lastResultAt!.day} 日 '
                          '${lastResultAt!.hour.toString().padLeft(2, '0')}:'
                          '${lastResultAt!.minute.toString().padLeft(2, '0')}）'}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: lastResult.contains('失败') || lastResult.contains('跳过')
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: busy ? null : _runNow,
                      child: Text(busy ? '正在刷新…' : '立即试跑一次（不占时间点）'),
                    ),
                  ),
                  if (message != null) ...[
                    const SizedBox(height: 8),
                    Text(message!, style: theme.textTheme.labelSmall),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
