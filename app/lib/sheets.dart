import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'app_state.dart';
import 'services/avatar_store.dart';
import 'services/bili_service.dart';
import 'services/logo_color.dart';
import 'services/uid.dart';
import 'format.dart';
import 'model.dart';
import 'services/ics_service.dart';
import 'theme.dart';
import 'theme_controller.dart';
import 'widgets.dart';

/// 统一的底部抽屉：白底（surfaceContainerLow）、只圆上缘 28、一条抓取条。
Future<T?> _showSheet<T>(BuildContext context, {required Widget child, bool scrollable = false}) {
  final scheme = Theme.of(context).colorScheme;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: scheme.surfaceContainerLow,
    barrierColor: Colors.black.withValues(alpha: 0.36),
    shape: AppShapes.sheet,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.88),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(AppShapes.pillRadius),
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: scrollable
                    ? child
                    : SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                        child: child,
                      ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------- 筛选

Future<void> showFilterSheet(BuildContext context, AppState state) {
  return _showSheet<void>(
    context,
    child: ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final theme = Theme.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('筛选', style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            Text('游戏', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoicePill(
                  label: '全部游戏',
                  selected: state.selectedGames.isEmpty,
                  onTap: state.clearGames,
                ),
                for (final g in state.allGames)
                  ChoicePill(
                    label: g.short,
                    dot: g.accent,
                    selected: state.selectedGames.contains(g.id),
                    onTap: () => state.toggleGame(g.id),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            Text('标签', style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            Text('和上面的游戏是两个维度，可同时选：维度内多选取其一，维度之间取交集。',
                style: theme.textTheme.labelSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoicePill(
                  label: '全部标签',
                  selected: state.selectedTags.isEmpty,
                  onTap: state.clearTags,
                ),
                for (final tag in kTagGroups.keys)
                  ChoicePill(
                    label: tag,
                    selected: state.selectedTags.contains(tag),
                    onTap: () => state.toggleTag(tag),
                  ),
              ],
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('完成'),
              ),
            ),
          ],
        );
      },
    ),
  );
}

// ---------------------------------------------------------------- 外观

Future<void> showAppearanceSheet(BuildContext context, ThemeController controller) {
  return _showSheet<void>(
    context,
    child: ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final theme = Theme.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('外观', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('底色始终是中性灰，换的只是前景那支强调色。', style: theme.textTheme.bodySmall),
            const SizedBox(height: 16),
            for (final preset in accentPresets)
              ListTile(
                contentPadding: EdgeInsets.zero,
                shape: AppShapes.chip,
                onTap: () => controller.select(preset.id),
                leading: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(color: preset.seed, shape: BoxShape.circle),
                ),
                title: Text(preset.name, style: theme.textTheme.titleSmall),
                subtitle: Text(preset.mood, style: theme.textTheme.labelSmall),
                trailing: controller.accentId == preset.id
                    ? Icon(Icons.check, color: theme.colorScheme.primary)
                    : null,
              ),
          ],
        );
      },
    ),
  );
}

// ---------------------------------------------------------------- 事件详情

