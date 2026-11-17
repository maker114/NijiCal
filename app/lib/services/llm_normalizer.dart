import 'dart:convert';
import 'dart:io';

/// 大模型配置：baseUrl + key + model，全部存在本机。
class LlmConfig {
  const LlmConfig({required this.baseUrl, required this.apiKey, required this.model});

  final String baseUrl;
  final String apiKey;
  final String model;

  bool get ready => apiKey.trim().isNotEmpty;

  static const fallback = LlmConfig(
    baseUrl: 'https://api.deepseek.com',
    apiKey: '',
    model: 'deepseek-chat',
  );
}

/// 一条动态经模型规范化后的结果
class NormalizedEvent {
  const NormalizedEvent({
    required this.gameId,
    required this.type,
    required this.title,
    required this.summary,
    required this.confidence,
    required this.tags,
    this.version,
    this.start,
    this.end,
  });

  final String gameId;
  final String type;
  final String title;
  final String summary;
  final int confidence;
  final List<String> tags;
  final String? version;
  final DateTime? start;
  final DateTime? end;
}

class LlmOutcome {
  const LlmOutcome({this.event, this.error});
  final NormalizedEvent? event;
  final String? error;
}

/// B 站动态 → 结构化事件。
///
/// 设计要点（对应《架构设计》3.2 的解析自动化）：
///   · 只输出 JSON，且字段受白名单约束，模型不能自造类型/游戏；
///   · 时间必须来自原文；只有相对表达（“版本更新后”“本周四”）时一律置 null 并压置信度；
///   · 任何一步失败都丢弃这条动态，**绝不猜时间**。
class LlmNormalizer {
  static const gameIds = {'异环': 'nte', '明日方舟': 'arknights', '终末地': 'endfield', '绝区零': 'zzz'};

  static const types = [
    '前瞻直播', '版本更新', '停服维护', '活动开始', '活动结束',
    '卡池开始', '卡池结束', '兑换码截止', '补偿领取截止',
  ];

  static const tagPool = ['卡池', '活动', '兑换码', '补偿', '维护', '前瞻', '限时', '复刻', '版本'];

  static String buildPrompt({
    required String text,
    required String author,
    required DateTime publishedAt,
  }) {
    final p =
        '${publishedAt.year}-${publishedAt.month.toString().padLeft(2, '0')}-'
        '${publishedAt.day.toString().padLeft(2, '0')} '
        '${publishedAt.hour.toString().padLeft(2, '0')}:${publishedAt.minute.toString().padLeft(2, '0')}';
    return '''你是二游日程抽取器。只输出 JSON 对象，不要解释、不要 markdown。

今天是 ${DateTime.now().year}-${DateTime.now().month}-${DateTime.now().day}（北京时间 UTC+8）。
账号：$author
动态发布时间：$p

动态原文：
"""
$text
"""

输出字段：
{
  "is_event": true/false,
  "game": "异环 | 明日方舟 | 终末地 | 绝区零",
  "version": "x.y" 或 null,
  "type": "${types.join(' | ')}",
  "title": "不超过 18 字",
  "start": "2026-11-20T18:30:00+08:00" 或 null,
  "end": "同上" 或 null,
  "summary": "不超过 60 字",
  "confidence": 0-100 的整数,
  "tags": ["从 ${tagPool.join('/')} 里选，最多 5 个"]
}

规则（违反即为错误输出）：
1. 只有“活动/卡池/维护/版本/兑换码/补偿/前瞻”这类带时间的公告才是 is_event=true；纯立绘、视频、剧情、抽奖转发一律 false。
2. 时间只能来自原文。原文只写“版本更新后”“本周四”“敬请期待”这类相对/模糊表达时，start 和 end 都返回 null，confidence ≤ 60。
3. 年份缺失时按发布时间推断；跨年（12 月发、1 月结束）要正确加一年。
4. 只有开始没有结束就 start 有值、end 为 null；只有截止就 end 有值、start 为 null。
5. 不确定的字段给 null，不要编造版本号。
6. **title 要规范化**：去掉话题标签（#…#）、表情、重复标点、无意义的修饰（如“快来看看吧”），
   写成“对象 + 动作”的短句（例：「2.7 版本前瞻兑换码 11 月 20 日截止」），保留官方专有名词。
   不要把整段正文塞进 title。''';
  }

