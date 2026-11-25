import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../model.dart';
import 'event_diff.dart';
import 'llm_normalizer.dart';

/// 一次刷新后的「全量审核」结果。
class DedupeResult {
  const DedupeResult({
    required this.events,
    required this.removed,
    this.error,
    this.byModel = false,
  });

  final List<GameEvent> events;

  /// 这次审核合并掉的重复条数
  final int removed;

  /// 模型不可用 / 调用失败的原因；非空表示已退回纯规则去重
  final String? error;

  /// 是否真的由大模型判定（false = 退回规则）
  final bool byModel;
}

/// 语义去重：每次刷新完成后，让大模型把**整份日程列表**过一遍，
/// 找出「其实是同一件事」的重复条目。
///
/// 只靠规则（titleFingerprint + 时间容差）抓不到两类重复：
///   · 「Zenless LIVE 2026」与「绝区零 2026 FES 布梦嘉年华」：标题毫无共同字词，
///     但同一天、同一窗口，是同一场活动；
///   · 同一份公告被两条动态各解析一次，开始时间可能差几小时，甚至一条没有开始时间。
///
/// 所以不再只把「同游戏同类型、开始时间相差 ≤10 分钟」的候选送给模型，而是把
/// 当轮入库后的全部事件一次性交给模型审核，一次刷新通常只多一次调用。
/// 模型按游戏与「开始/结束」方向再做一次硬校验（防止误合并并行的活动、把配套的
/// 开始与结束两条并掉），失败或不可用时退回纯规则。
class LlmDeduper {
  /// 单次请求最多送多少条。超过才按游戏拆成多片（同一款游戏不会被拆开）。
  @visibleForTesting
  static const maxItemsPerCall = 120;

