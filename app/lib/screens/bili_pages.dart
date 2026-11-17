import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../app_state.dart';
import '../model.dart';
import '../services/bili_service.dart';
import '../services/event_diff.dart';
import '../services/llm_normalizer.dart';
import '../services/avatar_store.dart';
import '../services/prefs.dart';
import '../services/reminder_service.dart';
import '../theme.dart';

/// 应用内登录：cookie 落在 WebView 自己的 jar 里，App 代码不读也不存 SESSDATA。
class BiliLoginPage extends StatefulWidget {
  const BiliLoginPage({super.key});

  @override
  State<BiliLoginPage> createState() => _BiliLoginPageState();
}

class _BiliLoginPageState extends State<BiliLoginPage> {
  late final WebViewController controller;
  bool checking = false;

  @override
  void initState() {
    super.initState();
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36',
      )
      ..loadRequest(Uri.parse('https://passport.bilibili.com/login'));
  }

  Future<void> _confirm() async {
    setState(() => checking = true);
    // 先在 bilibili.com 走一圈，让 cookie 落到 api.bilibili.com 能读到
    await controller.loadRequest(Uri.parse('https://www.bilibili.com/'));
    await Future<void>.delayed(const Duration(seconds: 1));
    final state = await BiliService.loginProbe(controller);
    if (!mounted) return;
    setState(() => checking = false);
    switch (state) {
      case 'ok':
        Navigator.of(context).pop(true);
        break;
      case 'not-login':
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('接口说未登录：可能还没登完，或登录的是别的账号')),
        );
        break;
      default:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('接口没返回 JSON（被网络或风控拦了），稍后再试')),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('登录 B 站'),
        actions: [
          TextButton(
            onPressed: checking ? null : _confirm,
            child: Text(checking ? '检测中…' : '我已登录'),
          ),
        ],
      ),
      body: SafeArea(child: WebViewWidget(controller: controller)),
    );
  }
}

/// 从 B 站拉动态 → 过大模型规范化 → 写入本机事件。
class BiliRefreshDialog extends StatefulWidget {
  const BiliRefreshDialog({super.key, required this.state, this.onlyGameId});

  final AppState state;

  /// 非空时只刷新这一款游戏（添加游戏后立刻拉一次用）
  final String? onlyGameId;

  @override
  State<BiliRefreshDialog> createState() => _BiliRefreshDialogState();
}

class _BiliRefreshDialogState extends State<BiliRefreshDialog> {
  late final WebViewController controller;
  String message = '准备中…';
  int done = 0;
  int total = 1;
  bool finished = false;
  int added = 0;
  final List<String> log = [];
  final List<String> failures = [];
  final Map<String, _GameStat> stats = {};
  String modelLabel = '';
  String? account;
  int fetched = 0;
  int rawFetched = 0;

