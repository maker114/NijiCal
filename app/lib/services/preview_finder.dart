import 'dart:convert';

import 'package:webview_flutter/webview_flutter.dart';

import 'bili_service.dart';
import 'debug_log.dart';
import 'wbi.dart';
import 'llm_normalizer.dart';

/// 一条「错过前瞻」的补救信息：找到了总结视频，并把它转成了文字。
class PreviewSummary {
  const PreviewSummary({
    required this.bvid,
    required this.title,
    required this.owner,
    required this.summary,
    required this.hasSubtitle,
    required this.url,
  });

  final String bvid;
  final String title;
  final String owner;

  /// 交给大模型压缩后的要点
  final String summary;

  /// 这段文字是来自字幕，还是只用了视频简介
  final bool hasSubtitle;

  final String url;

  Map<String, dynamic> toJson() => {
        'bvid': bvid,
        'title': title,
        'owner': owner,
        'summary': summary,
        'hasSubtitle': hasSubtitle,
        'url': url,
      };

  static PreviewSummary? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final bvid = raw['bvid'] as String?;
    final summary = raw['summary'] as String?;
    if (bvid == null || summary == null) return null;
    return PreviewSummary(
      bvid: bvid,
      title: raw['title'] as String? ?? '',
      owner: raw['owner'] as String? ?? '',
      summary: summary,
      hasSubtitle: raw['hasSubtitle'] as bool? ?? false,
      url: raw['url'] as String? ?? 'https://www.bilibili.com/video/$bvid',
    );
  }
}

/// 前瞻直播错过补救：
///   1. 在 B 站搜索里找一条“总结/复盘”类视频
///   2. 取视频信息，尽量拿字幕
///   3. 把标题 + 简介（+ 字幕）交给大模型压成要点
class PreviewFinder {

  /// 关键词：游戏名 + 版本 + 总结类词
  static String keywordFor(String gameName, String title) {
    final version = RegExp(r'(\d+(?:\.\d+)?)\s*版本').firstMatch(title)?.group(1);
    final parts = <String>[gameName, if (version != null) '$version 版本', '前瞻 总结'];
    return parts.join(' ');
  }

  /// 第一步：在搜索结果页里找视频链接。
  /// 搜索页是 SPA：等渲染 → 滚一屏触发懒加载 → 再扫一次；PC 版没结果就换移动版。
  static Future<({String bvid, String text})?> searchVideo(
    WebViewController controller,
    String keyword,
  ) async {
    final encoded = Uri.encodeComponent(keyword);
    final sources = <String>[
      'https://search.bilibili.com/all?keyword=$encoded&order=pubdate',
      'https://m.bilibili.com/search?keyword=$encoded',
    ];

    // 先试接口：结构化数据，最稳
    final apiHits = await _searchApi(controller, keyword);
    if (apiHits.isNotEmpty) {
      const hints = ['总结', '汇总', '复盘', '一览', '速看', '回顾'];
      for (final hit in apiHits) {
        if (hints.any(hit.text.contains)) return hit;
      }
      return apiHits.first;
    }

    // 接口不可用再退回解析页面
    for (final url in sources) {
      final found = await _scanSearchPage(controller, url);
      if (found != null) return found;
    }
    return null;
  }

  /// 直接用搜索接口（比解析 SPA 页面可靠）。返回候选 bvid 列表。
  static Future<List<({String bvid, String text})>> _searchApi(
    WebViewController controller,
    String keyword,
  ) async {
    // 搜索接口要 WBI 签名，否则一律 412
    final signed = await Wbi.sign(
      controller,
      'https://api.bilibili.com/x/web-interface/wbi/search/type',
      {
        'search_type': 'video',
        'keyword': keyword,
        'page': '1',
        'page_size': '20',
      },
    );
    await DebugLog.write('search api signed=${signed != null}');
    if (signed == null) return const [];
    final json = await BiliService.fetchJson(controller, signed);
    if (json == null) return const [];
    final code = json['code'];
    await DebugLog.write('search api code=$code');
    if (code != 0) return const [];
    final data = json['data'];
    final result = data is Map ? data['result'] : null;
    if (result is! List) return const [];
    final out = <({String bvid, String text})>[];
    for (final item in result.whereType<Map>()) {
      final bvid = '${item['bvid'] ?? ''}';
      if (!bvid.startsWith('BV')) continue;
      final title = '${item['title'] ?? ''}'.replaceAll(RegExp(r'<[^>]+>'), '');
      out.add((bvid: bvid, text: title));
    }
    return out;
  }
  static Future<({String bvid, String text})?> _scanSearchPage(
    WebViewController controller,
    String url,
  ) async {
    try {
      await controller.loadRequest(Uri.parse(url));
    } catch (e) {
      await DebugLog.write('search load failed url=$url err=$e');
      return null;
    }

    // 直接扫整页 HTML 里的 BV 号：不同版本的结果页结构差异大，
    // 但视频链接一定带 BV 号。
    const scan = '''
      (() => {
        const html = document.documentElement.outerHTML;
        const ids = [];
        const re = /BV[0-9A-Za-z]{10}/g;
        let m;
        while ((m = re.exec(html)) !== null) {
          if (!ids.includes(m[0])) ids.push(m[0]);
        }
        return JSON.stringify({ total: document.querySelectorAll('a').length, items: ids.slice(0, 20) });
      })()    ''';

    for (var attempt = 0; attempt < 3; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 2200));
      // 触发懒加载
      await BiliService.runJs(controller, 'window.scrollTo(0, document.body.scrollHeight * 0.6); 0');