Future<void> showDetailSheet(BuildContext context, AppState state, GameEvent event) {
  final game = state.gameMap[event.gameId];
  final theme = Theme.of(context);
  final urgency = urgencyOf(event.due);
  final accent = UrgencyColors.ofContext(context).of(urgency);

  return _showSheet<void>(
    context,
    scrollable: true,
    child: ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      shrinkWrap: true,
      children: [
        Row(
          children: [
            Tag(text: game?.name ?? '', color: game?.accent, dot: game?.accent),
            const SizedBox(width: 6),
            Tag(text: event.status.label),
            const SizedBox(width: 6),
            Text(urgencyLabel(urgency), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: accent)),
            const Spacer(),
            IconButton(
              tooltip: '关闭',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close, size: 20),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(event.title, style: theme.textTheme.titleLarge),
        const SizedBox(height: 16),
        _MetaRow(label: '类型', value: event.type),
        if ((event.version ?? '').isNotEmpty) _MetaRow(label: '版本', value: event.version!),
        _MetaRow(label: '时间', value: eventRange(event.start, event.end)),
        _MetaRow(label: '剩余', value: countdownOf(event.due).text),
        _MetaRow(label: '置信度', value: '${event.confidence}%'),
        _MetaRow(label: '来源', value: event.sourceName ?? '未标注'),
        if ((event.sourceUrl ?? '').isNotEmpty) ...[
          const SizedBox(height: 4),
          SelectableText(
            event.sourceUrl!,
            style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary),
          ),
        ],
        _MetaRow(label: '抓取时间', value: event.fetchedAt == null ? '—' : mdhm(event.fetchedAt!)),
        const SizedBox(height: 18),
        if (event.tags.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tag in event.tags) Tag(text: tag, dense: true),
            ],
          ),
        ],
        const SizedBox(height: 18),
        Text('原文摘要', style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        Text((event.summary ?? '').isEmpty ? '—' : event.summary!, style: theme.textTheme.bodyMedium),
        if (event.revisions.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text('变更记录', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          for (final r in event.revisions)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(AppShapes.nestedRadius),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${r.field}：${r.from ?? '—'} → ${r.to ?? '—'}', style: theme.textTheme.bodySmall),
                  if ((r.reason ?? '').isNotEmpty)
                    Text(r.reason!, style: theme.textTheme.labelSmall),
                ],
              ),
            ),
        ],
        const SizedBox(height: 18),
        Text('提醒规则', style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        Text(reminderText(state.data!.alarmsFor(event.type)), style: theme.textTheme.bodyMedium),
        const SizedBox(height: 22),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: () => IcsService.shareFile(
                  events: [event],
                  games: {event.gameId: game!},
                  alarms: state.data!.alarms,
                ),
                child: const Text('加入系统日历'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton(
                onPressed: () => _showCorrectionSheet(context, state, event),
                style: OutlinedButton.styleFrom(
                  shape: AppShapes.pill,
                  side: BorderSide.none,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
                child: const Text('提交纠错'),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 72, child: Text(label, style: theme.textTheme.labelLarge)),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 纠错

Future<void> _showCorrectionSheet(BuildContext context, AppState state, GameEvent event) {
  final controller = TextEditingController();
  return _showSheet<void>(
    context,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('提交纠错', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text('针对「${event.title}」', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 14),
        TextField(
          controller: controller,
          minLines: 3,
          maxLines: 5,
          decoration: const InputDecoration(hintText: '例如：官方已公告延期到 12 月 3 日。'),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () {
              state.addCorrection(event.id, controller.text.trim());
              Navigator.of(context).pop();
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已记录，感谢纠错')));
            },
            child: const Text('提交'),
          ),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------- 绑定官号

Future<void> showBindSheet(BuildContext context, AppState state, Game game) {
  final existing = state.bindings[game.id];
  final controller = TextEditingController(text: existing ?? '');
  final theme = Theme.of(context);

  return _showSheet<void>(
    context,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('绑定「${game.name}」官号', style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text('填 B 站官方账号的 UID 或空间链接，只存本机。', style: theme.textTheme.bodySmall),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.tertiaryContainer,
            borderRadius: BorderRadius.circular(AppShapes.nestedRadius),
          ),
          child: Text(
            '说明：绑定只决定刷新时去拉哪个号。'
            'UID 可以粘贴「UID:123456」或空间链接，会自动取出数字。',
            style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onTertiaryContainer),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: '例如 12345678 或 space.bilibili.com/12345678'),
        ),
        const SizedBox(height: 10),
        Text('未人工核实前不预置任何 UID —— 避免把错的号当成官方来源。', style: theme.textTheme.labelSmall),
        const SizedBox(height: 18),
        Row(
          children: [
            if (existing != null) ...[
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    state.unbind(game.id);
                    Navigator.of(context).pop();
                  },
                  style: OutlinedButton.styleFrom(
                    shape: AppShapes.pill,
                    side: BorderSide.none,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  ),
                  child: const Text('解除绑定'),
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: FilledButton(
                onPressed: () {
                  final uid = normalizeUid(controller.text);
                  if (!RegExp(r'^\d{3,}$').hasMatch(uid)) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('没识别出 UID，请填数字或空间链接')),
                    );
                    return;
                  }
                  state.bind(game.id, uid);
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('已绑定 UID $uid')),
                  );
                },
                child: const Text('保存'),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------- 添加游戏

/// 只填 UID（昵称可选）：名称、头像、标识色都从官号资料里取。
/// 返回新游戏的 id；用户取消返回 null。
Future<String?> showAddGameSheet(BuildContext context, AppState state) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppShapes.sheetRadius)),
    ),
    builder: (_) => _AddGameSheet(state: state),
  );
}

