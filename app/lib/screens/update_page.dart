import 'package:flutter/material.dart';

import '../motion.dart';
import '../services/update_service.dart';
import '../theme.dart';
import '../version.dart';

/// 设置 → 检查更新：问一次仓库清单，比 versionCode，给下载/安装按钮。
class UpdatePage extends StatefulWidget {
  const UpdatePage({super.key});

  @override
  State<UpdatePage> createState() => _UpdatePageState();
}

class _UpdatePageState extends State<UpdatePage> {
  bool checking = true;
  bool downloading = false;
  double progress = 0;
  UpdateInfo? info;
  String? error;
  String? installHint;
  DateTime? lastChecked;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() {
      checking = true;
      error = null;
      info = null;
      installHint = null;
    });
    final (latest, err) = await UpdateService.check();
    if (!mounted) return;
    setState(() {
      checking = false;
      info = latest;
      error = err;
    });
    if (latest != null) await UpdateService.markChecked();
    final at = await UpdateService.lastChecked();
    if (mounted) setState(() => lastChecked = at);
  }

  Future<void> _downloadAndInstall(UpdateInfo latest) async {
    setState(() {
      downloading = true;
      progress = 0;
      installHint = null;
    });
    try {
      final path = await UpdateService.download(
        latest,
        onProgress: (p) {
          if (mounted) setState(() => progress = p);
        },
      );
      if (!mounted) return;
      setState(() => downloading = false);
      final ok = await UpdateService.install(path);
      if (!mounted) return;
      if (!ok) {
        setState(() => installHint = '没能唤起安装器：请在系统设置里允许「安装未知应用」，然后重试');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        downloading = false;
        installHint = '下载失败：${'$e'.split('\n').first}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final latest = info;
    final hasUpdate = latest != null && latest.usable && latest.versionCode > kAppVersionCode;

    return Scaffold(
      appBar: AppBar(title: const Text('检查更新')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          FadeSlideIn(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('当前版本', style: theme.textTheme.labelLarge),
                    const SizedBox(height: 6),
                    Text('$kAppVersion（$kAppVersionCode）', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 10),
                    Text(
                      lastChecked == null
                          ? '还没检查过'
                          : '上次检查：${lastChecked!.month} 月 ${lastChecked!.day} 日 '
                              '${lastChecked!.hour.toString().padLeft(2, '0')}:'
                              '${lastChecked!.minute.toString().padLeft(2, '0')}',
                      style: theme.textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (checking)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 12),
                    Text('正在查询仓库…', style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            )
          else if (error != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('检查失败', style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.error)),
                    const SizedBox(height: 6),
                    Text(error!, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            )
          else if (latest != null && latest.usable)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hasUpdate ? '发现新版本 ${latest.version}' : '已是最新版本',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: hasUpdate ? theme.colorScheme.primary : null,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      hasUpdate
                          ? '仓库版本：${latest.version}（${latest.versionCode}）'
                          : '仓库版本：${latest.version}（${latest.versionCode}）',
                      style: theme.textTheme.labelSmall,
                    ),
                    if (latest.notes.trim().isNotEmpty) ...[
                      const SizedBox(height: 10),
                      _UpdateNotes(notes: latest.notes),
                    ],
                    if (hasUpdate) ...[
                      const SizedBox(height: 14),
                      if (downloading) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(AppShapes.pillRadius),
                          child: LinearProgressIndicator(value: progress == 0 ? null : progress),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          progress > 0 ? '下载中 ${(progress * 100).toStringAsFixed(0)}%' : '正在下载…',
                          style: theme.textTheme.labelSmall,
                        ),
                      ] else
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: () => _downloadAndInstall(latest),
                            icon: const Icon(Icons.system_update_alt, size: 18),
                            label: const Text('下载并安装（覆盖更新，不丢数据）'),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          if (installHint != null) ...[
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(installHint!, style: theme.textTheme.bodySmall),
              ),
            ),
          ],
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: checking ? null : _check,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重新检查'),
              style: OutlinedButton.styleFrom(
                shape: AppShapes.pill,
                side: BorderSide.none,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                padding: const EdgeInsets.symmetric(vertical: 13),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '更新包从 ${UpdateService.repositoryUrl} 的源码构建，签名与当前版本一致，'
            '因此可以直接覆盖安装，数据不会丢。',
            style: theme.textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}

/// 更新说明：按行拆成条目，每条单独一行（长句再按「；」拆）
class _UpdateNotes extends StatelessWidget {
  const _UpdateNotes({required this.notes});

  final String notes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(height: 1.55);
    final items = splitUpdateNotes(notes);
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('· ', style: style),
                Expanded(
                  child: Text(
                    item,
                    style: style,
                    softWrap: true,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}