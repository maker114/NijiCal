import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 写文件日志：某些机型（如 MIUI）会吞掉 release 包的 logcat 输出，
/// 排查时把关键步骤落到应用外部目录，用 adb pull 取即可。
/// 正式功能不依赖它，失败一律静默。
class DebugLog {
  static File? _file;

  static Future<void> write(String message) async {
    try {
      _file ??= await _resolve();
      final f = _file;
      if (f == null) return;
      await f.writeAsString(
        '${DateTime.now().toIso8601String()}  $message\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // 忽略
    }
  }

  static Future<File?> _resolve() async {
    try {
      final dir = await getExternalStorageDirectory();
      if (dir == null) return null;
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return File('${dir.path}/nijical.log');
    } catch (_) {
      return null;
    }
  }
}
