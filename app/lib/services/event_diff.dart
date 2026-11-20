import 'package:flutter/foundation.dart';

import '../model.dart';

/// 一次「官方改了公告、导致时间变化」的字段级变化
class EventChange {
  const EventChange({
    required this.eventId,
    required this.title,
    required this.field,
    this.from,
    this.to,
  });

  final String eventId;
  final String title;
  final String field;
  final String? from;
  final String? to;

  String get summary => '$title｜$field：${from ?? '—'} → ${to ?? '—'}';
}

/// 动态原文指纹（FNV-1a 32 位）。
///
/// 用它区分两件完全不同的事：
///   · 指纹变了 → 官方改过这条动态，时间变化才算“改期”；
///   · 指纹没变 → 原文一个字没动，时间不同只可能是模型抽取抖动，必须忽略。
String contentHash(String text) {
  var hash = 0x811c9dc5;
  for (final unit in text.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

String prettyStamp(DateTime? d) {
  if (d == null) return '—';
  return '${d.month} 月 ${d.day} 日 ${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';
}

/// 一律按 UTC 瞬时点比较：同一个时刻可能被表示成 UTC 或本地时间，
/// 直接读 hour 字段会差 8 小时，把每条事件都误判成改期。
String _stamp(DateTime? d) => d == null ? '' : d.toUtc().toIso8601String().substring(0, 16);

/// 只有原文指纹变化时才可能改期；历史数据没有指纹的一律不判定
bool _sourceChanged(GameEvent? old, GameEvent fresh) {
  if (old == null) return false;
  final before = old.sourceHash;
  final after = fresh.sourceHash;
  if (before == null || before.isEmpty || after == null || after.isEmpty) return false;
  return before != after;
}

/// 对比新旧事件，返回改期字段。
///
/// 判定口径：同 `id` + 原文指纹变化 + 时间变了，三者同时成立才算改期。
List<EventChange> diffEvents(List<GameEvent> oldEvents, List<GameEvent> freshEvents) {
  final byId = {for (final e in oldEvents) e.id: e};
  final changes = <EventChange>[];

  for (final fresh in freshEvents) {
    final old = byId[fresh.id];
    if (!_sourceChanged(old, fresh)) continue;
    final before = old!;

    if (_stamp(before.start) != _stamp(fresh.start)) {
      changes.add(EventChange(
        eventId: fresh.id,
        title: fresh.title,
        field: '开始时间',
        from: prettyStamp(before.start),
        to: prettyStamp(fresh.start),
      ));
    }
    if (_stamp(before.end) != _stamp(fresh.end)) {
      changes.add(EventChange(
        eventId: fresh.id,
        title: fresh.title,
        field: '结束时间',
        from: prettyStamp(before.end),
        to: prettyStamp(fresh.end),
      ));
    }
  }
  return changes;
}

/// 把变更写成事件的历史记录，并把状态标成「已变更」
GameEvent withChanges(GameEvent event, List<EventChange> changes, DateTime now) {
  final mine = changes.where((c) => c.eventId == event.id).toList();
  if (mine.isEmpty) return event;
  return GameEvent(
    id: event.id,
    gameId: event.gameId,
    type: event.type,
    title: event.title,
    start: event.start,
    end: event.end,
    status: EventStatus.changed,
    confidence: event.confidence,
    summary: event.summary,
    fetchedAt: event.fetchedAt,
    sourceName: event.sourceName,
    sourceUrl: event.sourceUrl,
    version: event.version,
    tags: event.tags,
    sourceHash: event.sourceHash,
    displayEnd: event.displayEnd,
    revisions: [
      ...event.revisions,
      for (final c in mine)
        Revision(
          field: c.field,
          from: c.from,
          to: c.to,
          changedAt: _changedAt(now),
          reason: '官方公告更新',
        ),
    ],
  );
}

String _changedAt(DateTime now) =>
    '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
    '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

/// 合并刷新结果：
///   · 原文没变 → 沿用旧事件（保住上次确认的时间，不被抖动覆盖）
///   · 原文变了 → 用新解析，并把时间变化记成历史
({List<GameEvent> events, List<EventChange> changes}) mergeEvents(
  List<GameEvent> oldEvents,
  List<GameEvent> freshEvents,
  DateTime now,
) {
  freshEvents = dedupeEvents(freshEvents);
  final byId = {for (final e in oldEvents) e.id: e};
  final changes = diffEvents(oldEvents, freshEvents);
  final next = <GameEvent>[];

  for (final fresh in freshEvents) {
    final old = byId[fresh.id];
    if (old != null && !_sourceChanged(old, fresh)) {
      // 历史数据没有指纹时补上，否则永远无法判定之后的改期
      next.add(old.sourceHash == null ? _adoptHash(old, fresh.sourceHash) : old);
    } else {
      next.add(withChanges(fresh, changes, now));
    }
  }
  return (events: next, changes: changes);
}

/// 只补指纹，其余字段（尤其是时间）保持原样
GameEvent _adoptHash(GameEvent event, String? hash) => GameEvent(
      id: event.id,
      gameId: event.gameId,
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
      sourceHash: hash,
      displayEnd: event.displayEnd,
      revisions: event.revisions,
    );
/// 标题核心：去掉标点、引号、空格，以及“全新版本/版本更新/开启/结束”这类套话。
/// 用来识别“同一条公告被多条动态各解析一遍”的重复。
String titleCore(String title) {
  final stripped = title.replaceAll(RegExp(r'[^\u4e00-\u9fa5A-Za-z0-9]'), '');
  return stripped.replaceAll(
    RegExp(r'全新版本|版本更新|版本前瞻|特别节目|今日开启|即将开启|正式开启|开启|结束|更新|版本|活动|卡池'),
    '',
  );
}

/// 已知游戏的全称与简称：做标题指纹时先去掉，
/// 避免「终末地 2.0 前瞻」与「2.0 前瞻」被判成两条。
const _gameNameTokens = <String>[
  '明日方舟终末地', '明日方舟', '终末地', '绝区零', '异环', '方舟',
];

/// 标题指纹：去游戏名、去标点空白、去泛用词，只留能区分「是不是同一件事」的部分。
///
/// 同一场前瞻常以三种写法被抓回来（「2.0 版本揭幕前瞻特别节目」/
/// 「终末地 2.0 版本前瞻特别节目」/「2.0 版本前瞻特别节目」），必须视为同一条。
@visibleForTesting
String titleFingerprint(String title) {
  var s = title;
  for (final name in _gameNameTokens) {
    s = s.replaceAll(name, '');
  }
  // 标题里常把日期/时间复述一遍（「3.4 版本 12月2日 上线」与「3.4 版本上线」
  // 是同一件事），时间已经在 start/end 里参与比较，这里把日期串去掉。
  s = s.replaceAll(RegExp(r'\d{1,2}\s*月\s*\d{1,2}\s*[日号]'), '');
  s = s.replaceAll(RegExp(r'\d{1,2}\s*月\s*\d{1,2}\s*[日号]?\s*(上午|下午|晚上|中午|凌晨)'), '');
  // 只用 / 与 - 当日期分隔符：'2.0' 这种是版本号，不能被当成日期吃掉
  s = s.replaceAll(RegExp(r'\d{1,2}\s*[/-]\s*\d{1,2}'), '');
  s = s.replaceAll(RegExp(r'\d{1,2}\s*[:：]\s*\d{2}'), '');
  s = s.replaceAll(RegExp(r'\d{1,2}\s*[点时](\s*\d{1,2}\s*分)?'), '');
  s = s.replaceAll(RegExp(r'[^\u4e00-\u9fa5A-Za-z0-9]'), '').toLowerCase();
  s = s.replaceAll(
    RegExp('全新|揭幕|特别节目|前瞻|直播|版本|更新|活动|卡池|开启|开始|结束'
        '|今日|即将|正式|上线|开放|截止|限时|复刻|预告|上午|下午|晚上|中午|凌晨'),
    '',
  );
  return s;
}

List<GameEvent> dedupeEvents(List<GameEvent> events) {
  final out = <GameEvent>[];
  for (final event in events) {
    final idx = out.indexWhere((kept) => _sameEvent(kept, event));
    if (idx < 0) {
      out.add(event);
    } else {
      out[idx] = _preferComplete(out[idx], event);
    }
  }
  return out;
}

/// 同一条事件的不同解析结果：游戏、类型相同，开始时间相差不超过 5 分钟，
/// 且标题指纹够像（相等 / 互相包含 / 二元组相似度 ≥ 0.65）。
///
/// 不再要求 end 完全一致 —— 模型有时给出结束时间、有时给 null，
/// 之前就是因此把「3.4 版本上线」判成了两条。
bool _sameEvent(GameEvent a, GameEvent b) {
  if (a.gameId != b.gameId || a.type != b.type) return false;
  final sa = a.start;
  final sb = b.start;
  if (sa == null || sb == null) return false;
  if (sa.difference(sb).inMinutes.abs() > 5) return false;
  if (_titleSimilar(titleFingerprint(a.title), titleFingerprint(b.title))) {
    return true;
  }
  // 标题完全不同、但起止时间几乎一致：同一场活动被两条动态用不同说法各写了一遍
  //（如「Zenless LIVE 2026」与「绝区零 2026 FES 布梦嘉年华」都是 11/27 00:00 → 11/29）。
  final ea = _windowEnd(a);
  final eb = _windowEnd(b);
  if (ea != null &&
      eb != null &&
      ea.difference(eb).inMinutes.abs() <= 60 &&
      // 再要求标题指纹至少共享一个二元组：同一活动的中英文两种叫法通常共享年份/版本号，
      // 而「回音特刊研募计划」与「电子人之梦棋盘」这类同窗口但毫不相干的并行活动不会共享，
      // 避免因为时间相同就误合并。
      _sharesBigram(titleFingerprint(a.title), titleFingerprint(b.title))) {
    return true;
  }
  return false;
}

bool _sharesBigram(String a, String b) {
  if (a.isEmpty || b.isEmpty) return false;
  final ga = _bigrams(a);
  final gb = _bigrams(b);
  return ga.intersection(gb).isNotEmpty;
}

/// 事件的有效结束时间：模型有时只给 displayEnd（拆出来的开始事件）
DateTime? _windowEnd(GameEvent e) => e.end ?? e.displayEnd;

/// 标题指纹相似度：相等、互相包含，或字符二元组 Jaccard ≥ 0.65
@visibleForTesting
bool titleSimilar(String a, String b) => _titleSimilar(a, b);

bool _titleSimilar(String a, String b) {
  // 标题全是泛用词（如「版本更新上线」）时指纹为空：同游戏同类型同时间即视为同一条
  if (a.isEmpty || b.isEmpty) return a.isEmpty && b.isEmpty;
  if (a == b) return true;
  if (a.contains(b) || b.contains(a)) return true;
  if (a.length < 4 || b.length < 4) return false;

  final ga = _bigrams(a);
  final gb = _bigrams(b);
  if (ga.isEmpty || gb.isEmpty) return false;
  final inter = ga.intersection(gb).length;
  final union = ga.union(gb).length;
  return union > 0 && inter / union >= 0.65;
}

Set<String> _bigrams(String s) {
  final out = <String>{};
  for (var i = 0; i + 1 < s.length; i += 1) {
    out.add(s.substring(i, i + 2));
  }
  return out;
}

/// 合并重复项时留下信息更全的那条（有区间 > 有摘要 > 标题更长）
GameEvent _preferComplete(GameEvent a, GameEvent b) {
  int score(GameEvent e) =>
      (e.end != null ? 4 : 0) +
      (e.displayEnd != null ? 4 : 0) +
      ((e.summary ?? '').isNotEmpty ? 2 : 0) +
      (e.title.length >= 6 ? 1 : 0);
  return score(b) > score(a) ? b : a;
}

/// 给拆分出来的「开始」事件补上区间：从同一条动态的 `-end` 兄弟事件里取结束时间。
/// 老数据里没有 displayEnd，靠这一步回填，否则行内只显示「开始 xx」。
List<GameEvent> backfillRanges(List<GameEvent> events) {
  final byId = {for (final e in events) e.id: e};
  return events.map((e) {
    if (!e.id.endsWith('-start') || e.displayEnd != null) return e;
    final sibling = byId[e.id.replaceFirst('-start', '-end')];
    if (sibling?.end == null) return e;
    return _withDisplayEnd(e, sibling!.end);
  }).toList();
}

GameEvent _withDisplayEnd(GameEvent event, DateTime? end) => GameEvent(
      id: event.id,
      gameId: event.gameId,
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
      sourceHash: event.sourceHash,
      displayEnd: end,
      revisions: event.revisions,
    );
