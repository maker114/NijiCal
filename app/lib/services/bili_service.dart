import 'dart:async';
import 'dart:convert';

import 'package:webview_flutter/webview_flutter.dart';

import '../model.dart';
import 'llm_normalizer.dart';

/// B 站动态读取：凭据只活在 WebView 自己的 cookie 里，代码不接触 SESSDATA。
///
/// 做法：把 WebView 直接导航到 `api.bilibili.com` 的接口地址，
/// 浏览器自动带上该域的 cookie，页面正文就是一段 JSON，读 `document.body.innerText` 即可。
class BiliService {
  static const _api = 'https://api.bilibili.com';
  static const _features = 'itemOpusStyle,listOnlyfans,opusBigCover,onlyfansVote';

  /// 检查登录态：nav 接口的 data.isLogin
  static Future<bool> isLoggedIn(WebViewController controller) async {
    final json = await _getJson(controller, '$_api/x/web-interface/nav');
    if (json == null) return false;
    final data = json['data'];
    return data is Map && data['isLogin'] == true;
  }

  /// 探针：给界面用，区分「没登录」和「压根没拿到 JSON」
  static Future<String> loginProbe(WebViewController controller) async {
    final json = await _getJson(controller, '$_api/x/web-interface/nav');
    if (json == null) return 'no-json';
    final data = json['data'];
    if (data is Map && data['isLogin'] == true) return 'ok';
    return 'not-login';
  }