      String raw;
      try {
        raw = await BiliService.runJs(controller, scan);
      } catch (e) {
        await DebugLog.write('scan js failed attempt=$attempt err=$e');
        continue;
      }

      List<dynamic> items = const [];
      var total = 0;
      try {
        final decoded = jsonDecode(raw);
        items = (decoded['items'] as List?) ?? const [];
        total = (decoded['total'] as num?)?.toInt() ?? 0;
      } catch (e) {
        await DebugLog.write('decode failed attempt=$attempt err=$e');
        continue;
      }

      await DebugLog.write('search attempt=$attempt anchors=$total hits=${items.length} url=$url');
      if (items.isEmpty) continue;

      final ids = items.whereType<String>().where((s) => s.startsWith('BV')).toList();
      if (ids.isEmpty) continue;
      return (bvid: ids.first, text: '');
    }
    return null;
  }
  /// 第二步：视频信息（标题 / 简介 / cid / UP 名）
  static Future<Map<String, dynamic>?> videoInfo(WebViewController controller, String bvid) async {
    final json = await BiliService.fetchJson(
      controller,
      'https://api.bilibili.com/x/web-interface/view?bvid=$bvid',
    );
    final data = json?['data'];
    return data is Map ? data.cast<String, dynamic>() : null;
  }

  /// 第三步：字幕（需要登录态，拿不到就返回空）
  static Future<String> subtitles(
    WebViewController controller,
    String bvid,
    int cid,
  ) async {
    try {
      final info = await BiliService.fetchJson(
        controller,
        'https://api.bilibili.com/x/player/v2?bvid=$bvid&cid=$cid',
      );
      final data = info?['data'];
      final subtitle = data is Map ? data['subtitle'] : null;
      final list = (subtitle is Map ? subtitle['subtitles'] : null) as List?;
      if (list == null || list.isEmpty) return '';

      // 优先中文
      Map? picked;
      for (final item in list) {
        if (item is Map && '${item['lan']}'.startsWith('zh')) {
          picked = item;
          break;
        }
      }
      picked ??= list.first is Map ? list.first as Map : null;
      final url = picked?['subtitle_url'] as String?;
      if (url == null || url.isEmpty) return '';

      final json = await BiliService.fetchJson(
        controller,
        url.startsWith('//') ? 'https:$url' : url,
      );
      final body = json?['body'];
      if (body is! List) return '';
      final text = body
          .whereType<Map>()
          .map((e) => '${e['content'] ?? ''}')
          .where((s) => s.isNotEmpty)
          .join(' ');
      return text;
    } catch (_) {
      return '';
    }
  }

  /// 把视频内容压成要点。失败返回 null，界面显示“没找到/失败”。
  static Future<PreviewSummary?> build(
    WebViewController controller, {
    required String gameName,
    required String eventTitle,
    required LlmConfig config,
  }) async {
    final keyword = keywordFor(gameName, eventTitle);
    await DebugLog.write('preview build keyword=$keyword');
    final found = await searchVideo(controller, keyword);
    if (found == null) return null;

    final info = await videoInfo(controller, found.bvid);
    if (info == null) return null;

    final title = '${info['title'] ?? ''}';
    final desc = '${info['desc'] ?? ''}';
    final owner = '${(info['owner'] as Map?)?['name'] ?? ''}';
    final pages = info['pages'];
    final cid = pages is List && pages.isNotEmpty && pages.first is Map
        ? (pages.first['cid'] as num?)?.toInt()
        : (info['cid'] as num?)?.toInt();

    var subtitleText = '';
    if (cid != null) {
      subtitleText = await subtitles(controller, found.bvid, cid);
    }

    final material = StringBuffer()
      ..writeln('视频标题：$title')
      ..writeln('UP 主：$owner')
      ..writeln('视频简介：$desc');
    if (subtitleText.isNotEmpty) {
      material.writeln('字幕（截取前 4000 字）：');
      material.writeln(subtitleText.length > 4000 ? subtitleText.substring(0, 4000) : subtitleText);
    }

    final outcome = await LlmNormalizer.summarizeVideo(
      material: material.toString(),
      gameName: gameName,
      config: config,
    );
    if (outcome == null) return null;

    return PreviewSummary(
      bvid: found.bvid,
      title: title,
      owner: owner,
      summary: outcome,
      hasSubtitle: subtitleText.isNotEmpty,
      url: 'https://www.bilibili.com/video/${found.bvid}',
    );
  }
}