  static Future<LlmOutcome> normalize({
    required String text,
    required String author,
    required DateTime publishedAt,
    required LlmConfig config,
    String? fallbackGameId,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    if (!config.ready) return const LlmOutcome(error: '未配置大模型 key');
    if (text.trim().length < 8) return const LlmOutcome(error: '正文过短');

    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final uri = Uri.parse('${config.baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions');
      final request = await client.postUrl(uri).timeout(timeout);
      request.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${config.apiKey}');
      request.write(jsonEncode({
        'model': config.model,
        'temperature': 0.1,
        'response_format': {'type': 'json_object'},
        'messages': [
          {'role': 'system', 'content': '你是严格的 JSON 抽取器，只输出 JSON。'},
          {
            'role': 'user',
            'content': buildPrompt(text: text, author: author, publishedAt: publishedAt),
          },
        ],
      }));

      final response = await request.close().timeout(timeout);
      final body = await response.transform(utf8.decoder).join().timeout(timeout);
      if (response.statusCode != 200) {
        return LlmOutcome(error: 'HTTP ${response.statusCode}: ${body.length > 120 ? body.substring(0, 120) : body}');
      }

      final decoded = jsonDecode(body);
      final content = ((decoded['choices'] as List?)?.first as Map?)?['message']?['content'] as String?;
      if (content == null) return const LlmOutcome(error: '响应里没有 content');
      return parse(content, fallbackGameId: fallbackGameId);
    } catch (e) {
      return LlmOutcome(error: e.toString().split('\n').first);
    } finally {
      client.close(force: true);
    }
  }

  /// 解析并校验模型输出；不合格就返回错误，不猜
  static LlmOutcome parse(String content, {String? fallbackGameId}) {
    Map<String, dynamic>? json;
    final openIdx = content.indexOf('{');
    final closeIdx = content.lastIndexOf('}');
    if (openIdx >= 0 && closeIdx > openIdx) {
      try {
        json = (jsonDecode(content.substring(openIdx, closeIdx + 1)) as Map).cast<String, dynamic>();
      } catch (_) {
        json = null;
      }
    }
    if (json == null) return const LlmOutcome(error: 'JSON 解析失败');

    if (json['is_event'] != true) return const LlmOutcome(error: '非事件');

    final gameName = '${json['game'] ?? ''}';
    // 归属以「这条动态是从哪个官号拉下来的」为准：
    // 模型把星铁的公告说成明日方舟也不能改归属，所以 fallback 优先。
    final gameId = fallbackGameId ?? gameIds[gameName];
    if (gameId == null) return LlmOutcome(error: '未知游戏：$gameName');

    final type = '${json['type'] ?? ''}';
    if (!types.contains(type)) return LlmOutcome(error: '未知类型：$type');

    final title = '${json['title'] ?? ''}'.trim();
    if (title.isEmpty) return const LlmOutcome(error: '标题为空');

    final start = _parseTime(json['start']);
    final end = _parseTime(json['end']);
    if (start == null && end == null) return const LlmOutcome(error: '没有可用时间');

    final version = _validVersion(json['version']);
    final tags = <String>[];
    for (final t in (json['tags'] as List? ?? const [])) {
      final s = '$t';
      if (tagPool.contains(s) && !tags.contains(s)) tags.add(s);
      if (tags.length >= 5) break;
    }

    final rawConfidence = json['confidence'];
    final confidence = (rawConfidence is num
            ? rawConfidence.toInt()
            : int.tryParse('$rawConfidence') ?? 70)
        .clamp(0, 100);

    return LlmOutcome(
      event: NormalizedEvent(
        gameId: gameId,
        type: type,
        title: title.length > 18 ? title.substring(0, 18) : title,
        summary: '${json['summary'] ?? ''}'.trim(),
        confidence: confidence,
        tags: tags,
        version: version,
        start: start,
        end: end,
      ),
    );
  }

  static DateTime? _parseTime(dynamic value) {
    if (value == null) return null;
    final raw = '$value'.trim();
    if (raw.isEmpty || raw.toLowerCase() == 'null') return null;
    // 带 +08:00 的字符串解析出来已经是正确的瞬时点，不要再加 8 小时；
    // 展示时由 format.wall() 统一换成北京时间。
    return DateTime.tryParse(raw);
  }

