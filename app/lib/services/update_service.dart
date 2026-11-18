import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'prefs.dart';

/// 应用内更新：从仓库里的 updates/latest.json 读最新版本，
/// 比当前 versionCode 新就下载 APK 并唤起系统安装器（覆盖安装，不丢数据）。
class UpdateService {
  /// 清单地址：公开仓库的 raw 文件，无需 token
  static const manifestUrl =
      'https://raw.githubusercontent.com/maker114/NijiCal/main/updates/latest.json';

  static const repositoryUrl = 'https://github.com/maker114/NijiCal';

  static const _channel = MethodChannel('nijical/power');

  /// 查询最新版本；网络失败返回 (null, 错误说明)
  static Future<(UpdateInfo?, String?)> check() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(Uri.parse(manifestUrl));
      request.headers.set(HttpHeaders.userAgentHeader, 'NijiCal');
      final response = await request.close();
      if (response.statusCode != 200) {
        return (null, '仓库清单返回 ${response.statusCode}');
      }
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body);
      if (json is! Map) return (null, '清单格式不对');
      return (UpdateInfo.fromJson(json.cast<String, dynamic>()), null);
    } on SocketException {
      return (null, '连不上 GitHub，检查网络');
    } catch (e) {
      return (null, '检查失败：${'$e'.split('\n').first}');
    } finally {
      client.close(force: true);
    }
  }

  /// 下载 APK 到缓存目录，返回本地路径
  static Future<String> download(UpdateInfo info, {void Function(double)? onProgress}) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/NijiCal-${info.version}.apk');
    if (await file.exists()) await file.delete();

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(Uri.parse(info.apkUrl));
      request.headers.set(HttpHeaders.userAgentHeader, 'NijiCal');
      final response = await request.close();
      if (response.statusCode != 200) {
        throw Exception('下载失败：HTTP ${response.statusCode}');
      }
      final total = response.contentLength;
      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.close();
      return file.path;
    } finally {
      client.close(force: true);
    }
  }

  /// 交给系统安装器；返回 false 表示没装成（多半是没给「安装未知应用」权限）
  static Future<bool> install(String apkPath) async {
    try {
      final ok = await _channel.invokeMethod<bool>('installApk', {'path': apkPath});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 上次检查时间（只是给界面显示，不参与逻辑）
  static Future<DateTime?> lastChecked() => Prefs.loadUpdateCheckedAt();

  static Future<void> markChecked() => Prefs.saveUpdateCheckedAt(DateTime.now());
}

class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.versionCode,
    required this.apkUrl,
    required this.notes,
    this.publishedAt,
  });

  final String version;
  final int versionCode;
  final String apkUrl;
  final String notes;
  final String? publishedAt;

  factory UpdateInfo.fromJson(Map<String, dynamic> j) => UpdateInfo(
        version: '${j['version'] ?? ''}',
        versionCode: (j['versionCode'] as num?)?.toInt() ?? 0,
        apkUrl: '${j['apkUrl'] ?? ''}',
        notes: '${j['notes'] ?? ''}',
        publishedAt: j['publishedAt'] as String?,
      );

  bool get usable => version.isNotEmpty && apkUrl.isNotEmpty;
}
