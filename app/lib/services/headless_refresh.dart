import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:webview_flutter/webview_flutter.dart';

import '../model.dart';
import 'event_diff.dart';
import 'llm_deduper.dart';
import 'llm_normalizer.dart';
import 'prefs.dart';

/// 无人值守刷新：不依赖界面里的 WebView，直接用 WebView 的 cookie 发 HTTP 请求。
///
/// 这条链路存在的意义是「定时自动刷新」——后台没有界面，起不了 WebView，
/// 所以把 cookie 从 CookieManager 里取出来，换成普通的 HttpClient 请求。
class HeadlessRefresh {
  static const _ua =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36';

  /// 一轮完整的自动刷新。返回给通知用的摘要。
  static Future<HeadlessResult> run() async {
    final startedAt = DateTime.now();
    try {
      final cookies = await _cookieHeader();
      if (cookies.isEmpty) {
        return const HeadlessResult(ok: false, message: '没有登录态，自动刷新跳过');
      }

      final bindings = await Prefs.loadBindings();
      if (bindings.isEmpty) {
        return const HeadlessResult(ok: false, message: '还没有绑定官号');
      }

      final maxPosts = await Prefs.loadBiliMaxPosts();
      final cfg = await Prefs.loadLlm();
      final config = LlmConfig(
        baseUrl: cfg['baseUrl'] ?? LlmConfig.fallback.baseUrl,
        apiKey: cfg['apiKey'] ?? '',
        model: cfg['model'] ?? LlmConfig.fallback.model,
      );
      if (!config.ready) {
        return const HeadlessResult(ok: false, message: '还没配置大模型 key');
      }

      final fresh = <GameEvent>[];
      final diag = <String>[];
      var failed = 0;

      for (final entry in bindings.entries) {
        final game = entry.key;
        try {
          final res = await _fetchSpace(cookies, entry.value, maxPosts);
          final picked = _prefilter(res.items, maxPosts);
          var passed = 0;
          for (final item in picked) {
            try {
              final event = await _normalize(item, game, config);
              if (event != null) {
                fresh.addAll(event);
                passed++;
              }
            } catch (e) {
              diag.add('解析异常: ${'$e'.split('\n').first}');
            }
          }
          diag.add('$game: code=${res.code} 拉到=${res.items.length} 送解析=${picked.length} '
              '通过=$passed 未通过=${picked.length - passed}');
          await Future<void>.delayed(const Duration(milliseconds: 1500));
        } catch (_) {
          failed++;
        }
      }

      if (fresh.isEmpty) {
        return HeadlessResult(
          ok: false,
          message: '没有解析出事件｜bindings=${bindings.length} cookies=${cookies.length} '
              'failed=$failed｜${diag.join(' / ')}',
        );
      }

      final stored = (await Prefs.loadLiveEvents()).map(GameEvent.fromJson).toList();
      final beforeIds = {for (final e in stored) e.id};
      final merged = mergeEvents(stored, fresh, startedAt);
      final ids = fresh.map((e) => e.id).toSet();
      final kept = stored.where((e) => !ids.contains(e.id));
      var next = backfillRanges([...merged.events, ...kept]);
      // 语义去重：同一件事的多种说法只留一条（含历史遗留重复；模型不可用就退回纯规则）
      next = backfillRanges(await LlmDeduper.dedupeSemantically(next, config: config));
      await Prefs.saveLiveEvents(next.map((e) => e.toJson()).toList());
      await Prefs.saveLiveFetchedAt(startedAt);

      final afterIds = {for (final e in next) e.id};
      final added = afterIds.difference(beforeIds).length;
      final removed = beforeIds.difference(afterIds).length;
      final summary = '入库 ${next.length} 条，新增 $added 条，删除 $removed 条'
          '${merged.changes.isEmpty ? '' : '，改期 ${merged.changes.length} 项'}'
          '${failed > 0 ? '，$failed 个号失败' : ''}';
      return HeadlessResult(
        ok: true,
        message: '$summary（${diag.join(' / ')}）',
        added: added,
        removed: removed,
      );
    } catch (e) {
      return HeadlessResult(ok: false, message: '自动刷新失败：${'$e'.split('\n').first}');
    }
  }

