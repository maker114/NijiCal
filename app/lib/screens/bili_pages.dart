import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../app_state.dart';
import '../model.dart';
import '../services/bili_service.dart';
import '../services/llm_normalizer.dart';
import '../services/prefs.dart';
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
  const BiliRefreshDialog({super.key, required this.state});

  final AppState state;

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
  String modelLabel = '';
  int fetched = 0;

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
      if (!await BiliService.isLoggedIn(controller)) {
        _finish('登录已失效，请重新登录 B 站');
        return;
      }

      final games = widget.state.data?.gamesById ?? {};
      final bindings = widget.state.bindings;
      final items = <Map<String, dynamic>>[];

      var index = 0;
      for (final entry in bindings.entries) {
        index++;
        final name = games[entry.key]?.name ?? entry.key;
        _progress('拉取 $name 的动态（$index/${bindings.length}）', index - 1, bindings.length);
        try {
          final list = await BiliService.fetchSpace(controller, entry.value, pages: 2);
          for (final item in list) {
            items.add({...item, '_game': entry.key, '_name': name});
          }
          log.add('$name：${list.length} 条动态');
        } catch (e) {
          final reason = '$e'.split('\n').first;
          log.add('$name：拉取失败 $reason');
          failures.add('$name｜拉取失败：$reason');
        }
        await Future<void>.delayed(const Duration(milliseconds: 1200));
      }
      fetched = items.length;

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
        );
        if (outcome.event == null) {
          failures.add('$gameName｜${outcome.error ?? '未知原因'}（${BiliService.idOf(item)}）');
          continue;
        }
        final normalized = outcome.event!;
        final event = BiliService.fromNormalized(
          n: normalized,
          author: BiliService.authorOf(item),
          dynamicId: BiliService.idOf(item),
          fetchedAt: now,
        );
        // 游戏以绑定关系为准（模型判错时仍归到你绑的那个号）
        events[event.id] = GameEvent(
          id: event.id,
          gameId: gameId,
          type: event.type,
          title: event.title,
          start: event.start,
          end: event.end,
          status: event.status,
          confidence: event.confidence,
          summary: event.summary,
          fetchedAt: event.fetchedAt,
          sourceName: event.sourceName,
          sourceUrl: event.sourceUrl,
          version: event.version,
          tags: event.tags,
          revisions: const [],
        );
      }

      added = events.length;
      if (events.isEmpty) {
        // 一条都没解析出来时不要覆盖原有数据，否则一次失败会把日历清空
        _finish('没有解析出事件（$fetched 条动态全部未通过），已保留原有 ${widget.state.liveEvents.length} 条');
        return;
      }
      await widget.state.applyLive(events.values.toList());
      _finish('完成：$added 条事件｜$fetched 条动态，${failures.length} 条未通过');
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
      ..writeln('动态 $fetched 条 / 入库 $added 条 / 未通过 ${failures.length} 条');
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
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(opacity: 0.3, child: WebViewWidget(controller: controller)),
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
                      Text('从 B 站刷新', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        value: finished ? 1 : done / (total == 0 ? 1 : total),
                        minHeight: 6,
                        borderRadius: BorderRadius.circular(AppShapes.pillRadius),
                        backgroundColor: theme.colorScheme.surfaceContainerHighest,
                      ),
                      const SizedBox(height: 12),
                      Text(message, style: theme.textTheme.bodyMedium),
                      if (log.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        for (final line in log.take(6))
                          Text(line, style: theme.textTheme.labelSmall),
                      ],
                      if (failures.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          '未通过（${failures.length}）',
                          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.error),
                        ),
                        for (final line in failures.take(3))
                          Text(
                            line,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall,
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
