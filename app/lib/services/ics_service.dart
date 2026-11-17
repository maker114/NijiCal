import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../format.dart';
import '../model.dart';

/// 在机内生成 iCalendar 文本，可导出给系统日历（iOS/Android 都能直接导入）。
/// 这样“把日程装进系统日历”不依赖任何服务端。
abstract class IcsService {
  static const _tzName = 'Asia/Shanghai';

  static String build({
    required List<GameEvent> events,
    required Map<String, Game> games,
    required Map<String, List<int>> alarms,
    String calendarName = 'NijiCal · 二游日程',
  }) {
    final now = DateTime.now().toUtc();
    final stamp = '${now.year}${_p(now.month)}${_p(now.day)}T'
        '${_p(now.hour)}${_p(now.minute)}${_p(now.second)}Z';

    final out = <String>[
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'PRODID:-//NijiCal//App//CN',
      'CALSCALE:GREGORIAN',
      'METHOD:PUBLISH',
      _fold('X-WR-CALNAME:${_esc(calendarName)}'),
      'X-WR-TIMEZONE:$_tzName',
      'BEGIN:VTIMEZONE',
      'TZID:$_tzName',
      'BEGIN:STANDARD',
      'DTSTART:19700101T000000',
      'TZOFFSETFROM:+0800',
      'TZOFFSETTO:+0800',
      'TZNAME:CST',
      'END:STANDARD',
      'END:VTIMEZONE',
    ];

    for (final e in events) {
      final game = games[e.gameId];
      final start = e.start;
      final end = e.end;

      final DateTime dtStart;
      final DateTime dtEnd;
      if (start != null && end != null) {
        dtStart = start;
        dtEnd = end;
      } else if (start != null) {
        dtStart = start;
        dtEnd = start.add(const Duration(hours: 1));
      } else {
        dtStart = end!;
        dtEnd = end.add(const Duration(minutes: 15));
      }

      final summary = '【${game?.short ?? ''}】${e.title}';
      final desc = [
        if ((e.summary ?? '').isNotEmpty) e.summary!,
        '类型：${e.type}',
        '置信度：${e.confidence}%（${e.status.label}）',
        '来源：${e.sourceName ?? '未标注'}',
      ].join('\n');

      out
        ..add('BEGIN:VEVENT')
        ..add('UID:${e.id}@nijical')
        ..add('DTSTAMP:$stamp')
        ..add('DTSTART;TZID=$_tzName:${_icsTime(dtStart)}')
        ..add('DTEND;TZID=$_tzName:${_icsTime(dtEnd)}')
        ..add(_fold('SUMMARY:${_esc(summary)}'))
        ..add(_fold('DESCRIPTION:${_esc(desc)}'))
        ..add('STATUS:${e.status == EventStatus.tentative ? 'TENTATIVE' : 'CONFIRMED'}')
        ..add('TRANSP:TRANSPARENT')
        ..add('X-NIJICAL-CONFIDENCE:${e.confidence}');

      for (final minutes in alarms[e.type] ?? const [-1440, -60]) {
        out
          ..add('BEGIN:VALARM')
          ..add('ACTION:DISPLAY')
          ..add(_fold('DESCRIPTION:${_esc('NijiCal：$summary')}'))
          ..add('TRIGGER:${_duration(minutes)}')
          ..add('END:VALARM');
      }
      out.add('END:VEVENT');
    }

    out.add('END:VCALENDAR');
    return '${out.join('\r\n')}\r\n';
  }

  /// 写到临时目录并唤起系统分享 —— 用户挑“日历”或“文件”即可导入
  static Future<void> shareFile({
    required List<GameEvent> events,
    required Map<String, Game> games,
    required Map<String, List<int>> alarms,
    String fileName = 'nijical.ics',
  }) async {
    final content = build(events: events, games: games, alarms: alarms);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsString(content, flush: true);

    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'text/calendar')],
        text: 'NijiCal 日程（${events.length} 条）',
        subject: 'NijiCal 日程',
      ),
    );
  }

  // ---------------------------------------------------------------- 工具

  static String _p(int v) => v.toString().padLeft(2, '0');

  /// 转成北京时间墙钟，避免依赖设备本地时区
  static String _icsTime(DateTime d) {
    final w = wall(d);
    return '${w.year}${_p(w.month)}${_p(w.day)}T${_p(w.hour)}${_p(w.minute)}${_p(w.second)}';
  }

  static String _duration(int minutes) {
    final m = -minutes;
    if (m % 1440 == 0) return '-P${m ~/ 1440}D';
    if (m % 60 == 0) return '-PT${m ~/ 60}H';
    return '-PT${m}M';
  }

  static String _esc(String s) => s
      .replaceAll('\\', '\\\\')
      .replaceAll(';', '\\;')
      .replaceAll(',', '\\,')
      .replaceAll('\r\n', '\\n')
      .replaceAll('\n', '\\n');

  /// RFC 5545 折行：每行不超过 75 个八位组
  static String _fold(String line) {
    final bytes = <int>[];
    final chunks = <String>[];
    var buffer = StringBuffer();

    for (final rune in line.runes) {
      final ch = String.fromCharCode(rune);
      final len = _utf8Len(rune);
      if (bytes.length + len > 73) {
        chunks.add(buffer.toString());
        buffer = StringBuffer();
        bytes.clear();
      }
      buffer.write(ch);
      bytes.add(len);
    }
    chunks.add(buffer.toString());
    return chunks.join('\r\n ');
  }

  static int _utf8Len(int rune) {
    if (rune <= 0x7F) return 1;
    if (rune <= 0x7FF) return 2;
    if (rune <= 0xFFFF) return 3;
    return 4;
  }
}
