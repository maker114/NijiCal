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
  int gameDone = 0;
  int gameTotal = 1;
  int itemDone = 0;
  int itemTotal = 0;
  bool finished = false;
  int added = 0;
  final List<String> log = [];
  final List<String> failures = [];
  final Map<String, _GameStat> stats = {};
  String modelLabel = '';
  String? account;
  int fetched = 0;
  int rawFetched = 0;
  int gameRaw = 0; // 当前这个号实际抓到的原始动态条数
  List<String> gameOrder = const []; // 表格行顺序（绑定顺序）
  String? currentGameId; // 正在抓的号，表格里高亮

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

  void _progress(String text, {required int game, int item = 0, int itemTotal = 0}) {
    if (!mounted) return;
    setState(() {
      message = text;
      gameDone = game;
      itemDone = item;
      this.itemTotal = itemTotal;
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

      // 用户可配置每账号读取多少条历史动态（设置 → 读取条数）
      final perAccount = widget.state.biliMaxPosts;
      // 接口一页约 12 条。按「预筛后可用条数」决定是否继续翻页，
      // 否则会出现「设置 20 条、实际只有 13 条能解析」的落差。
      int usableCount(List<Map<String, dynamic>> items) {
        var n = 0;
        for (final item in items) {
          if (_prefilterRank(BiliService.dynamicsText(item)) > 0) n++;
        }
        return n;
      }
      final entries = bindings.entries.toList();
      gameOrder = entries.map((e) => e.key).toList();
      if (mounted) {
        setState(() {
          gameTotal = entries.length;
          gameDone = 0;
        });
      }

      for (var index = 0; index < entries.length; index++) {
        final entry = entries[index];
        final name = games[entry.key]?.name ?? entry.key;
        gameRaw = 0;
        currentGameId = entry.key;
        _progress(
          '拉取 $name 的动态',
          game: index,
          item: 0,
          itemTotal: 0,
        );

        var taken = <Map<String, dynamic>>[];
        try {
          final list = await BiliService.fetchSpace(
            controller,
            entry.value,
            pages: 6,
            stopWhen: (acc) => usableCount(acc) >= perAccount,
          );
          rawFetched += list.length;
          gameRaw = list.length;
          stats[entry.key] = _GameStat(raw: list.length, strict: 0, loose: 0, taken: 0);
          if (mounted) setState(() {});

          // 头像已缓存就不用再请求一次（少一次接口调用，少一分被限流的概率）
          if (AvatarStore.pathOf(entry.key) == null) {
            final face = await BiliService.faceOf(controller, entry.value);
            if (face != null) await AvatarStore.download(entry.key, face);
          }

          // 预筛分两级：先收「关键词 + 时间」的，再用「只有时间」的补足名额；
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
          taken = <Map<String, dynamic>>[...strict, ...loose].take(perAccount).toList();
          stats[entry.key] = _GameStat(
            raw: list.length,
            strict: strict.length,
            loose: loose.length,
            taken: taken.length,
          );
        } catch (e) {
          final reason = '$e'.split('\n').first;
          stats[entry.key] = _GameStat(raw: 0, strict: 0, loose: 0, taken: 0)..error = reason;
          failures.add('$name｜拉取失败：$reason');
          debugPrint('[NijiCal] fetch failed game=$name uid=${entry.value} reason=$reason');
          if (mounted) setState(() => gameDone = index + 1);
          await Future<void>.delayed(const Duration(milliseconds: 2500));
          continue;
        }

        fetched += taken.length;

        for (var j = 0; j < taken.length; j++) {
          final item = taken[j];
          _progress(
            '$name 解析（${j + 1}/${taken.length}）',
            game: index,
            item: j,
            itemTotal: taken.length,
          );
          await _parseOne(
            item: item,
            gameId: entry.key,
            gameName: name,
            config: config,
            now: now,
            events: events,
          );
          await Future<void>.delayed(const Duration(milliseconds: 120));
        }

        _progress('$name 完成', game: index + 1, item: taken.length, itemTotal: taken.length);
        // 多个号连着打接口容易被风控，账号之间拉开一点
        await Future<void>.delayed(const Duration(milliseconds: 2500));
      }

      added = events.length;
      if (events.isEmpty) {
        // 一条都没解析出来时不要覆盖原有数据，否则一次失败会把日历清空
        _finish('没有解析出事件（$fetched 条动态全部未通过），已保留原有 ${widget.state.liveEvents.length} 条');
        return;
      }
      // 记下刷新前的 ID 集合，用于算「新增 / 删除」
      final beforeIds = {
        for (final e in widget.state.liveEvents)
          if (widget.onlyGameId == null || e.gameId == widget.onlyGameId) e.id,
      };
      final changes = await widget.state.applyLive(events.values.toList(), onlyGame: widget.onlyGameId);
      final afterEvents = widget.state.liveEvents
          .where((e) => widget.onlyGameId == null || e.gameId == widget.onlyGameId)
          .toList();
      final afterIds = {for (final e in afterEvents) e.id};
      final newCount = afterIds.difference(beforeIds).length;
      final removedCount = beforeIds.difference(afterIds).length;
      final storedCount = afterEvents.length;

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
        if (entry.value.error != null) {
          log.add('$name：拉取失败 · ${entry.value.error}');
          continue;
        }
        final mine = widget.state.liveEvents.where((e) => e.gameId == entry.key).toList();
        final hidden = mine.where(AppState.isDeadlineEvent).length;
        log.add('$name：拉到 ${entry.value.raw} · 送解析 ${entry.value.taken} · '
            '入库 ${mine.length}${hidden > 0 ? '（其中 $hidden 条截止类）' : ''} · '
            '未通过 ${entry.value.failed}');
      }
      for (final line in failures) {
        debugPrint('[NijiCal] fail $line');
      }

      final hiddenNote = stored.isNotEmpty && visible == 0
          ? '｜${stored.length} 条全是截止类事件，已被「显示截止事件」开关隐藏'
          : '';
      currentGameId = null;
      _finish('已获取完成，共入库 $storedCount 条，其中新增 $newCount 条，删除 $removedCount 条'
          '${changes.isEmpty ? '' : '；改期 ${changes.length} 项'}$hiddenNote');
    } catch (e) {
      _finish('失败：${'$e'.split('\n').first}');
    }
  }

  /// 单条动态 → 事件（原样放进事件表）
  Future<void> _parseOne({
    required Map<String, dynamic> item,
    required String gameId,
    required String gameName,
    required LlmConfig config,
    required DateTime now,
    required Map<String, GameEvent> events,
  }) async {
    final text = BiliService.dynamicsText(item);
    if (text.length < 8) {
      failures.add('$gameName｜正文为空（${BiliService.idOf(item)}）');
      stats[gameId]?.failed += 1;
      return;
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
        return;
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
      GameEvent build({required String id, required String type, DateTime? start, DateTime? end, String? title, DateTime? displayEnd}) => GameEvent(
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
            displayEnd: displayEnd,
            revisions: const [],
          );

      // 有起止区间的“开始类”事件拆成两条：开始一条、结束一条。
      final isStartType = event.type == '活动开始' || event.type == '卡池开始';
      if (isStartType && event.start != null && event.end != null) {
        final closeType = event.type == '活动开始' ? '活动结束' : '卡池结束';
        String closeTitle(String raw) {
          if (raw.contains('开启')) return raw.replaceAll('开启', '结束');
          if (raw.contains('开始')) return raw.replaceAll('开始', '结束');
          return '$raw（截止）';
        }

        events['${event.id}-start'] = build(id: '${event.id}-start', type: event.type, start: event.start, displayEnd: event.end);
        events['${event.id}-end'] = build(id: '${event.id}-end', type: closeType, end: event.end, title: closeTitle(event.title));
      } else {
        events[event.id] = build(id: event.id, type: event.type, start: event.start, end: event.end);
      }
  }

  void _finish(String text) {
    if (!mounted) return;
    setState(() {
      message = text;
      finished = true;
      gameDone = gameTotal;
      itemDone = itemTotal;
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
                      // 两条进度条：整轮 / 本游戏，厚度一致
                      _ProgressBar(
                        label: '游戏 ${finished ? gameTotal : gameDone}/$gameTotal',
                        value: finished ? 1 : gameDone / (gameTotal == 0 ? 1 : gameTotal),
                      ),
                      const SizedBox(height: 8),
                      _ProgressBar(
                        label: itemTotal == 0
                            ? '本游戏 · 拉取中${gameRaw > 0 ? ' · 已拉到 $gameRaw 条' : ''}'
                            : '本游戏 ${finished ? itemTotal : itemDone}/$itemTotal'
                                '${gameRaw > 0 ? ' · 拉到 $gameRaw 条' : ''}',
                        value: itemTotal == 0
                            ? (finished ? 1 : 0)
                            : (finished ? 1 : itemDone / itemTotal),
                      ),
                      const SizedBox(height: 10),
                      Text(message, style: theme.textTheme.bodyMedium),
                      const SizedBox(height: 12),
                      _RefreshTable(
                        rows: [
                          for (final id in gameOrder)
                            _RefreshRow(
                              name: widget.state.gameMap[id]?.name ?? id,
                              accent: widget.state.gameMap[id] == null
                                  ? theme.colorScheme.primary
                                  : widget.state.gameAccentOf(widget.state.gameMap[id]!),
                              raw: stats[id]?.raw,
                              taken: stats[id]?.taken,
                              parsed: stats[id]?.parsed,
                              failed: stats[id]?.failed,
                              active: id == currentGameId,
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
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

/// 一条带标签的细进度条
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.label, required this.value});

  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = value.isNaN ? 0.0 : value.clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurface),
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppShapes.pillRadius),
          child: LinearProgressIndicator(
            value: v,
            minHeight: 6,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            color: theme.colorScheme.primary,
          ),
        ),
      ],
    );
  }
}

