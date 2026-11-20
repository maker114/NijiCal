import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../model.dart';
import 'llm_normalizer.dart';

/// 语义去重：让大模型判断「哪些条目其实是同一件事」。
///
/// 纯规则（titleFingerprint + 时间容差）能解决大部分重复，但抓不到
/// 「Zenless LIVE 2026」与「绝区零 2026 FES 布梦嘉年华」这种同一场活动的两种说法：
/// 标题毫无共同字词、又都是同一天同一时刻、常常都没有结束时间，
/// 按字面比较只能靠猜，而放宽到「时间相同就合并」会把当天真正并行的多个活动也并掉。
///
/// 所以只在「同一游戏、同一类型、开始时间相差 ≤10 分钟」的候选组里问模型，
/// 一次刷新最多一次额外调用；模型失败或返回不可用时，退回纯规则结果。
class LlmDeduper {
  /// 返回去掉语义重复后的列表（每组保留信息最全的那条）
  static Future<List<GameEvent>> dedupeSemantically(
    List<GameEvent> events, {
    required LlmConfig config,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    if (events.length < 2 || !config.ready) return events;

    final candidates = _candidates(events);
    if (candidates.isEmpty) return events;

    final items = <Map<String, dynamic>>[];
    final byIndex = <int, GameEvent>{};
    for (final group in candidates) {
      for (final e in group) {
        final i = items.length;
        items.add({
          'i': i,
          'game': e.gameId,
          'type': e.type,
          'start': _fmt(e.start),
          'end': _fmt(e.end),
          'title': e.title,
        });
        byIndex[i] = e;
      }
    }
    if (items.length < 2) return events;

    final groups = await _ask(items: items, config: config, timeout: timeout);
    if (groups == null) return events;

    final drop = <String>{};
    for (final group in groups) {
      final members = <GameEvent>[
        for (final i in group)
          if (byIndex[i] != null) byIndex[i]!,
      ];
      if (members.length < 2) continue;
      members.sort((a, b) => _score(b).compareTo(_score(a)));
      for (final e in members.skip(1)) {
        drop.add(e.id);
      }
    }
    if (drop.isEmpty) return events;
    // 保持原顺序，避免影响后续合并/改期判定的稳定性
    return events.where((e) => !drop.contains(e.id)).toList();
  }

  /// 同游戏、同类型、开始时间在同一个 10 分钟桶里的条目才值得问模型。
  /// 拆出来的「开始 / 结束」两条类型不同，不会被分到同一组。
  static List<List<GameEvent>> _candidates(List<GameEvent> events) {
    final buckets = <String, List<GameEvent>>{};
    for (final e in events) {
      final start = e.start;
      if (start == null) continue;
      final bucket = start.millisecondsSinceEpoch ~/ (10 * 60 * 1000);
      buckets
          .putIfAbsent('${e.gameId}|${e.type}|$bucket', () => <GameEvent>[])
          .add(e);
    }
    return [
      for (final group in buckets.values)
        if (group.length >= 2) group,
    ];
  }

  static int _score(GameEvent e) =>
      (e.end != null ? 4 : 0) +
      (e.displayEnd != null ? 4 : 0) +
      ((e.summary ?? '').isNotEmpty ? 2 : 0) +
      (e.title.length >= 6 ? 1 : 0);

  static String _fmt(DateTime? t) {
    if (t == null) return '-';
    final b = t.toUtc().add(const Duration(hours: 8));
    String two(int v) => v.toString().padLeft(2, '0');
    return '${b.year}-${two(b.month)}-${two(b.day)} ${two(b.hour)}:${two(b.minute)}';
  }

  static Future<List<List<int>>?> _ask({
    required List<Map<String, dynamic>> items,
    required LlmConfig config,
    required Duration timeout,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final uri = Uri.parse('${config.baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions');
      final request = await client.postUrl(uri).timeout(timeout);
      request.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${config.apiKey}');
      request.write(jsonEncode({
        'model': config.model,
        'temperature': 0,
        'response_format': {'type': 'json_object'},
        'messages': [
          {
            'role': 'system',
            'content': '你是日程去重器。只输出 JSON，形如 {"duplicates": [[0,3],[1,2]]}。'
                '判断标准：讲的是同一件事（同一场活动 / 同一次维护 / 同一个版本更新）就算重复，'
                '即使标题一个中文一个英文、一个写了日期一个没写，也算同一件事。'
                '只返回重复组（组内至少 2 条，用 i 索引表示，每个索引最多出现一次）；'
                '没有重复就返回 {"duplicates": []}。不确定的不要合并。',
          },
          {
            'role': 'user',
            'content': jsonEncode({'items': items}),
          },
        ],
      }));

      final response = await request.close().timeout(timeout);
      final body = await response.transform(utf8.decoder).join().timeout(timeout);
      if (response.statusCode != 200) {
        debugPrint('[NijiCal][semdedupe] HTTP ${response.statusCode}');
        return null;
      }
      final decoded = jsonDecode(body);
      final content = ((decoded['choices'] as List?)?.first as Map?)?['message']?['content'] as String?;
      if (content == null) {
        debugPrint('[NijiCal][semdedupe] 没有 content');
        return null;
      }
      final open = content.indexOf('{');
      final close = content.lastIndexOf('}');
      if (open < 0 || close <= open) {
        debugPrint('[NijiCal][semdedupe] 解析失败: ${content.length} 字');
        return null;
      }
      final json = (jsonDecode(content.substring(open, close + 1)) as Map).cast<String, dynamic>();
      final raw = json['duplicates'];
      if (raw is! List) {
        debugPrint('[NijiCal][semdedupe] 缺 duplicates: $json');
        return null;
      }
      final out = <List<int>>[];
      final used = <int>{};
      for (final g in raw) {
        if (g is! List) continue;
        final group = <int>[];
        for (final v in g) {
          if (v is int && used.add(v)) group.add(v);
        }
        if (group.length >= 2) out.add(group);
      }
      return out;
    } catch (e) {
      debugPrint('[NijiCal][semdedupe] 异常 ${e.toString().split('\n').first}');
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
