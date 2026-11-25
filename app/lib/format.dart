import 'model.dart';

/// 统一按北京时间展示：把带时区的时间换算成 UTC+8 的“墙钟”再格式化。
DateTime wall(DateTime d) => d.toUtc().add(beijingOffset);

String _two(int v) => v.toString().padLeft(2, '0');

String hm(DateTime d) {
  final w = wall(d);
  return '${_two(w.hour)}:${_two(w.minute)}';
}

String md(DateTime d) => '${wall(d).month}月${wall(d).day}日';

String mdhm(DateTime d) => '${md(d)} ${hm(d)}';

String shortDate(DateTime d) => '${wall(d).month}/${wall(d).day}';

String weekday(DateTime d) => const ['一', '二', '三', '四', '五', '六', '日'][wall(d).weekday - 1];

String dayKey(DateTime d) {
  final w = wall(d);
  return '${w.year}-${_two(w.month)}-${_two(w.day)}';
}

double hoursUntil(DateTime due) => due.difference(DateTime.now()).inSeconds / 3600;

class Countdown {
  const Countdown(this.text, this.level);
  final String text;

  /// 0 = 已过期，1 = 3 小时内（最紧），2 = 24 小时内，3 = 正常
  final int level;
}

/// 只给“还有几天”，不再报到小时：日历上扫一眼就够，精确时刻在详情里看。
Countdown countdownOf(DateTime due) {
  final h = hoursUntil(due);
  if (h < 0) return const Countdown('已过期', 0);
  if (h < 1) return const Countdown('还有 1 小时', 1);
  if (h < 3) return Countdown('还有 ${h.floor()} 小时', 1);
  if (h < 24) return Countdown('还有 ${h.floor()} 小时', 2);
  final days = (h / 24).ceil();
  return Countdown('还有 $days 天', 3);
}

/// 原文只写了日期、没写具体时刻：模型会把这类公告落成当天的 00:00。
///
/// 注意这是「推断」而不是精确值 —— `GameEvent` 里没有额外的精度字段，
/// 所以只能用 00:00 这个约定当“全天”的标记（真正的 00:00 事件极少）。
bool isAllDay(DateTime? t) {
  if (t == null) return false;
  final w = wall(t);
  return w.hour == 0 && w.minute == 0;
}

/// 事件发生在今天、且没有具体时刻 —— 一整天都算「进行中」，
/// 不该在 00:00 一过就显示成「已过期」。
///
/// 开始时间给了日期没给时刻的全天事件：只要开始日还是今天，就整天算进行中，
/// 不再拿结束时刻卡它（只给日期的公告，结束也可能是当天 00:00 / 23:59 的约定值）；
/// 只有截止日的全天事件：截止日就是今天。
bool isOngoingAllDay(GameEvent e, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final today = wall(current);
  bool sameDay(DateTime? t) {
    if (t == null) return false;
    final w = wall(t);
    return w.year == today.year && w.month == today.month && w.day == today.day;
  }

  final start = e.start;
  if (start != null) {
    return sameDay(start) && isAllDay(start);
  }
  // 只有截止时间（start == null）且没给具体时刻：整个截止日都算进行中
  final end = e.end;
  return end != null && sameDay(end) && isAllDay(end);
}

String reminderText(List<int> offsets) {
  final parts = offsets.map((m) {
    final v = -m;
    if (v % 1440 == 0) return '${v ~/ 1440} 天前';
    if (v % 60 == 0) return '${v ~/ 60} 小时前';
    return '$v 分钟前';
  });
  return '${parts.join(' · ')}（订阅日历后由系统日历发出）';
}

String eventRange(DateTime? start, DateTime? end) {
  if (start != null && end != null) {
    return '${mdhm(start)} → ${mdhm(end)}';
  }
  if (start != null) return '${mdhm(start)} 开始';
  if (end != null) return '截止 ${mdhm(end)}';
  return '—';
}

// ---------------------------------------------------------------- 日历用

/// `2026-11-17`（北京时间的“日”）
String dateKeyOf(int year, int month, int day) =>
    '$year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';

String dayPartOf(DateTime dt) {
  final w = wall(dt);
  return dateKeyOf(w.year, w.month, w.day);
}

String todayKey() => dayPartOf(DateTime.now());

/// `2026-11-17` → `11 月 17 日`
String monthDayLabel(String key) {
  final parts = key.split('-');
  if (parts.length != 3) return key;
  final m = int.tryParse(parts[1]);
  final d = int.tryParse(parts[2]);
  if (m == null || d == null) return key;
  return '$m 月 $d 日';
}

/// `2026-11-17` → `周二`
String weekdayLabelOf(String key) {
  final parts = key.split('-');
  if (parts.length != 3) return '';
  final dt = DateTime.tryParse(key);
  if (dt == null) return '';
  const names = ['一', '二', '三', '四', '五', '六', '日'];
  return '周${names[dt.weekday - 1]}';
}
/// 行内用的紧凑写法：`11/5 12:00 → 11/19 03:59`
String eventRangeShort(DateTime? start, DateTime? end) {
  String stamp(DateTime d) => '${shortDate(d)} ${hm(d)}';
  if (start != null && end != null) return '${stamp(start)} → ${stamp(end)}';
  if (start != null) return '${stamp(start)} 开始';
  if (end != null) return '截止 ${stamp(end)}';
  return '—';
}