class _AddGameSheet extends StatefulWidget {
  const _AddGameSheet({required this.state});

  final AppState state;

  @override
  State<_AddGameSheet> createState() => _AddGameSheetState();
}

class _AddGameSheetState extends State<_AddGameSheet> {
  late final WebViewController _web;
  final uidCtrl = TextEditingController();
  final nickCtrl = TextEditingController();
  Timer? _debounce;

  bool fetching = false;
  String? fetchedName;
  List<int>? faceBytes;
  Color? accent;
  String? error;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36',
      );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    uidCtrl.dispose();
    nickCtrl.dispose();
    super.dispose();
  }

  void _onUidChanged(String value) {
    _debounce?.cancel();
    final normalized = normalizeUid(value);
    if (normalized != value && normalized.isNotEmpty) {
      // 粘贴进来的 “UID:123456” 或空间链接，直接换成纯数字
      uidCtrl.value = TextEditingValue(
        text: normalized,
        selection: TextSelection.collapsed(offset: normalized.length),
      );
    }
    setState(() => error = null);
    final mid = normalized;
    if (mid.length < 3) {
      setState(() {
        fetchedName = null;
        faceBytes = null;
        accent = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 700), () => _fetch(mid));
  }

  Future<void> _fetch(String mid) async {
    setState(() => fetching = true);
    try {
      final info = await BiliService.userInfo(_web, mid);
      if (info.name == null) {
        if (!mounted) return;
        setState(() {
          fetching = false;
          error = '没找到这个 UID，确认一下数字对不对';
        });
        return;
      }
      List<int>? bytes;
      Color? color;
      if (info.face != null) {
        bytes = await AvatarStore.fetchBytes(info.face!);
        if (bytes != null) color = await dominantColorOf(Uint8List.fromList(bytes));
      }
      if (!mounted) return;
      setState(() {
        fetching = false;
        fetchedName = info.name;
        faceBytes = bytes;
        accent = color;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        fetching = false;
        error = '取资料失败：${'$e'.split('\n').first}';
      });
    }
  }

  Future<void> _submit() async {
    final name = (fetchedName ?? nickCtrl.text.trim()).trim();
    if (name.isEmpty) return;
    final id = widget.state.addGame(
      name: name,
      accent: (accent ?? accentPresets.first.seed).toARGB32(),
      uid: normalizeUid(uidCtrl.text),
    );
    if (faceBytes != null) await AvatarStore.saveBytes(id, faceBytes!);
    if (!mounted) return;
    Navigator.of(context).pop(id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canSubmit = (fetchedName ?? nickCtrl.text).trim().isNotEmpty && !fetching;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 4, 20, 24 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('添加游戏', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('填 B 站官号 UID 就行，名称、头像和标识色会自动取回来。', style: theme.textTheme.labelSmall),
          const SizedBox(height: 16),
          TextField(
            controller: uidCtrl,
            keyboardType: TextInputType.number,
            onChanged: _onUidChanged,
            decoration: InputDecoration(
              labelText: '官号 UID',
              hintText: 'B 站空间地址里那串数字',
              suffixIcon: fetching
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: nickCtrl,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: '昵称（可选）',
              hintText: '填了就用它，留空用官号名',
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 10),
            Text(error!, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.error)),
          ],
          if (fetchedName != null) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppShapes.nestedRadius),
                  child: faceBytes == null
                      ? Container(width: 44, height: 44, color: (accent ?? theme.colorScheme.primary).withValues(alpha: 0.16))
                      : Image.memory(Uint8List.fromList(faceBytes!), width: 44, height: 44, fit: BoxFit.cover),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(fetchedName!, style: theme.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text(
                        '标识色取自头像',
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: accent ?? theme.colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: canSubmit ? _submit : null,
              child: Text(uidCtrl.text.trim().isEmpty ? '添加（只填昵称）' : '添加并拉取这个号'),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '添加后会立刻单独刷新这个号，只替换它自己的日程。',
            style: theme.textTheme.labelSmall,
          ),
          // 取 B 站资料要真跑一个 WebView；给 1×1 就够，不占版面
          SizedBox(width: 1, height: 1, child: WebViewWidget(controller: _web)),
        ],
      ),
    );
  }
}