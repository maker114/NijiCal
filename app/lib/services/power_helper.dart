import 'package:flutter/services.dart';

/// 与原生层的小桥：跳「自启动管理」和「忽略电池优化」。
/// 国产 ROM 上不点这两个，WorkManager 到点也不会被唤醒。
class PowerHelper {
  static const _channel = MethodChannel('nijical/power');

  /// 打开厂商的自启动管理页；失败会退回应用详情页
  static Future<bool> openAutoStart() async {
    try {
      final ok = await _channel.invokeMethod<bool>('openAutoStart');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 申请忽略电池优化
  static Future<bool> requestIgnoreBattery() async {
    try {
      final ok = await _channel.invokeMethod<bool>('requestIgnoreBattery');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> isIgnoringBattery() async {
    try {
      final ok = await _channel.invokeMethod<bool>('isIgnoringBattery');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}
