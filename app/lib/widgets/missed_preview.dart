import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../app_state.dart';
import '../model.dart';
import '../screens/web_page.dart';
import '../services/llm_normalizer.dart';
import '../services/debug_log.dart';
import '../services/prefs.dart';
import '../services/preview_finder.dart';
import '../theme.dart';

/// 「错过前瞻」卡片：自动找一个总结视频，把内容压成要点显示出来，并给跳转链接。
class MissedPreviewCard extends StatefulWidget {
  const MissedPreviewCard({
    super.key,
    required this.state,
    required this.event,
    required this.game,
  });

  final AppState state;
  final GameEvent event;
  final Game? game;

  @override
  State<MissedPreviewCard> createState() => _MissedPreviewCardState();
}

class _MissedPreviewCardState extends State<MissedPreviewCard> {
  late final WebViewController _web;
  PreviewSummary? summary;
  bool loading = true;
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
    // 等首帧之后：WebViewWidget 还没挂到树上时，loadRequest 会直接失败
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(const Duration(milliseconds: 400), _load);
    });
  }

  Future<void> _load() async {
    final cached = await Prefs.loadPreviewSummary(widget.event.id);
    if (cached != null && cached.isNotEmpty) {
      final parsed = PreviewSummary.fromJson(jsonDecode(cached));
      if (parsed != null) {
        if (!mounted) return;
        setState(() {
          summary = parsed;
          loading = false;
        });
        return;
      }
    }
    await _find();
  }

  Future<void> _find() async {
    await DebugLog.write('preview find start id=${widget.event.id}');
    if (!mounted) return;
    setState(() {
      loading = true;
      error = null;
    });

    final cfg = await Prefs.loadLlm();
    final config = LlmConfig(
      baseUrl: cfg['baseUrl'] ?? LlmConfig.fallback.baseUrl,
      apiKey: cfg['apiKey'] ?? '',
      model: cfg['model'] ?? LlmConfig.fallback.model,
    );
    if (!config.ready) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = '还没配置大模型 key，没法把视频转成文字';
      });
      return;
    }

    try {
      final result = await PreviewFinder.build(
        _web,
        gameName: widget.game?.name ?? '',
        eventTitle: widget.event.title,
        config: config,
      );
      if (!mounted) return;
      await DebugLog.write('preview result=${result == null ? 'null' : result.bvid}');
      if (result == null) {
        setState(() {
          loading = false;
          error = '没找到合适的总结视频';
        });
        return;
      }
      await Prefs.savePreviewSummary(widget.event.id, jsonEncode(result.toJson()));
      if (!mounted) return;
      setState(() {
        summary = result;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = '找总结失败：${'$e'.split('\n').first}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppShapes.nestedRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Text('错过前瞻 · 帮你找总结', style: theme.textTheme.labelLarge),
            ],
          ),
          const SizedBox(height: 8),
          if (loading) ...[
            Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
                ),
                const SizedBox(width: 8),
                Text('正在找总结视频…', style: theme.textTheme.bodySmall),
              ],
            ),
          ] else if (summary != null) ...[
            for (final line in summary!.summary.split('\n'))
              if (line.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    line.trim(),
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
                  ),
                ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${summary!.title}${summary!.hasSubtitle ? '' : '（仅简介）'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => WebPageScreen(url: summary!.url, title: '总结视频'),
                    ),
                  ),
                  child: const Text('打开原视频'),
                ),
              ],
            ),
          ] else ...[
            Text(error ?? '没有找到总结', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: _find, child: const Text('再找一次')),
            ),
          ],
          // 取视频要真跑一个 WebView；1×1 不占版面
          SizedBox(width: 1, height: 1, child: WebViewWidget(controller: _web)),
        ],
      ),
    );
  }
}