  static String? _validVersion(dynamic value) {
    if (value == null) return null;
    final raw = '$value'.trim();
    return RegExp(r'^\d+\.\d+$').hasMatch(raw) ? raw : null;
  }

  /// 把「前瞻总结视频」的文字材料压成要点。返回纯文本，失败返回 null。
  ///
  /// 长字幕先分段提炼事实，再汇总成结构化要点：直接单次压缩会丢细节，
  /// 实测只写得出 6 条泛泛的话。
  static Future<String?> summarizeVideo({
    required String material,
    required String gameName,
    required LlmConfig config,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (!config.ready) return null;

    // 长文先分段提炼（每段 4000 字左右）
    final notes = <String>[];
    if (material.length > 5000) {
      final chunks = _splitChunks(material, 4000);
      for (final chunk in chunks) {
        final part = await _chat(
          config,
          system: '你是二游资讯编辑，只输出要点列表。',
          user: '''下面是《$gameName》前瞻总结视频的一段文字（第 ${notes.length + 1}/${chunks.length} 段）。
只提取这一段里明确出现的事实：版本号、新角色、卡池与复刻、皮肤、玩法更新、活动、时间节点、价格或兑换码。
每条一行，以「- 」开头，尽量保留具体数字与专有名词，不要客套话。

"""
$chunk
"""''',
          maxTokens: 800,
          timeout: timeout,
        );
        if (part != null && part.trim().isNotEmpty) notes.add(part.trim());
      }
    }

    final body = notes.isEmpty ? material : notes.join('\n');
    return _chat(
      config,
      system: '你是二游资讯编辑，输出结构化的中文要点，不要客套话。',
      user: '''这是《$gameName》一次前瞻直播的总结材料（标题/简介/字幕要点）：
"""
$body
"""

请整理成一份**有信息量**的前瞻速览，按下面四组输出（某组没有内容就整组省略）：
【版本内容】版本号与新内容、新角色/新皮肤、玩法改动
【卡池】UP 角色与武器、复刻安排、开放时间
【活动与福利】活动玩法、签到、兑换码、补偿
【时间节点】版本更新、卡池与活动的起止时间

要求：
- 每组 2～6 条，每条以「- 」开头，写清楚**具体名字、数量、时间、价格**；
- 允许每条长一些（30～80 字），不要压缩成一句空话；
- 只写材料里明确提到的内容，不确定的不要编；
- 不要输出「视频讲了什么」这类元信息，也不要重复标题。''',
      maxTokens: 2000,
      timeout: timeout,
    );
  }

  /// 按段落/句号切成若干块，尽量避免把一句话切断
  static List<String> _splitChunks(String text, int size) {
    final out = <String>[];
    var cursor = 0;
    while (cursor < text.length) {
      var end = (cursor + size).clamp(0, text.length);
      if (end < text.length) {
        final window = text.substring(cursor, end);
        final cut = window.lastIndexOf(RegExp(r'[。！？.!?\n]'));
        if (cut > size ~/ 2) end = cursor + cut + 1;
      }
      out.add(text.substring(cursor, end));
      cursor = end;
    }
    return out;
  }

  /// 一次 chat 调用
  static Future<String?> _chat(
    LlmConfig config, {
    required String system,
    required String user,
    required int maxTokens,
    required Duration timeout,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final uri = Uri.parse('${config.baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions');
      final request = await client.postUrl(uri).timeout(timeout);
      request.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${config.apiKey}');
      request.write(jsonEncode({
        'model': config.model,
        'temperature': 0.2,
        'max_tokens': maxTokens,
        'messages': [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': user},
        ],
      }));
      final response = await request.close().timeout(timeout);
      final body = await response.transform(utf8.decoder).join().timeout(timeout);
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(body);
      final content = ((decoded['choices'] as List?)?.first as Map?)?['message']?['content'] as String?;
      final text = (content ?? '').trim();
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
  /// 设置页的连通性测试
  static Future<String> test(LlmConfig config) async {
    final outcome = await normalize(
      text: '【测试】《终末地》1.2 版本更新维护：2026 年 11 月 20 日 06:00 ~ 11:00',
      author: '连通性测试',
      publishedAt: DateTime.now(),
      config: config,
      timeout: const Duration(seconds: 30),
    );
    if (outcome.event != null) return 'ok';
    return outcome.error ?? '未知错误';
  }
}

