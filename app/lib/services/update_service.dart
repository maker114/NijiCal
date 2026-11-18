import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'prefs.dart';

/// 应用内更新：从仓库的 updates/latest.json 读最新版本，
/// 比当前 versionCode 新就下载 APK 并唤起系统安装器（覆盖安装，不丢数据）。
///
/// 国内网络直连 raw.githubusercontent.com 基本不通，所以清单走 jsDelivr CDN，
/// APK 走 ghfast / ghproxy 这类反向代理，逐级回退。
class UpdateService {
  /// 清单地址：按可用性排序，取第一个成功返回的
  /// 顺序有讲究：jsDelivr 会缓存分支内容几小时，发版后迟迟看不到新版，
  /// 所以实时性要求高的放前面（ghfast / ghproxy 直通 raw，实测无缓存），
  /// jsDelivr 只作兜底。
  static const manifestSources = <String>[
    'https://ghfast.top/https://raw.githubusercontent.com/maker114/NijiCal/main/updates/latest.json',
    'https://ghproxy.net/https://raw.githubusercontent.com/maker114/NijiCal/main/updates/latest.json',
    'https://cdn.jsdelivr.net/gh/maker114/NijiCal@main/updates/latest.json',
    'https://raw.githubusercontent.com/maker114/NijiCal/main/updates/latest.json',
  ];

  /// APK 下载前缀：空串是直连，其余是国内可用的 GitHub 代理
  static const apkPrefixes = <String>[
    '',
    'https://ghfast.top/',
    'https://ghproxy.net/',
  ];

  static const repositoryUrl = 'https://github.com/maker114/NijiCal';

  static const _channel = MethodChannel('nijical/power');

  /// 查询最新版本；全部地址都失败时返回 (null, 说明)
  static Future<(UpdateInfo?, String?)> check() async {
    final tried = <String>[];
    for (final url in manifestSources) {
      try {
        final body = await _getText(url);
        final json = jsonDecode(body);
        if (json is! Map) {
          tried.add('清单格式不对');
          continue;
        }
        final info = UpdateInfo.fromJson(json.cast<String, dynamic>());
        if (!info.usable) {
          tried.add('清单缺字段');
          continue;
        }
        return (info, null);
      } catch (e) {
        tried.add(_short(e));
      }
    }
    return (null, '连不上更新服务器（已试 ${tried.length} 个地址：${tried.join('；')}）');
  }

  /// 下载 APK 到缓存目录，返回本地路径。会依次尝试直连与代理。
  static Future<String> download(UpdateInfo info, {void Function(double)? onProgress}) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/NijiCal-${info.version}.apk');
    final errors = <String>[];

    for (final prefix in apkPrefixes) {
      final url = prefix.isEmpty ? info.apkUrl : '$prefix${info.apkUrl}';
      try {
        if (await file.exists()) await file.delete();
        await _downloadTo(url, file, onProgress);
        final size = await file.length();
        // 代理返回错误页时也会是 200，用体积兜底
        if (size < 1024 * 1024) {
          errors.add('包不完整');
          continue;
        }
        return file.path;
      } catch (e) {
        errors.add(_short(e));
      }
    }
    throw Exception('下载失败（已试 ${errors.length} 个地址：${errors.join('；')}）');
  }

  static Future<void> _downloadTo(String url, File file, void Function(double)? onProgress) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'NijiCal');
      final response = await request.close().timeout(const Duration(seconds: 45));
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final total = response.contentLength;
      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.flush();
      await sink.close();
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> _getText(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'NijiCal');
      final response = await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) throw Exception('HTTP ${response.statusCode}');
      return await response.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }

  static String _short(Object e) {
    final text = '$e'.split('\n').first;
    if (text.contains('SocketException')) return '网络不通';
    if (text.contains('TimeoutException')) return '超时';
    return text.length > 40 ? '${text.substring(0, 40)}…' : text;
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
