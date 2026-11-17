import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 官号头像的本地缓存：按 gameId 存成 `<appSupport>/avatars/<gameId>.jpg`。
/// 头像来自 B 站账号接口，只在本机使用，不上传。
class AvatarStore {
  static final Map<String, String> paths = {};

  static String? pathOf(String gameId) {
    final path = paths[gameId];
    if (path == null) return null;
    return File(path).existsSync() ? path : null;
  }

  static Future<void> load() async {
    try {
      final dir = await _dir();
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.endsWith('.jpg')) continue;
        paths[name.substring(0, name.length - 4)] = entity.path;
      }
    } catch (_) {
      // 拿不到目录就当没有头像，退回首字图标
    }
  }

  /// 下载并落盘；失败返回 null，不影响主流程
  static Future<String?> download(String gameId, String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.refererHeader, 'https://www.bilibili.com/');
      request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 (Linux; Android 14) NijiCal');
      final response = await request.close();
      if (response.statusCode != 200) return null;
      final bytes = await response.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      if (bytes.isEmpty) return null;

      final dir = await _dir();
      final file = File('${dir.path}/$gameId.jpg');
      await file.writeAsBytes(bytes);
      paths[gameId] = file.path;
      return file.path;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/avatars');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }
}
