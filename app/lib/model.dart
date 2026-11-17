import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// 北京时间（UTC+8）。产品 MVP 阶段只支持单时区。
const beijingOffset = Duration(hours: 8);

DateTime? _parse(String? raw) => (raw == null || raw.isEmpty) ? null : DateTime.parse(raw);

Color _hex(String? raw) {
  if (raw == null || raw.length < 7) return const Color(0xFF8A8A8A);
  return Color(0xFF000000 | int.parse(raw.substring(1), radix: 16));
}

class Revision {
  const Revision({required this.field, this.from, this.to, this.changedAt, this.reason});

  final String field;
  final String? from;
  final String? to;
  final String? changedAt;
  final String? reason;

  factory Revision.fromJson(Map<String, dynamic> j) => Revision(
        field: j['field'] as String? ?? '变更',
        from: j['from'] as String?,
        to: j['to'] as String?,
        changedAt: j['changed_at'] as String?,
        reason: j['reason'] as String?,
      );
}

class Game {
  const Game({
    required this.id,
    required this.name,
    required this.short,
    required this.accent,
    this.biliUid,
    this.versionCurrent,
    this.versionNext,
  });

  final String id;
  final String name;
  final String short;
  final Color accent;
  final String? biliUid;
  final String? versionCurrent;
  final String? versionNext;

  String get initial => name.isEmpty ? '?' : name.substring(0, 1);

  factory Game.fromJson(Map<String, dynamic> j) => Game(
        id: j['id'] as String,
        name: j['name'] as String,
        short: j['short'] as String? ?? j['name'] as String,
        accent: _hex(j['accent'] as String?),
        biliUid: j['bili_uid'] as String?,
        versionCurrent: j['version_current'] as String?,
        versionNext: j['version_next'] as String?,
      );
}

enum EventStatus {
  confirmed('官方确认'),
  tentative('待确认'),
  changed('已变更'),
  expired('已过期');

  const EventStatus(this.label);

  final String label;

  static EventStatus parse(String? raw) => switch (raw) {
        'tentative' => EventStatus.tentative,
        'changed' => EventStatus.changed,
        'expired' => EventStatus.expired,
        _ => EventStatus.confirmed,
      };
}

class GameEvent {
  const GameEvent({
    required this.id,
    required this.gameId,
    required this.type,
    required this.title,
    required this.status,
    required this.confidence,
    required this.revisions,
    this.start,
    this.end,
    this.summary,
    this.fetchedAt,
    this.sourceName,
    this.sourceUrl,
    this.version,
    this.tags = const [],
  });

  final String id;
  final String gameId;
  final String type;
  final String title;
  final DateTime? start;
  final DateTime? end;
  final EventStatus status;
  final int confidence;
  final String? summary;
  final DateTime? fetchedAt;
  final String? sourceName;
  final String? sourceUrl;
  final List<Revision> revisions;

  /// 大模型规范化出的版本号（如 2.7）与标签（活动/卡池/限时…）
  final String? version;
  final List<String> tags;

  /// 真正该被提醒的时刻：截止类用 end，开始类用 start
  DateTime get due => end ?? start!;
  bool get isDeadline => start == null;

  /// 与 [GameEvent.fromJson] 对称，用于把 App 内刷新到的事件存到本机
  Map<String, dynamic> toJson() => {
        'id': id,
        'game_id': gameId,
        'type': type,
        'title': title,
        'start': start?.toIso8601String(),
        'end': end?.toIso8601String(),
        'status': status.name,
        'confidence': confidence,
        'summary': summary,
        'fetched_at': fetchedAt?.toIso8601String(),
        'source': {'name': sourceName, 'url': sourceUrl},
        'version': version,
        'tags': tags,
        'revisions': [
          for (final r in revisions)
            {'field': r.field, 'from': r.from, 'to': r.to, 'changed_at': r.changedAt, 'reason': r.reason},
        ],
      };

  factory GameEvent.fromJson(Map<String, dynamic> j) => GameEvent(
        id: j['id'] as String,
        gameId: j['game_id'] as String,
        type: j['type'] as String,
        title: j['title'] as String,
        start: _parse(j['start'] as String?),
        end: _parse(j['end'] as String?),
        status: EventStatus.parse(j['status'] as String?),
        confidence: (j['confidence'] as num?)?.toInt() ?? 0,
        summary: j['summary'] as String?,
        fetchedAt: _parse(j['fetched_at'] as String?),
        sourceName: (j['source'] as Map?)?['name'] as String?,
        sourceUrl: (j['source'] as Map?)?['url'] as String?,
        version: j['version'] as String?,
        tags: ((j['tags'] as List?) ?? const []).cast<String>(),
        revisions: ((j['revisions'] as List?) ?? const [])
            .map((e) => Revision.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class NijiData {
  const NijiData({
    required this.dataMode,
    required this.sampleNotice,
    required this.builtAt,
    required this.typeOrder,
    required this.alarms,
    required this.games,
    required this.events,
  });

  final String dataMode;
  final String sampleNotice;
  final String builtAt;
  final List<String> typeOrder;
  final Map<String, List<int>> alarms;
  final List<Game> games;
  final List<GameEvent> events;

  Map<String, Game> get gamesById => {for (final g in games) g.id: g};

  List<int> alarmsFor(String type) => alarms[type] ?? const [-1440, -60];

  static Future<NijiData> load({String asset = 'assets/data.json'}) async {
    final raw = await rootBundle.loadString(asset);
    final json = jsonDecode(raw) as Map<String, dynamic>;

    final meta = (json['meta'] as Map?)?.cast<String, dynamic>() ?? const {};
    final alarmsRaw = (json['alarms'] as Map?)?.cast<String, dynamic>() ?? const {};

    return NijiData(
      dataMode: meta['data_mode'] as String? ?? 'sample',
      sampleNotice: meta['sample_notice'] as String? ?? '',
      builtAt: meta['built_at'] as String? ?? '',
      typeOrder: ((json['type_order'] as List?) ?? const []).cast<String>(),
      alarms: {
        for (final entry in alarmsRaw.entries)
          entry.key: (entry.value as List).map((e) => (e as num).toInt()).toList(),
      },
      games: ((json['games'] as List?) ?? const [])
          .map((e) => Game.fromJson(e as Map<String, dynamic>))
          .toList(),
      events: ((json['events'] as List?) ?? const [])
          .map((e) => GameEvent.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