  /// 审核整份日程列表，返回去重后的列表。
  static Future<DedupeResult> audit(
    List<GameEvent> events, {
    required LlmConfig config,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (events.length < 2) {
      return DedupeResult(events: events, removed: 0);
    }
    if (!config.ready) {
      return _fallback(events, '还没配置大模型 key');
    }

    final drops = <int>{};
    for (final indexes in _chunkIndexes(events)) {
      final chunk = [for (final i in indexes) events[i]];
      final ask = await _ask(
        items: [for (var i = 0; i < chunk.length; i++) _item(i, chunk[i])],
        config: config,
        timeout: timeout,
      );
      if (ask.groups == null) {
        return _fallback(events, ask.error ?? '大模型审核失败');
      }
      for (final local in _droppedIndexes(chunk, ask.groups!)) {
        drops.add(indexes[local]);
      }
    }

    if (drops.isEmpty) {
      return DedupeResult(events: events, removed: 0, byModel: true);
    }
    // 保持原顺序，避免影响后续合并 / 改期判定的稳定性
    return DedupeResult(
      events: [
        for (var i = 0; i < events.length; i++)
          if (!drops.contains(i)) events[i],
      ],
      removed: drops.length,
      byModel: true,
    );
  }

  /// 模型不可用或调用失败：至少按规则把同一件事的重复清一遍，
  /// 并把原因带回去给界面 / 诊断信息。
  static DedupeResult _fallback(List<GameEvent> events, String error) {
    final deduped = dedupeEvents(events);
    return DedupeResult(
      events: deduped,
      removed: events.length - deduped.length,
      error: error,
    );
  }

  /// 同游戏 + 同方向（开始 / 结束）才算一组；分组后按索引顺序稳定排序。
  /// 这是对模型输出的硬校验：模型把并行的两个活动或配套的开始/结束两条
  /// 放进同一组时，这里不会真的把它们合并。
  static Set<int> _droppedIndexes(List<GameEvent> events, List<List<int>> groups) {
    final drop = <int>{};
    for (final raw in groups) {
      final members = <int>{};
      for (final v in raw) {
        // 已经被上一组判为重复的条目不再参与，否则它可能当上「代表」，
        // 导致同一组里两条都被删掉
        if (v >= 0 && v < events.length && !drop.contains(v)) members.add(v);
      }
      if (members.length < 2) continue;

      final buckets = <String, List<int>>{};
      for (final i in members) {
        final e = events[i];
        buckets.putIfAbsent('${e.gameId}\u0000${_direction(e)}', () => <int>[]).add(i);
      }
      for (final bucket in buckets.values) {
        if (bucket.length < 2) continue;
        bucket.sort((a, b) {
          final byScore = _score(events[b]).compareTo(_score(events[a]));
          // 同分时留靠前的那条，保证结果稳定
          return byScore != 0 ? byScore : a.compareTo(b);
        });
        final kept = <int>[];
        for (final i in bucket) {
          if (kept.any((k) => _compatible(events[k], events[i]))) {
            // 同一组里信息最全的那条留下，其余算重复
            drop.add(i);
          } else {
            kept.add(i);
          }
        }
      }
    }
    return drop;
  }

  /// 同一件事的两次抽取，时间可能差几小时；差到两天以上就不当成同一条，
  /// 宁可留两条也不把另一场活动删掉。没有开始时间就比结束时间。
  static bool _compatible(GameEvent a, GameEvent b) {
    final sa = a.start;
    final sb = b.start;
    if (sa != null && sb != null) {
      return sa.difference(sb).abs() <= const Duration(hours: 48);
    }
    final ea = a.end ?? a.displayEnd;
    final eb = b.end ?? b.displayEnd;
    if (ea != null && eb != null) {
      return ea.difference(eb).abs() <= const Duration(hours: 48);
    }
    return true;
  }

  /// 开始类与结束类绝不互相合并：一条公告被拆成「开始 / 结束」两条是设计如此。
  static String _direction(GameEvent e) =>
      const {'活动结束', '卡池结束', '兑换码截止', '补偿领取截止'}.contains(e.type) ? 'end' : 'start';

  static int _score(GameEvent e) =>
      (e.end != null ? 4 : 0) +
      (e.displayEnd != null ? 4 : 0) +
      ((e.summary ?? '').isNotEmpty ? 2 : 0) +
      (e.title.length >= 6 ? 1 : 0) +
      (e.confidence >= 85 ? 1 : 0);

  static String _fmt(DateTime? t) {
    if (t == null) return '-';
    final b = t.toUtc().add(const Duration(hours: 8));
    String two(int v) => v.toString().padLeft(2, '0');
    return '${b.year}-${two(b.month)}-${two(b.day)} ${two(b.hour)}:${two(b.minute)}';
  }

  static Map<String, dynamic> _item(int i, GameEvent e) {
    final summary = (e.summary ?? '').trim();
    return {
      'i': i,
      'game': e.gameId,
      'type': e.type,
      'start': _fmt(e.start),
      'end': _fmt(e.end ?? e.displayEnd),
      'title': e.title,
      if ((e.version ?? '').isNotEmpty) 'version': e.version,
      if (summary.isNotEmpty)
        'summary': summary.length > 40 ? '${summary.substring(0, 40)}…' : summary,
    };
  }

  /// 超过上限时按游戏分片；同一款游戏的事件始终在同一片里，
  /// 否则跨片的重复看不到。
  static List<List<int>> _chunkIndexes(List<GameEvent> events) {
    if (events.length <= maxItemsPerCall) {
      return [List<int>.generate(events.length, (i) => i)];
    }
    final byGame = <String, List<int>>{};
    for (var i = 0; i < events.length; i++) {
      byGame.putIfAbsent(events[i].gameId, () => <int>[]).add(i);
    }
    final chunks = <List<int>>[];
    var current = <int>[];
    for (final indexes in byGame.values) {
      if (current.isNotEmpty && current.length + indexes.length > maxItemsPerCall) {
        chunks.add(current);
        current = <int>[];
      }
      current.addAll(indexes);
    }
    if (current.isNotEmpty) chunks.add(current);
    return chunks;
  }

  /// 测试用：直接套用一组「重复索引」并返回去重后的列表
  @visibleForTesting
  static List<GameEvent> applyGroups(List<GameEvent> events, List<List<int>> groups) {
    final drop = _droppedIndexes(events, groups);
    if (drop.isEmpty) return events;
    return [
      for (var i = 0; i < events.length; i++)
        if (!drop.contains(i)) events[i],
    ];
  }

  static Future<({List<List<int>>? groups, String? error})> _ask({
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
            'content': '你是二游日程审核员。只输出 JSON，形如 {"duplicates": [[0,3],[1,2]]}。\n'
                '下面是一次刷新后得到的全部日程，每条有唯一索引 i。逐条比对，找出'
                '「其实是同一件事」的重复：同一场活动 / 同一次停服维护 / 同一个版本更新 / '
                '同一个卡池 / 同一个兑换码或补偿。\n'
                '以下情况算重复：同一场活动的两种叫法（中文、英文、简称各写一遍）；'
                '同一份公告被两条动态各解析一次；标题复述日期与不复述日期；'
                '开始时间相差几小时但明显是同一天同一件事。\n'
                '以下情况不是重复，绝对不要合并：\n'
                '- 同一条公告拆出的「开始」与「结束」两条（类型分别为 活动开始/活动结束 或 '
                '卡池开始/卡池结束），它们是配套的两条；\n'
                '- 同一天或同一时间的两个不同活动、两个不同角色的卡池、两个不同兑换码；\n'
                '- 只是标题相似但对象不同，或日期相差一天以上的两条；\n'
                '- game 字段不同的两条（不是同一款游戏）。\n'
                '只返回重复组（组内至少 2 条，用 i 表示，每个 i 最多出现一次）；'
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
        return (groups: null, error: 'HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(body);
      final content = ((decoded['choices'] as List?)?.first as Map?)?['message']?['content'] as String?;
      if (content == null) {
        return (groups: null, error: '响应里没有 content');
      }
      final open = content.indexOf('{');
      final close = content.lastIndexOf('}');
      if (open < 0 || close <= open) {
        return (groups: null, error: '模型没有返回 JSON');
      }
      final json = (jsonDecode(content.substring(open, close + 1)) as Map).cast<String, dynamic>();
      final raw = json['duplicates'];
      if (raw is! List) {
        return (groups: null, error: '响应缺少 duplicates');
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
      return (groups: out, error: null);
    } catch (e) {
      final message = e.toString().split('\n').first;
      debugPrint('[NijiCal][dedupe] 全量审核异常 $message');
      return (groups: null, error: '调用异常：$message');
    } finally {
      client.close(force: true);
    }
  }
}