  static Future<String> _cookieHeader() async {
    try {
      final cookies = await WebViewCookieManager().getCookies(
        domain: Uri.parse('https://api.bilibili.com'),
      );
      if (cookies.isEmpty) return '';
      return cookies.map((c) => '${c.name}=${c.value}').join('; ');
    } catch (_) {
      return '';
    }
  }

  static Future<({int code, List<dynamic> items})> _fetchSpace(
    String cookies,
    String mid,
    int maxPosts,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      // 接口一页约 12 条，按需要的条数翻页；上限 6 页，别把风控惹毛
      final pages = ((maxPosts / 12).ceil()).clamp(1, 6);
      final items = <dynamic>[];
      var offset = '';
      var code = 0;
      for (var page = 0; page < pages; page++) {
        final uri = Uri.parse(
          'https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/space'
          '?host_mid=$mid&offset=${Uri.encodeComponent(offset)}&timezone_offset=-480'
          '&features=itemOpusStyle,listOnlyfans,opusBigCover,onlyfansVote',
        );
        final request = await client.getUrl(uri);
        request.headers
          ..set(HttpHeaders.userAgentHeader, _ua)
          ..set(HttpHeaders.refererHeader, 'https://space.bilibili.com/$mid/dynamic')
          ..set(HttpHeaders.cookieHeader, cookies);
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body);
        if (json is! Map) {
          code = -1;
          break;
        }
        code = (json['code'] as num?)?.toInt() ?? -1;
        if (code != 0) break;
        final data = json['data'];
        if (data is! Map) break;
        final pageItems = data['items'];
        if (pageItems is List) items.addAll(pageItems);
        // 按「预筛后可用条数」决定是否继续翻页，避免设置 20 却只解析 13 条
        if (_prefilter(items, maxPosts).length >= maxPosts) break;
        final next = data['offset'];
        if (data['has_more'] != true || next is! String || next.isEmpty) break;
        offset = next;
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
      return (code: code, items: items);
    } catch (e) {
      return (code: -2, items: const <dynamic>[]);
    } finally {
      client.close(force: true);
    }
  }

  static List<Map<String, dynamic>> _prefilter(List<dynamic> items, int maxPosts) {
    final out = <Map<String, dynamic>>[];
    for (final raw in items) {
      if (raw is! Map) continue;
      final item = raw.cast<String, dynamic>();
      final text = _textOf(item);
      if (text.length < 10) continue;
      final hasKeyword = const ['活动', '维护', '版本', '兑换码', '卡池', '寻访', '祈愿', '跃迁', '补偿', '前瞻', '截止', '结束', '开启', '开放', '预约', '发放']
          .any(text.contains);
      final hasTime = RegExp(r'\d{1,2}\s*月\s*\d{1,2}\s*[日号]|\d{1,2}\s*[:：]\s*\d{2}|本周|下周|今日|明天|版本更新后|维护后')
          .hasMatch(text);
      if (!hasKeyword && !hasTime) continue;
      item['_text'] = text;
      out.add(item);
      if (out.length >= maxPosts) break;
    }
    return out;
  }

  static Future<List<GameEvent>?> _normalize(
    Map<String, dynamic> item,
    String gameId,
    LlmConfig config,
  ) async {
    final text = item['_text'] as String? ?? _textOf(item);
    if (text.length < 8) return null;
    final outcome = await LlmNormalizer.normalize(
      text: text,
      author: _authorOf(item),
      publishedAt: _timeOf(item),
      config: config,
      fallbackGameId: gameId,
    );
    final n = outcome.event;
    if (n == null) return null;

    final id = 'b${_idOf(item)}';
    final base = GameEvent(
      id: id,
      gameId: gameId,
      type: n.type,
      title: n.title,
      start: n.start,
      end: n.end,
      status: n.confidence >= 85 && n.start != null ? EventStatus.confirmed : EventStatus.tentative,
      confidence: n.confidence,
      summary: n.summary,
      fetchedAt: DateTime.now(),
      sourceName: 'B站动态 · ${_authorOf(item)}',
      sourceUrl: 'https://t.bilibili.com/${_idOf(item)}',
      version: n.version,
      tags: n.tags,
      sourceHash: contentHash(text),
      revisions: const [],
    );

    final isStartType = base.type == '活动开始' || base.type == '卡池开始';
    if (isStartType && base.start != null && base.end != null) {
      final closeType = base.type == '活动开始' ? '活动结束' : '卡池结束';
      String closeTitle(String raw) {
        if (raw.contains('开启')) return raw.replaceAll('开启', '结束');
        if (raw.contains('开始')) return raw.replaceAll('开始', '结束');
        return '$raw（截止）';
      }

      return [
        _copy(base, id: '$id-start', type: base.type, start: base.start, displayEnd: base.end),
        _copy(base, id: '$id-end', type: closeType, end: base.end, title: closeTitle(base.title)),
      ];
    }
    return [base];
  }

  static GameEvent _copy(
    GameEvent e, {
    required String id,
    String? type,
    String? title,
    DateTime? start,
    DateTime? end,
    DateTime? displayEnd,
  }) =>
      GameEvent(
        id: id,
        gameId: e.gameId,
        type: type ?? e.type,
        title: title ?? e.title,
        start: start,
        end: end,
        status: e.status,
        confidence: e.confidence,
        summary: e.summary,
        fetchedAt: e.fetchedAt,
        sourceName: e.sourceName,
        sourceUrl: e.sourceUrl,
        version: e.version,
        tags: e.tags,
        sourceHash: e.sourceHash,
        displayEnd: displayEnd,
        revisions: const [],
      );

  static String _textOf(Map<String, dynamic> item) {
    final modules = (item['modules'] as Map?)?.cast<String, dynamic>() ?? const {};
    final dyn = (modules['module_dynamic'] as Map?)?.cast<String, dynamic>() ?? const {};
    final desc = (dyn['desc'] as Map?)?['text'] as String? ?? '';
    if (desc.trim().isNotEmpty) return desc.trim();
    final major = (dyn['major'] as Map?)?.cast<String, dynamic>() ?? const {};
    final opus = (major['opus'] as Map?)?.cast<String, dynamic>();
    if (opus != null) {
      final summary = (opus['summary'] as Map?)?['text'] as String? ?? '';
      final title = opus['title'] as String? ?? '';
      return '${title.isEmpty ? '' : '$title '}$summary'.trim();
    }
    return '';
  }

  static String _authorOf(Map<String, dynamic> item) {
    final modules = (item['modules'] as Map?)?.cast<String, dynamic>() ?? const {};
    final author = (modules['module_author'] as Map?)?.cast<String, dynamic>() ?? const {};
    return author['name'] as String? ?? '官方';
  }

  static DateTime _timeOf(Map<String, dynamic> item) {
    final modules = (item['modules'] as Map?)?.cast<String, dynamic>() ?? const {};
    final author = (modules['module_author'] as Map?)?.cast<String, dynamic>() ?? const {};
    // pub_ts 有时是字符串，强转会抛 type cast（和之前 WebView 版踩过同一个坑）
    final raw = author['pub_ts'];
    final ts = raw is num ? raw.toInt() : int.tryParse('$raw');
    if (ts != null && ts > 0) return DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    return DateTime.now();
  }

  static String _idOf(Map<String, dynamic> item) => '${item['id_str'] ?? item['id'] ?? ''}';
}

class HeadlessResult {
  const HeadlessResult({
    required this.ok,
    required this.message,
    this.added = 0,
    this.removed = 0,
  });

  final bool ok;

  /// 完整播报用的一行摘要（含每款游戏的拉取 / 通过 / 未通过）
  final String message;

  /// 这一轮新增的事件条数（按 id 比）
  final int added;

  /// 这一轮删除的事件条数
  final int removed;
}