  /// 一次拿到名称与头像（添加游戏时用）
  static Future<({String? name, String? face})> userInfo(
    WebViewController controller,
    String mid,
  ) async {
    final json = await _getJson(controller, '$_api/x/web-interface/card?mid=$mid');
    final data = json?['data'];
    final card = data is Map ? data['card'] : null;
    if (card is Map) {
      return (name: card['name'] as String?, face: card['face'] as String?);
    }
    // 有些号 card 拿不到，退一步用 nav 的 uname
    final nav = await _getJson(controller, '$_api/x/web-interface/nav');
    final navData = nav?['data'];
    if (navData is Map && navData['mid']?.toString() == mid) {
      return (name: navData['uname'] as String?, face: navData['face'] as String?);
    }
    return (name: null, face: null);
  }
  /// 官号头像地址（来自 card 接口）
  static Future<String?> faceOf(WebViewController controller, String mid) async {
    final json = await _getJson(controller, '$_api/x/web-interface/card?mid=$mid');
    final data = json?['data'];
    final card = data is Map ? data['card'] : null;
    if (card is Map) return card['face'] as String?;
    return null;
  }
  /// 当前登录的账号名（用来在刷新界面上显示“用的是谁的号”）
  static Future<String?> accountName(WebViewController controller) async {
    final json = await _getJson(controller, '$_api/x/web-interface/nav');
    final data = json?['data'];
    if (data is Map && data['isLogin'] == true) return data['uname'] as String?;
    return null;
  }
  /// 拉一个 UP 的最近动态
  static Future<List<Map<String, dynamic>>> fetchSpace(
    WebViewController controller,
    String mid, {
    int pages = 2,
    bool Function(List<Map<String, dynamic>> accumulated)? stopWhen,
  }) async {
    final out = <Map<String, dynamic>>[];
    var offset = '';
    for (var page = 0; page < pages; page++) {
      final url = '$_api/x/polymer/web-dynamic/v1/feed/space'
          '?host_mid=$mid&offset=${Uri.encodeComponent(offset)}'
          '&timezone_offset=-480&features=$_features';
      var json = await _getJson(controller, url);
      if (json == null) break;
      var code = json['code'];
      // -352 / -412 是风控与限流：等一会儿重试一次，别直接把这号判死
      if (code == -352 || code == -412 || code == -509) {
        await Future<void>.delayed(const Duration(seconds: 4));
        json = await _getJson(controller, url);
        code = json?['code'];
      }
      if (json == null) break;
      if (code != 0) {
        throw BiliException('接口返回 code=$code ${json['message'] ?? ''}');
      }
      final data = json['data'];
      if (data is! Map) break;
      for (final item in (data['items'] as List? ?? const [])) {
        if (item is Map) out.add(item.cast<String, dynamic>());
      }
      final next = data['offset'];
      // 够数就停：调用方按「预筛后可用条数」判断，避免读到 20 条却只有 13 条能解析
      if (stopWhen != null && stopWhen(out)) break;
      if (data['has_more'] != true || next is! String || next.isEmpty) break;
      offset = next;
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    return out;
  }

  /// 给其它服务复用的 JSON 抓取（同样的 WebView + cookie 策略）
  static Future<Map<String, dynamic>?> fetchJson(WebViewController controller, String url) =>
      _getJson(controller, url);

  /// 在页面里执行 JS 并拿到字符串结果。
  /// 安卓端返回值常被 JSON 编码过一次（`"{\"a\":1}"`），这里统一还原成原始字符串。
  static Future<String> runJs(WebViewController controller, String script) async {
    final raw = await controller.runJavaScriptReturningResult(script);
    final text = raw is String ? raw : '$raw';
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is String) return decoded;
      } catch (_) {
        // 还原失败就用原样
      }
    }
    return text;
  }
  static Future<Map<String, dynamic>?> _getJson(WebViewController controller, String url) async {
    final done = Completer<void>();
    controller.setNavigationDelegate(NavigationDelegate(
      onPageFinished: (_) {
        if (!done.isCompleted) done.complete();
      },
      onWebResourceError: (_) {
        if (!done.isCompleted) done.complete();
      },
    ));
    await controller.loadRequest(Uri.parse(url));
    await done.future.timeout(const Duration(seconds: 20), onTimeout: () {});
    await Future<void>.delayed(const Duration(milliseconds: 400));

    for (var attempt = 0; attempt < 2; attempt++) {
      final raw = await controller.runJavaScriptReturningResult('document.body.innerText');
      final parsed = _parseLoose(raw);
      if (parsed != null) return parsed;
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }
    return null;
  }

  /// 容忍三种形态：原始 JSON / 被 JSON 编码过的字符串 / 外面包了一层 HTML
  static Map<String, dynamic>? _parseLoose(dynamic raw) {
    var text = raw is String ? raw : '$raw';
    for (var round = 0; round < 3; round++) {
      final start = text.indexOf('{');
      final end = text.lastIndexOf('}');
      if (start >= 0 && end > start) {
        try {
          final value = jsonDecode(text.substring(start, end + 1));
          if (value is Map) return value.cast<String, dynamic>();
        } catch (_) {
          // 继续尝试“先整体 jsonDecode”
        }
      }
      try {
        final outer = jsonDecode(text);
        if (outer is Map) return outer.cast<String, dynamic>();
        if (outer is String) {
          text = outer;
          continue;
        }
      } catch (_) {}
      break;
    }
    return null;
  }

  /// 动态正文（给大模型当输入）
  static String dynamicsText(Map<String, dynamic> item) {
    final modules = (item['modules'] as Map?)?.cast<String, dynamic>() ?? const {};
    final dyn = (modules['module_dynamic'] as Map?)?.cast<String, dynamic>() ?? const {};
    final desc = (dyn['desc'] as Map?)?['text'] as String? ?? '';
    final major = (dyn['major'] as Map?)?.cast<String, dynamic>() ?? const {};

    var text = desc.trim();
    if (text.isEmpty) {
      final opus = (major['opus'] as Map?)?.cast<String, dynamic>();
      if (opus != null) {
        final summary = (opus['summary'] as Map?)?['text'] as String? ?? '';
        final title = opus['title'] as String? ?? '';
        text = '${title.isEmpty ? '' : '$title '}$summary'.trim();
      }
    }
    if (text.isEmpty) {
      final orig = (dyn['orig'] as Map?)?.cast<String, dynamic>();
      final origDyn = (orig?['modules'] as Map?)?['module_dynamic'] as Map?;
      final fwd = (origDyn?['desc'] as Map?)?['text'] as String? ?? '';
      if (fwd.isNotEmpty) text = fwd.trim();
    }
    return text;
  }

  static String authorOf(Map<String, dynamic> item) {
    final modules = (item['modules'] as Map?)?.cast<String, dynamic>() ?? const {};
    final author = (modules['module_author'] as Map?)?.cast<String, dynamic>() ?? const {};
    return author['name'] as String? ?? '官方';
  }

  /// B 站同一个字段有时是 num、有时是字符串，统一用这个取
  static int? asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static DateTime publishedAtOf(Map<String, dynamic> item) {
    final modules = (item['modules'] as Map?)?.cast<String, dynamic>() ?? const {};
    final author = (modules['module_author'] as Map?)?.cast<String, dynamic>() ?? const {};
    final ts = asInt(author['pub_ts']);
    if (ts != null && ts > 0) return DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    return DateTime.now();
  }

  static String idOf(Map<String, dynamic> item) => '${item['id_str'] ?? item['id'] ?? ''}';

  /// 规范化结果 → 事件
  static GameEvent fromNormalized({
    required NormalizedEvent n,
    required String author,
    required String dynamicId,
    required DateTime fetchedAt,
    required String sourceHash,
  }) {
    return GameEvent(
      id: 'b$dynamicId',
      gameId: n.gameId,
      type: n.type,
      title: n.title,
      start: n.start,
      end: n.end,
      status: n.confidence >= 85 && n.start != null ? EventStatus.confirmed : EventStatus.tentative,
      confidence: n.confidence,
      summary: n.summary,
      fetchedAt: fetchedAt,
      sourceName: 'B站动态 · $author',
      sourceUrl: 'https://t.bilibili.com/$dynamicId',
      version: n.version,
      sourceHash: sourceHash,
      tags: n.tags,
      revisions: const [],
    );
  }
}

class BiliException implements Exception {
  BiliException(this.message);
  final String message;
  @override
  String toString() => message;
}
