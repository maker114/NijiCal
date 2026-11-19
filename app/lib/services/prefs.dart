import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../model.dart';

/// 本机持久化：官号绑定、提醒开关。全部存在设备上，不联网。
abstract class Prefs {
  static const _bindingsKey = 'nijical.bindings';
  static const _remindersKey = 'nijical.reminders';
  static const _accentKey = 'nijical.accent';
  static const _liveKey = 'nijical.liveEvents';
  static const _liveAtKey = 'nijical.liveFetchedAt';
  // 大模型解析配置（key 只存在本机，不上传、不进仓库）
  static const _llmBaseKey = 'nijical.llm.base';
  static const _llmKeyKey = 'nijical.llm.key';
  static const _llmModelKey = 'nijical.llm.model';

  static Future<Map<String, String>> loadLlm() async {
    final sp = await SharedPreferences.getInstance();
    return {
      'baseUrl': sp.getString(_llmBaseKey) ?? 'https://api.deepseek.com',
      'apiKey': sp.getString(_llmKeyKey) ?? '',
      'model': sp.getString(_llmModelKey) ?? 'deepseek-chat',
    };
  }

  static Future<void> saveLlm({required String baseUrl, required String apiKey, required String model}) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_llmBaseKey, baseUrl);
    await sp.setString(_llmKeyKey, apiKey);
    await sp.setString(_llmModelKey, model);
  }

  static Future<List<Map<String, dynamic>>> loadLiveEvents() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_liveKey);
    if (raw == null || raw.isEmpty) return const [];
    return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  }

  static Future<void> saveLiveEvents(List<Map<String, dynamic>> events) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_liveKey, jsonEncode(events));
  }

  static Future<DateTime?> loadLiveFetchedAt() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_liveAtKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  static Future<void> saveLiveFetchedAt(DateTime at) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_liveAtKey, at.toIso8601String());
  }

  static Future<String?> loadAccentId() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_accentKey);
  }

  static Future<void> saveAccentId(String id) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_accentKey, id);
  }

  static Future<Map<String, String>> loadBindings() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_bindingsKey);
    if (raw == null || raw.isEmpty) return {};
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return map.map((k, v) => MapEntry(k, '$v'));
  }

  static Future<void> saveBindings(Map<String, String> bindings) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_bindingsKey, jsonEncode(bindings));
  }

  static Future<bool> loadRemindersEnabled() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_remindersKey) ?? false;
  }

  static Future<void> saveRemindersEnabled(bool value) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_remindersKey, value);
  }
  // 每款游戏的标识色覆盖
  static const _accentsKey = 'nijical.gameAccents';

  static Future<Map<String, int>> loadGameAccents() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_accentsKey);
    if (raw == null || raw.isEmpty) return {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return {};
    return {
      for (final e in decoded.entries)
        if (e.value is num) '${e.key}': (e.value as num).toInt(),
    };
  }

  static Future<void> saveGameAccents(Map<String, int> value) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_accentsKey, jsonEncode(value));
  }  static const _calendarViewKey = 'nijical.calendarView';
  static const _showDeadlineKey = 'nijical.showDeadlineEvents';

  static Future<bool> loadCalendarView() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_calendarViewKey) ?? false;
  }

  static Future<void> saveCalendarView(bool value) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_calendarViewKey, value);
  }

  static Future<bool> loadShowDeadlineEvents() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_showDeadlineKey) ?? false;
  }

  static Future<void> saveShowDeadlineEvents(bool value) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_showDeadlineKey, value);
  }
  // 自定义游戏与被移除的内置游戏
  static const _customGamesKey = 'nijical.customGames';
  static const _hiddenGamesKey = 'nijical.hiddenGames';

  static Future<List<Game>> loadCustomGames() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getStringList(_customGamesKey) ?? const [];
    final out = <Game>[];
    for (final item in raw) {
      try {
        final j = jsonDecode(item);
        if (j is Map) out.add(Game.fromJson(j.cast<String, dynamic>()));
      } catch (_) {}
    }
    return out;
  }

  static Future<void> saveCustomGames(List<Game> games) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(
      _customGamesKey,
      games.map((g) => jsonEncode({
            'id': g.id,
            'name': g.name,
            'short': g.short,
            'accent': '#${g.accent.toARGB32().toRadixString(16).substring(2).toUpperCase()}',
          })).toList(),
    );
  }

  static Future<Set<String>> loadHiddenGames() async {
    final sp = await SharedPreferences.getInstance();
    return (sp.getStringList(_hiddenGamesKey) ?? const []).toSet();
  }

  static Future<void> saveHiddenGames(Set<String> ids) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_hiddenGamesKey, ids.toList());
  }
  // 每款游戏的预测设置
  static const _predictionKey = 'nijical.predictions';

  static Future<Map<String, PredictionSetting>> loadPredictions() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_predictionKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final e in decoded.entries)
          if (e.value is Map) '${e.key}': PredictionSetting.fromJson((e.value as Map).cast<String, dynamic>()),
      };
    } catch (_) {
      return {};
    }
  }

  static Future<void> savePredictions(Map<String, PredictionSetting> value) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
      _predictionKey,
      jsonEncode({
        for (final e in value.entries) e.key: e.value.toJson(),
      }),
    );
  }  // 自动刷新：开关、每天的时间点列表、上次跑过的时段
  static const _autoEnabledKey = 'nijical.auto.enabled';
  static const _autoTimesKey = 'nijical.auto.times';
  static const _autoLastKey = 'nijical.auto.lastSlot';

  static Future<bool> loadAutoEnabled() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_autoEnabledKey) ?? false;
  }

  static Future<void> saveAutoEnabled(bool value) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_autoEnabledKey, value);
  }

  static Future<List<String>> loadAutoTimes() async {
    final sp = await SharedPreferences.getInstance();
    final list = sp.getStringList(_autoTimesKey);
    return (list == null || list.isEmpty) ? const ['12:30', '19:30'] : list;
  }

  static Future<void> saveAutoTimes(List<String> times) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_autoTimesKey, times);
  }

  static Future<String?> loadAutoLastSlot() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_autoLastKey);
  }

  static Future<void> saveAutoLastSlot(String slot) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_autoLastKey, slot);
  }
  // 上次手动检查更新的时间（只用于界面显示）
  static const _updateCheckedKey = 'nijical.update.checkedAt';

  static Future<DateTime?> loadUpdateCheckedAt() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_updateCheckedKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  static Future<void> saveUpdateCheckedAt(DateTime value) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_updateCheckedKey, value.toIso8601String());
  }
  // 每个账号最多读取多少条历史动态（影响抓取页数与送大模型解析的条数）
  static const _maxPostsKey = 'nijical.bili.maxPosts';

  static Future<int> loadBiliMaxPosts() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getInt(_maxPostsKey) ?? 20;
  }

  static Future<void> saveBiliMaxPosts(int value) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_maxPostsKey, value);
  }
  // 手动添加的事件（本机，刷新不会覆盖）
  static const _manualEventsKey = 'nijical.manualEvents';

  static Future<List<Map<String, dynamic>>> loadManualEvents() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getStringList(_manualEventsKey) ?? const <String>[];
    final out = <Map<String, dynamic>>[];
    for (final line in raw) {
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map) out.add(decoded.cast<String, dynamic>());
      } catch (_) {}
    }
    return out;
  }

  static Future<void> saveManualEvents(List<Map<String, dynamic>> events) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_manualEventsKey, [for (final e in events) jsonEncode(e)]);
  }}
