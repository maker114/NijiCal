import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../format.dart';
import '../model.dart';

/// 全部提醒逻辑都在手机上跑：不依赖服务器、不依赖推送服务。
///
/// 每条事件按类型提前量排 2 个本地通知（与产品文档 §3.1.5 的模板一致），
/// 到期由系统闹钟唤起来发通知——App 被划掉也能收到。
abstract class ReminderService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static const _channelId = 'nijical_deadlines';
  static const _channelName = '截止提醒';
  static const _channelDesc = '活动结束、卡池截止、兑换码过期等时间提醒';

  static Future<void> init() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(settings: const InitializationSettings(android: android));
    _ready = true;
  }

  static AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  /// Android 13+ 需要运行时授权
  static Future<bool> requestPermission() async {
    await init();
    final granted = await _android?.requestNotificationsPermission();
    return granted ?? true;
  }

  static Future<bool> hasPermission() async {
    await init();
    return await _android?.areNotificationsEnabled() ?? true;
  }

  static Future<void> cancelAll() async {
    await init();
    await _plugin.cancelAll();
  }

  /// 为给定事件重新排期；返回实际排上的通知条数
  static Future<int> schedule(List<GameEvent> events, Map<String, List<int>> alarms) async {
    await init();
    await _plugin.cancelAll();
    var count = 0;

    for (final event in events) {
      final all = alarms[event.type] ?? const [-1440, -60];
      // 开始类事件只保留最近的一档提醒：一个活动已经被拆成“开始/结束”两条，
      // 再各排两条就是 4 条噪音，而提醒本该围绕截止点。
      final offsets = event.isDeadline ? all : [all.last];
      for (final minutes in offsets) {
        final fireAt = event.due.add(Duration(minutes: minutes));
        if (fireAt.isBefore(DateTime.now())) continue;

        final id = notificationIdFor(event.id, minutes);
        final when = fireAt.toUtc();
        await _plugin.zonedSchedule(
          id: id,
          title: '${_prefix(event)}${event.type}',
          body: '${event.title} · ${mdhm(event.due)}（${_offsetLabel(minutes)}）',
          scheduledDate: tz.TZDateTime.from(when, tz.local),
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              _channelId,
              _channelName,
              channelDescription: _channelDesc,
              importance: Importance.high,
              priority: Priority.high,
              styleInformation: BigTextStyleInformation('${event.title}\n${event.summary ?? ''}'),
              color: const Color(0xFF6366F1),
            ),
          ),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          payload: event.id,
        );
        count++;
      }
    }
    return count;
  }

  /// 排一条 10 秒后的测试通知 —— 用来验证「权限 → 定时 → 弹出」这条链路。
  static Future<void> scheduleTest({int seconds = 10}) async {
    await init();
    final when = DateTime.now().add(Duration(seconds: seconds));
    await _plugin.zonedSchedule(
      id: 990001,
      title: 'NijiCal 测试提醒',
      body: '看到这条就说明：通知权限拿到了、定时排上了、系统闹钟也唤醒了。',
      scheduledDate: tz.TZDateTime.from(when.toUtc(), tz.local),
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDesc,
          importance: Importance.high,
          priority: Priority.high,
          color: Color(0xFF6366F1),
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  /// 立即发一条通知（改期提醒用，不排期）
  static Future<void> notifyNow({required String title, required String body}) async {
    await init();
    await _plugin.show(
      id: 990002,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDesc,
          importance: Importance.high,
          priority: Priority.high,
          color: Color(0xFF6366F1),
        ),
      ),
    );
  }
  static String _prefix(GameEvent e) => e.isDeadline ? '【截止】' : '【开始】';

  static String _offsetLabel(int minutes) {
    final v = -minutes;
    if (v % 1440 == 0) return '${v ~/ 1440} 天后';
    if (v % 60 == 0) return '${v ~/ 60} 小时后';
    return '$v 分钟后';
  }

  /// 事件 id + 提前量 → 通知 id。
  ///
  /// 必须把「完整 id」和「提前量」都算进去：
  /// - 之前只取 id 里的数字，`b123-start` 与 `b123-end` 会撞成同一个 id；
  /// - 之前提前量只取分钟个位，-1440 与 -60 都变成 0，同一事件的两条提醒互相覆盖。
  @visibleForTesting
  static int notificationIdFor(String eventId, int minutes) {
    // FNV-1a 32 位，稳定且分布均匀（不依赖 Dart 的 hashCode 实现）
    var hash = 0x811C9DC5;
    for (final unit in '$eventId#$minutes'.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash % 0x7FFFFFFF;
  }
}
