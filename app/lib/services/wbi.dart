import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'bili_service.dart';

/// B 站 WBI 签名。
///
/// 2023 年起 `x/web-interface/search/*`、`x/space/wbi/*` 等接口要求带 `w_rid` + `wts`：
///   1. 取 nav 里的 wbi_img，得到 img_key / sub_key；
///   2. 按固定 64 项重排表拼出 mixin key（取前 32 位）；
///   3. 参数按 key 排序、过滤 `!'()*`、URL 编码后拼成 query，加上 wts；
///   4. w_rid = md5(query + mixinKey)。
class Wbi {
  static String? _mixinKey;
  static DateTime? _fetchedAt;

  static const List<int> _mixinKeyEncTab = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
    27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
    37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
    22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
  ];

  /// 取 mixin key（缓存 12 小时）
  static Future<String?> mixinKey(WebViewController controller) async {
    final now = DateTime.now();
    if (_mixinKey != null && _fetchedAt != null && now.difference(_fetchedAt!).inHours < 12) {
      return _mixinKey;
    }
    final json = await BiliService.fetchJson(
      controller,
      'https://api.bilibili.com/x/web-interface/nav',
    );
    final data = json?['data'];
    final img = data is Map ? data['wbi_img'] : null;
    if (img is! Map) return null;
    final imgUrl = '${img['img_url'] ?? ''}';
    final subUrl = '${img['sub_url'] ?? ''}';
    final imgKey = _keyOf(imgUrl);
    final subKey = _keyOf(subUrl);
    if (imgKey.isEmpty || subKey.isEmpty) return null;

    final raw = imgKey + subKey;
    final buf = StringBuffer();
    for (final i in _mixinKeyEncTab) {
      if (i < raw.length) buf.write(raw[i]);
    }
    final key = buf.toString();
    if (key.length < 32) return null;
    _mixinKey = key.substring(0, 32);
    _fetchedAt = now;
    return _mixinKey;
  }

  static String _keyOf(String url) {
    final name = url.split('/').last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// 给参数加上 wts 与 w_rid，返回可直接请求的完整 URL
  static Future<String?> sign(
    WebViewController controller,
    String baseUrl,
    Map<String, String> params,
  ) async {
    final mixin = await mixinKey(controller);
    if (mixin == null) return null;

    final all = <String, String>{
      ...params,
      'wts': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
    };
    final keys = all.keys.toList()..sort();

    String clean(String v) => v.replaceAll(RegExp(r"[!'()*]"), '');

    final query = keys
        .map((k) => '${Uri.encodeComponent(k)}=${Uri.encodeComponent(clean(all[k]!))}')
        .join('&');
    final rid = _md5(query + mixin);
    return '$baseUrl?$query&w_rid=$rid';
  }

  // ---------------------------------------------------------------- MD5

  @visibleForTesting
  static String md5Of(String input) => _md5(input);

  static String _md5(String input) {
    final bytes = utf8.encode(input);
    final length = bytes.length;
    final bitLen = length * 8;

    final withPad = <int>[...bytes, 0x80];
    while (withPad.length % 64 != 56) {
      withPad.add(0);
    }
    for (var i = 0; i < 8; i++) {
      withPad.add((bitLen >> (8 * i)) & 0xff);
    }

    const s = [
      7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
      5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
      4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
      6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ];
    // MD5 标准常量表（不要用浮点现算，末位一错整串签名就废）
    const k = <int>[
      0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
      0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
      0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
      0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
      0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
      0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
      0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
      0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
      0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
      0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
      0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
      0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
      0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
      0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
      0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
      0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    ];

    var a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;

    for (var chunk = 0; chunk < withPad.length; chunk += 64) {
      final m = List<int>.generate(16, (i) => 0);
      for (var i = 0; i < 16; i++) {
        final base = chunk + i * 4;
        m[i] = withPad[base] |
            (withPad[base + 1] << 8) |
            (withPad[base + 2] << 16) |
            (withPad[base + 3] << 24);
      }

      var a = a0, b = b0, c = c0, d = d0;
      for (var i = 0; i < 64; i++) {
        int f, g;
        if (i < 16) {
          f = (b & c) | ((~b) & d);
          g = i;
        } else if (i < 32) {
          f = (d & b) | ((~d) & c);
          g = (5 * i + 1) % 16;
        } else if (i < 48) {
          f = b ^ c ^ d;
          g = (3 * i + 5) % 16;
        } else {
          f = c ^ (b | (~d));
          g = (7 * i) % 16;
        }
        f = (f + a + k[i] + m[g]) & 0xffffffff;
        a = d;
        d = c;
        c = b;
        b = (b + _rotateLeft(f, s[i])) & 0xffffffff;
      }

      a0 = (a0 + a) & 0xffffffff;
      b0 = (b0 + b) & 0xffffffff;
      c0 = (c0 + c) & 0xffffffff;
      d0 = (d0 + d) & 0xffffffff;
    }

    String hex(int v) => v
        .toUnsigned(32)
        .toRadixString(16)
        .padLeft(8, '0')
        .replaceFirstMapped(RegExp(r'^(..)(..)(..)(..)$'), (m) => '${m[4]}${m[3]}${m[2]}${m[1]}');

    return '${hex(a0)}${hex(b0)}${hex(c0)}${hex(d0)}';
  }

  static int _rotateLeft(int x, int c) => ((x << c) | (x >> (32 - c))) & 0xffffffff;
}
