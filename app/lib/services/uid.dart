/// B 站 UID 归一化。
///
/// 从 B 站复制出来的内容经常带前缀或整段链接：
///   `UID:123456`、`uid：123456`、`space.bilibili.com/123456`、
///   `https://space.bilibili.com/123456?spm=...`
/// 统一取其中第一段 3 位以上的数字；取不到就原样返回（去空白）。
String normalizeUid(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return text;

  // 去掉 UID / uid / UID: 这类前缀（中英文冒号都算）
  text = text.replaceAll(RegExp(r'\buid\b\s*[:：]?', caseSensitive: false), '');
  text = text.trim();

  final match = RegExp(r'\d{3,}').firstMatch(text);
  if (match != null) return match.group(0)!;

  // 只有纯数字但不足 3 位时也认
  final digits = text.replaceAll(RegExp(r'\D'), '');
  return digits.isEmpty ? text.replaceAll(RegExp(r'\s+'), '') : digits;
}