  @override
  void initState() {
    super.initState();
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36',
      );
    _run();
  }

  void _progress(String text, int d, int t) {
    if (!mounted) return;
    setState(() {
      message = text;
      done = d;
      total = t < 1 ? 1 : t;
    });
  }

  static const _eventKeywords = [
    '活动', '维护', '版本', '兑换码', '卡池', '寻访', '祈愿', '跃迁',
    '补偿', '前瞻', '截止', '结束', '开启', '开放', '预约', '发放',
  ];

  static final RegExp _timeRe = RegExp(
    r'\d{1,2}\s*月\s*\d{1,2}\s*[日号]'
    r'|\d{1,2}\s*[./]\s*\d{1,2}'
    r'|\d{1,2}\s*[:：]\s*\d{2}'
    r'|本周|下周|今日|明天|版本更新后|维护后',
  );

  /// 有事件关键词 + 有时间线索：最可能是公告
  static bool _looksLikeEvent(String text) {
    if (text.length < 10) return false;
    return _eventKeywords.any(text.contains) && _timeRe.hasMatch(text);
  }

  /// 仅有时间线索（含日期/时刻/相对时间）：兜底池，用来补足名额
  static bool _hasTimeSignal(String text) {
    if (text.length < 10) return false;
    return _timeRe.hasMatch(text);
  }

  /// 取一条动态的预筛等级：2 = 严格通过，1 = 只命中时间，0 = 不要
  static int _prefilterRank(String text) {
    if (_looksLikeEvent(text)) return 2;
    if (_hasTimeSignal(text)) return 1;
    return 0;
  }

  Future<void> _run() async {
    final now = DateTime.now();
    final events = <String, GameEvent>{};

    final cfgMap = await Prefs.loadLlm();
    final config = LlmConfig(
      baseUrl: cfgMap['baseUrl'] ?? LlmConfig.fallback.baseUrl,
      apiKey: cfgMap['apiKey'] ?? '',
      model: cfgMap['model'] ?? LlmConfig.fallback.model,
    );
    modelLabel = '${config.model} @ ${Uri.tryParse(config.baseUrl)?.host ?? config.baseUrl}';
    if (!config.ready) {
      _finish('还没有配置大模型 key');
      return;
    }

    try {
      final name = await BiliService.accountName(controller);
      if (name == null) {
        _finish('登录已失效，请重新登录 B 站');
        return;
      }
      if (mounted) setState(() => account = name);

      final games = widget.state.gameMap;
      // 只刷游戏库里还存在的游戏：删掉的游戏若留下绑定，会白拉一遍，
      // 统计数字也会和界面对不上。
      final all = <String, String>{
        for (final e in widget.state.bindings.entries)
          if (games.containsKey(e.key)) e.key: e.value,
      };
      final bindings = widget.onlyGameId == null
          ? all
          : {
              if (all.containsKey(widget.onlyGameId)) widget.onlyGameId!: all[widget.onlyGameId]!,
            };
      if (bindings.isEmpty) {
        _finish('这个游戏还没有绑定官号 UID');
        return;
      }
      final items = <Map<String, dynamic>>[];
      var rawFetched = 0;
      // 只按账号限流，不再设全局上限：以前 4 个号就能吃满 30 条，
      // 后加的游戏一条都没机会进入解析。
      const perAccount = 10;

      var index = 0;
      for (final entry in bindings.entries) {
        index++;
        final name = games[entry.key]?.name ?? entry.key;
        _progress('拉取 $name 的动态（$index/${bindings.length}）', index - 1, bindings.length);
        try {
          final list = await BiliService.fetchSpace(controller, entry.value, pages: 2);
          rawFetched += list.length;

          // 顺手把官号头像存下来，列表和详情用真头像
          final face = await BiliService.faceOf(controller, entry.value);
          if (face != null) await AvatarStore.download(entry.key, face);

          // 预筛分两级：先收「关键词 + 时间」的，再用「只有时间」的补足名额，
          // 避免把没有关键词但确实带日期的公告漏掉。
          final strict = <Map<String, dynamic>>[];
          final loose = <Map<String, dynamic>>[];
          for (final item in list) {
            final text = BiliService.dynamicsText(item);
            final rank = _prefilterRank(text);
            if (rank == 2) {
              strict.add({...item, '_game': entry.key, '_name': name});
            } else if (rank == 1) {
              loose.add({...item, '_game': entry.key, '_name': name});
            }
          }
          final taken = <Map<String, dynamic>>[
            ...strict,
            ...loose,
          ].take(perAccount).toList();
          items.addAll(taken);
          stats[entry.key] = _GameStat(
            raw: list.length,
            strict: strict.length,
            loose: loose.length,
            taken: taken.length,
          );
        } catch (e) {
          final reason = '$e'.split('\n').first;
          log.add('$name：拉取失败 $reason');
          failures.add('$name｜拉取失败：$reason');
        }
        // 多个号连着打接口容易被风控，账号之间拉开一点
        await Future<void>.delayed(const Duration(milliseconds: 2500));
      }
      fetched = items.length;
      this.rawFetched = rawFetched;

      if (items.isEmpty) {
        _finish('没有拉到动态');
        return;
      }

      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        final gameId = item['_game'] as String;
        final gameName = item['_name'] as String;
        _progress('大模型解析（${i + 1}/${items.length}）', i, items.length);

        final text = BiliService.dynamicsText(item);
        if (text.length < 8) {
          failures.add('$gameName｜正文为空（${BiliService.idOf(item)}）');
          continue;
        }
        final outcome = await LlmNormalizer.normalize(
          text: text,
          author: BiliService.authorOf(item),
          publishedAt: BiliService.publishedAtOf(item),
          config: config,
          fallbackGameId: gameId,
        );
        if (outcome.event == null) {
          stats[gameId]?.failed += 1;
          failures.add('$gameName｜${outcome.error ?? '未知原因'}（${BiliService.idOf(item)}）');
          continue;
        }
        stats[gameId]?.parsed += 1;
        final normalized = outcome.event!;
        final event = BiliService.fromNormalized(
          n: normalized,
          author: BiliService.authorOf(item),
          dynamicId: BiliService.idOf(item),
          fetchedAt: now,
          sourceHash: contentHash(text),
        );
        // 游戏以绑定关系为准（模型判错时仍归到你绑的那个号）
        GameEvent build({required String id, required String type, DateTime? start, DateTime? end, String? title}) => GameEvent(
              id: id,
              gameId: gameId,
              type: type,
              title: title ?? event.title,
              start: start,
              end: end,
              status: event.status,
              confidence: event.confidence,
              summary: event.summary,
              fetchedAt: event.fetchedAt,
              sourceName: event.sourceName,
              sourceUrl: event.sourceUrl,
              version: event.version,
              tags: event.tags,
              sourceHash: event.sourceHash,
              revisions: const [],
            );

        // 有起止区间的“开始类”事件拆成两条：开始一条、结束一条。
        // 否则类型写着“开始”，圆环和倒计时却落在结束那天，读起来是矛盾的。
        final isStartType = event.type == '活动开始' || event.type == '卡池开始';
        if (isStartType && event.start != null && event.end != null) {
          final closeType = event.type == '活动开始' ? '活动结束' : '卡池结束';
          // 标题也跟着改，否则会出现「中坚甄选开启」配「卡池结束」的别扭组合
          String closeTitle(String raw) {
            if (raw.contains('开启')) return raw.replaceAll('开启', '结束');
            if (raw.contains('开始')) return raw.replaceAll('开始', '结束');
            return '$raw（截止）';
          }

          events['${event.id}-start'] = build(id: '${event.id}-start', type: event.type, start: event.start);
          events['${event.id}-end'] = build(id: '${event.id}-end', type: closeType, end: event.end, title: closeTitle(event.title));
        } else {
          events[event.id] = build(id: event.id, type: event.type, start: event.start, end: event.end);
        }
      }

      added = events.length;
      if (events.isEmpty) {
        // 一条都没解析出来时不要覆盖原有数据，否则一次失败会把日历清空
        _finish('没有解析出事件（$fetched 条动态全部未通过），已保留原有 ${widget.state.liveEvents.length} 条');
        return;
      }
      final changes = await widget.state.applyLive(events.values.toList(), onlyGame: widget.onlyGameId);

      if (changes.isNotEmpty) {
        // 改期是这套链路最有价值的部分：立刻推一条，别等用户自己发现
        await ReminderService.notifyNow(
          title: '官方改期：${changes.length} 项',
          body: changes.length == 1
              ? changes.first.summary
              : '共 ${changes.length} 项，例如：${changes.first.summary}',
        );
        log.add('检测到 ${changes.length} 项变化，已发一条改期通知');
        for (final c in changes.take(3)) {
          log.add('· ${c.summary}');
        }
      }
      final scope = widget.onlyGameId;
      final stored = widget.state.liveEvents
          .where((e) => scope == null || e.gameId == scope)
          .toList();
      final visible = stored
          .where((e) => widget.state.showDeadlineEvents || !AppState.isDeadlineEvent(e))
          .length;
      debugPrint('[NijiCal] refresh scope=${scope ?? 'all'} parsed=$added '
          'stored=${stored.length} visible=$visible fetched=$fetched '
          'failed=${failures.length} games=${stored.map((e) => e.gameId).toSet()}');

      for (final entry in stats.entries) {
        final name = widget.state.gameMap[entry.key]?.name ?? entry.key;
        final mine = widget.state.liveEvents.where((e) => e.gameId == entry.key).toList();
        final hidden = mine.where(AppState.isDeadlineEvent).length;
        log.add('$name：拉到 ${entry.value.raw} · 送解析 ${entry.value.taken} · '
            '入库 ${mine.length}${hidden > 0 ? '（其中 $hidden 条截止类）' : ''} · '
            '未通过 ${entry.value.failed}');
      }

      final hiddenNote = stored.isNotEmpty && visible == 0
          ? '｜${stored.length} 条全是截止类事件，已被「显示截止事件」开关隐藏'
          : '';
      _finish('完成：$added 条事件｜${bindings.length} 个账号 · 送解析 $fetched 条（共拉 $rawFetched 条），${failures.length} 条未通过'
          '${changes.isEmpty ? '' : '｜改期 ${changes.length} 项'}$hiddenNote');
    } catch (e) {
      _finish('失败：${'$e'.split('\n').first}');
    }
  }

  void _finish(String text) {
    if (!mounted) return;
    setState(() {
      message = text;
      finished = true;
      done = total;
    });
  }

  String _diagnostics() {
    final buf = StringBuffer()
      ..writeln('NijiCal 刷新诊断')
      ..writeln('时间：${DateTime.now().toIso8601String()}')
      ..writeln('模型：$modelLabel')
      ..writeln('结果：$message')
      ..writeln('动态 $rawFetched 条 / 预筛 $fetched 条 / 入库 $added 条 / 未通过 ${failures.length} 条');
    if (log.isNotEmpty) {
      buf.writeln('--- 拉取 ---');
      for (final line in log) {
        buf.writeln(line);
      }
    }
    if (failures.isNotEmpty) {
      buf.writeln('--- 未通过（最多 20 条）---');
      for (final line in failures.take(20)) {
        buf.writeln(line);
      }
    }
    return buf.toString();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.black.withValues(alpha: 0.35),
      child: Stack(
        children: [
          // B 站这边取的是接口 JSON，不依赖视口尺寸；给 1×1 就够执行 JS，
          // 也免得把一大段原始 JSON 铺在弹窗背后。
          Positioned(
            left: 0,
            top: 0,
            child: IgnorePointer(
              child: SizedBox(
                width: 1,
                height: 1,
                child: WebViewWidget(controller: controller),
              ),
            ),
          ),
          Center(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                child: SizedBox(
                  width: 320,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text('从 B 站刷新', style: theme.textTheme.titleLarge),
                          const Spacer(),
                          if (account != null)
                            Text(
                              '@$account',
                              style: theme.textTheme.labelSmall,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        value: finished ? 1 : done / (total == 0 ? 1 : total),
                        minHeight: 6,
                        borderRadius: BorderRadius.circular(AppShapes.pillRadius),
                        backgroundColor: theme.colorScheme.surfaceContainerHighest,
                      ),
                      const SizedBox(height: 12),
                      Text(message, style: theme.textTheme.bodyMedium),
                      if (finished && log.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 150),
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (final line in log)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 3),
                                    child: Text(line, style: theme.textTheme.labelSmall),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      if (failures.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          '未通过（${failures.length}）',
                          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.error),
                        ),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 180),
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (final line in failures)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 4),
                                    child: Text(line, style: theme.textTheme.labelSmall),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        '只读你绑定的官号；每条动态都先过大模型规范化，抽不出时间的不入库。',
                        style: theme.textTheme.labelSmall,
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (finished)
                            TextButton(
                              onPressed: () async {
                                await Clipboard.setData(ClipboardData(text: _diagnostics()));
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('诊断信息已复制')),
                                );
                              },
                              child: const Text('复制诊断'),
                            ),
                          TextButton(
                            onPressed: finished ? () => Navigator.of(context).pop(added > 0) : null,
                            child: Text(finished ? '完成' : '刷新中…'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单个账号一轮刷新的漏斗数字
class _GameStat {
  _GameStat({required this.raw, required this.strict, required this.loose, required this.taken});

  final int raw;
  final int strict;
  final int loose;
  final int taken;
  int parsed = 0;
  int failed = 0;
  String? error;
}
