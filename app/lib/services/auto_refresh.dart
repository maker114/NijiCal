import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'headless_refresh.dart';
import 'prefs.dart';
import 'reminder_service.dart';

/// 每天在指定时间点自动刷新。
///
/// 为什么用 WorkManager：App 被划掉、被系统回收后，普通的 Dart Timer 都没了，
/// 只有交给系统的 JobScheduler 才可能在后台被唤醒。
/// WorkManager 的周期任务最小 15 分钟、且不保证准点，所以做法是：
/// 每 15 分钟醒一次，判断「现在是否落在某个设定的时间点之后 20 分钟内，
/// 且这个时间点今天还没跑过」，是才真正执行刷新。
class AutoRefresh {
  static const taskName = 'nijical-auto-refresh';
  static const _uniqueName = 'nijical-auto-refresh-periodic';

  /// 时间点之后多久内还算「该跑」——配合 15 分钟周期，避免刚好错过就整天不跑
  static const _window = Duration(minutes: 25);

  static Future<void> init() async {
    try {
      await Workmanager().initialize(callbackDispatcher);
      await _registerPeriodic();
    } catch (_) {
      // 桌面 / 测试环境没有 WorkManager，忽略
    }
  }

  static Future<void> _registerPeriodic() async {
    try {
      await Workmanager().registerPeriodicTask(
        _uniqueName,
        taskName,
        frequency: const Duration(minutes: 15),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    } catch (_) {}
  }

  static Future<void> reschedule() => _registerPeriodic();

  /// 现在是否有「该跑但没跑」的时间点；有就返回它的标识（日期+时间）
  static Future<String?> dueSlot() async {
    if (!await Prefs.loadAutoEnabled()) return null;
    final times = await Prefs.loadAutoTimes();
    final last = await Prefs.loadAutoLastSlot();

    final now = DateTime.now();
    for (final t in times) {
      final parts = t.split(':');
      if (parts.length != 2) continue;
      final hour = int.tryParse(parts[0]);
      final minute = int.tryParse(parts[1]);
      if (hour == null || minute == null) continue;

      final slot = DateTime(now.year, now.month, now.day, hour, minute);
      if (now.isBefore(slot) || now.difference(slot) > _window) continue;

      final key =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')} $t';
      if (last == key) continue;
      return key;
    }
    return null;
  }

  static Future<HeadlessResult> runNow({bool mark = true}) async {
    final slot = await dueSlot();
    final result = await HeadlessRefresh.run();
    await Prefs.saveAutoResult(result.message);
    if (mark && slot != null) await Prefs.saveAutoLastSlot(slot);
    return result;
  }

  /// 前台兜底：App 活着时用计时器盯，不必等系统唤醒
  static Timer? _timer;

  static void startForegroundWatch(Future<void> Function() onRan) {
    // widget 测试里没有真实时钟，常驻计时器会让测试因「有未完成的 Timer」失败
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) async {
      final slot = await dueSlot();
      if (slot == null) return;
      await Prefs.saveAutoLastSlot(slot);
      final result = await HeadlessRefresh.run();
      await Prefs.saveAutoResult(result.message);
      await ReminderService.notifyNow(
        title: result.ok ? 'NijiCal 自动刷新完成' : 'NijiCal 自动刷新失败',
        body: result.message,
      );
      await onRan();
    });
  }

  static void stopForegroundWatch() {
    _timer?.cancel();
    _timer = null;
  }
}

/// WorkManager 的后台入口：必须是顶层函数且带 vm:entry-point
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      await ReminderService.init();
    } catch (_) {}

    final slot = await AutoRefresh.dueSlot();
    if (slot == null) return true;

    await Prefs.saveAutoLastSlot(slot);
    final result = await HeadlessRefresh.run();
    await Prefs.saveAutoResult(result.message);
    try {
      await ReminderService.notifyNow(
        title: result.ok ? 'NijiCal 定时刷新完成' : 'NijiCal 定时刷新失败',
        body: result.message,
      );
    } catch (_) {}
    return true;
  });
}