/// 刷新弹窗里的统计表：游戏 / 抓取 / 送审 / 入库 / 未通过
class _RefreshTable extends StatelessWidget {
  const _RefreshTable({required this.rows});

  final List<_RefreshRow> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final header = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(flex: 9, child: Text('游戏', style: header)),
              Expanded(flex: 3, child: Text('抓取', textAlign: TextAlign.center, style: header)),
              Expanded(flex: 3, child: Text('送审', textAlign: TextAlign.center, style: header)),
              Expanded(flex: 3, child: Text('入库', textAlign: TextAlign.center, style: header)),
              Expanded(flex: 3, child: Text('未通过', textAlign: TextAlign.center, style: header)),
            ],
          ),
        ),
        for (final row in rows) _RefreshTableRow(row: row),
      ],
    );
  }
}

class _RefreshRow {
  const _RefreshRow({
    required this.name,
    required this.accent,
    required this.active,
    this.raw,
    this.taken,
    this.parsed,
    this.failed,
  });

  final String name;
  final Color accent;
  final bool active;
  final int? raw;
  final int? taken;
  final int? parsed;
  final int? failed;
}

class _RefreshTableRow extends StatelessWidget {
  const _RefreshTableRow({required this.row});

  final _RefreshRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final valueStyle = theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    String show(int? v) => v == null ? '—' : '$v';
    return Container(
      decoration: BoxDecoration(
        color: row.active ? row.accent.withValues(alpha: 0.14) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
      child: Row(
        children: [
          Expanded(
            flex: 9,
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 16,
                  decoration: BoxDecoration(
                    color: row.accent,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    row.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: row.active ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(flex: 3, child: Text(show(row.raw), textAlign: TextAlign.center, style: valueStyle)),
          Expanded(flex: 3, child: Text(show(row.taken), textAlign: TextAlign.center, style: valueStyle)),
          Expanded(
            flex: 3,
            child: Text(
              show(row.parsed),
              textAlign: TextAlign.center,
              style: valueStyle?.copyWith(color: (row.parsed ?? 0) > 0 ? scheme.primary : null),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              show(row.failed),
              textAlign: TextAlign.center,
              style: valueStyle?.copyWith(color: (row.failed ?? 0) > 0 ? scheme.error : null),
            ),
          ),
        ],
      ),
    );
  }
}