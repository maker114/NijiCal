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

Countdown countdownOf(DateTime due) {
  final h = hoursUntil(due);
  if (h < 0) return const Countdown('已过期', 0);
  if (h < 1) return Countdown('剩 ${(h * 60).round().clamp(1, 60)} 分钟', 1);
  if (h < 3) return Countdown('剩 ${h.floor()} 小时 ${((h % 1) * 60).round()} 分', 1);
  if (h < 24) return Countdown('剩 ${h.floor()} 小时 ${((h % 1) * 60).round()} 分', 2);
  final d = h ~/ 24;
  final rest = (h % 24).round();
  return Countdown(rest == 0 ? '剩 $d 天' : '剩 $d 天 $rest 小时', 3);
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
