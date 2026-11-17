import 'package:flutter/material.dart';

import 'format.dart';
import 'model.dart';
import 'services/event_diff.dart';
import 'services/prefs.dart';

enum RangeFilter {
  today('今天'),
  week('本周'),
  month('30 天'),
  all('全部');

  const RangeFilter(this.label);
  final String label;
}

/// 日历上的「标签」：把 9 个事件类型归成玩家看得懂的几类。
/// 与游戏筛选是两个并行维度，维度内多选为“或”，维度之间为“与”。
const Map<String, List<String>> kTagGroups = {
  '前瞻': ['前瞻直播'],
  '卡池': ['卡池开始', '卡池结束'],
  '活动': ['活动开始', '活动结束'],
  '更新': ['版本更新', '停服维护'],
  '兑换码': ['兑换码截止'],
  '补偿': ['补偿领取截止'],
};
/// 全局状态：数据 + 筛选 + 官号绑定。MVP 阶段全部在内存里，不落盘。
class AppState extends ChangeNotifier {
  AppState();

  NijiData? data;
  bool loading = true;
  String? error;

  final Set<String> selectedGames = {};
  final Set<String> selectedTags = {};
  final Map<String, String> bindings = {};
  RangeFilter range = RangeFilter.month;
  String search = '';
  bool remindersOn = false;
  bool calendarView = false;
  /// 是否显示「截止」类事件（活动结束 / 卡池结束 / 兑换码截止 / 补偿截止）
  bool showDeadlineEvents = false;
  int scheduledCount = 0;
  final List<String> corrections = [];

  /// App 内手动刷新抓回来的事件（存在本机，覆盖同 URL 的内置事件）
  List<GameEvent> liveEvents = [];
  DateTime? liveFetchedAt;

  Future<void> restore() async {
    bindings
      ..clear()
      ..addAll(await Prefs.loadBindings());
    remindersOn = await Prefs.loadRemindersEnabled();
    calendarView = await Prefs.loadCalendarView();
    showDeadlineEvents = await Prefs.loadShowDeadlineEvents();
    gameAccents
      ..clear()
      ..addAll(await Prefs.loadGameAccents());
    try {
      final loaded = (await Prefs.loadLiveEvents()).map(GameEvent.fromJson).toList();
      // 2.0.0 移除了官网采集通道，旧版本本机缓存的官网事件要清掉，否则会继续显示
      final cleaned = loaded.where((e) => !(e.sourceName ?? '').contains('官网公告')).toList();
      if (cleaned.length != loaded.length) {
        await Prefs.saveLiveEvents(cleaned.map((e) => e.toJson()).toList());
      }
      liveEvents = cleaned;
      liveFetchedAt = await Prefs.loadLiveFetchedAt();
    } catch (_) {
      liveEvents = [];
    }
    notifyListeners();
  }

  /// 内置数据 + 刷新结果的合并视图（同源 URL 以刷新结果为准）
  List<GameEvent> get allEvents {
    final bundled = data?.events ?? const <GameEvent>[];
    final List<GameEvent> merged;
    if (liveEvents.isEmpty) {
      merged = bundled;
    } else {
      final liveUrls = liveEvents.map((e) => e.sourceUrl).whereType<String>().toSet();
      merged = [
        ...liveEvents,
        ...bundled.where((e) => !liveUrls.contains(e.sourceUrl)),
      ];
    }
    // 游戏被移除后，它的日程也不再显示
    final known = gameMap;
    return merged.where((e) => known.containsKey(e.gameId)).toList();
  }

  /// 写入刷新结果；返回这次检测到的改期（没有就是空列表）。
  /// [onlyGame] 非空时只替换该游戏的事件，其它游戏保持原样。
  Future<List<EventChange>> applyLive(List<GameEvent> events, {String? onlyGame}) async {
    final now = DateTime.now();
    final base = onlyGame == null
        ? liveEvents
        : liveEvents.where((e) => e.gameId != onlyGame).toList();
    final merged = mergeEvents(base, events, now);
    final freshIds = events.map((e) => e.id).toSet();
    final kept = base.where((e) => !freshIds.contains(e.id));

    liveEvents = [...merged.events, ...kept];
    liveFetchedAt = now;
    await Prefs.saveLiveEvents(liveEvents.map((e) => e.toJson()).toList());
    await Prefs.saveLiveFetchedAt(now);
    notifyListeners();
    return merged.changes;
  }

  Future<void> load() async {
    try {
      data = await NijiData.load();
    } catch (e) {
      error = '$e';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------- 筛选

  DateTime get _wallNow => DateTime.now().toUtc().add(beijingOffset);

  DateTime get endOfToday {
    final w = _wallNow;
    return DateTime.utc(w.year, w.month, w.day + 1).subtract(beijingOffset);
  }

  DateTime get endOfWeek {
    final w = _wallNow;
    // weekday: 周一 = 1 … 周日 = 7；本周结束 = 下周一 00:00
    return DateTime.utc(w.year, w.month, w.day + (8 - w.weekday)).subtract(beijingOffset);
  }

  bool _passes(GameEvent e) {
    if (selectedGames.isNotEmpty && !selectedGames.contains(e.gameId)) return false;
    if (selectedTags.isNotEmpty) {
      // 标签与游戏是两个维度，彼此并行：维度内多选是“或”，维度之间是“与”
      final allowed = selectedTags.expand((t) => kTagGroups[t] ?? const <String>[]).toSet();
      if (!allowed.contains(e.type)) return false;
    }
    final due = e.due;
    final h = hoursUntil(due);
    return switch (range) {
      RangeFilter.today => !due.isBefore(DateTime.now()) && due.isBefore(endOfToday),
      RangeFilter.week => !due.isBefore(DateTime.now()) && due.isBefore(endOfWeek),
      RangeFilter.month => h >= 0 && h <= 24 * 30,
      RangeFilter.all => true,
    };
  }

  /// 是否是「截止」类事件：类型以结束/截止结尾，或标题以（截止）收尾
  static bool isDeadlineEvent(GameEvent e) =>
      e.title.endsWith('（截止）') ||
      const {'活动结束', '卡池结束', '兑换码截止', '补偿领取截止'}.contains(e.type);

  List<GameEvent> visibleEvents() {
    final list = allEvents
        .where(_passes)
        .where((e) => showDeadlineEvents || !isDeadlineEvent(e))
        .toList();
    list.sort((a, b) => a.due.compareTo(b.due));
    return list;
  }

  List<GameEvent> eventsOf(String gameId) {
    final list = [
      ...allEvents.where((e) => e.gameId == gameId),
    ]..sort((a, b) => a.due.compareTo(b.due));
    return list;
  }

  /// 用户自己加的游戏（存在本机）
  final List<Game> customGames = [];

  /// 被用户从游戏库移除的内置游戏
  final Set<String> hiddenGames = {};

  /// 游戏库的全集：内置（去掉被移除的）+ 自定义
  List<Game> get allGames => [
        ...?data?.games.where((g) => !hiddenGames.contains(g.id)),
        ...customGames,
      ];

  Map<String, Game> get gameMap => {for (final g in allGames) g.id: g};

  Future<void> loadGames() async {
    customGames
      ..clear()
      ..addAll(await Prefs.loadCustomGames());
    hiddenGames
      ..clear()
      ..addAll(await Prefs.loadHiddenGames());
    notifyListeners();
  }

  /// 新增一款游戏；返回新游戏的 id
  String addGame({required String name, String? short, required int accent, String? uid}) {
    final id = 'custom-${DateTime.now().millisecondsSinceEpoch}';
    customGames.add(Game(
      id: id,
      name: name.trim(),
      short: (short == null || short.trim().isEmpty) ? name.trim() : short.trim(),
      accent: Color(accent),
    ));
    if (uid != null && uid.trim().isNotEmpty) bindings[id] = uid.trim();
    Prefs.saveCustomGames(customGames);
    Prefs.saveBindings(bindings);
    notifyListeners();
    return id;
  }

  void restoreGame(String id) {
    hiddenGames.remove(id);
    Prefs.saveHiddenGames(hiddenGames);
    notifyListeners();
  }
  /// 移除一款游戏：自定义的直接删，内置的只是隐藏
  void removeGame(String id) {
    final isCustom = customGames.any((g) => g.id == id);
    if (isCustom) {
      customGames.removeWhere((g) => g.id == id);
      Prefs.saveCustomGames(customGames);
    } else {
      hiddenGames.add(id);
      Prefs.saveHiddenGames(hiddenGames);
    }
    bindings.remove(id);
    Prefs.saveBindings(bindings);
    notifyListeners();
  }
  List<Game> get games => allGames;

  int countWithin(double hours) {
    final events = allEvents;
    return events.where((e) {
      final h = hoursUntil(e.due);
      return h >= 0 && h <= hours;
    }).length;
  }

  int get totalEvents => allEvents.length;

  // ---------------------------------------------------------------- 操作

  void setRange(RangeFilter value) {
    range = value;
    notifyListeners();
  }

  void toggleGame(String id) {
    selectedGames.contains(id) ? selectedGames.remove(id) : selectedGames.add(id);
    notifyListeners();
  }

  void toggleTag(String tag) {
    selectedTags.contains(tag) ? selectedTags.remove(tag) : selectedTags.add(tag);
    notifyListeners();
  }

  void clearFilters() {
    selectedGames.clear();
    selectedTags.clear();
    notifyListeners();
  }

  void clearGames() {
    selectedGames.clear();
    notifyListeners();
  }

  void clearTags() {
    selectedTags.clear();
    notifyListeners();
  }

  void setSearch(String value) {
    search = value;
    notifyListeners();
  }

  /// 每款游戏的标识色可以被用户改，存在本机
  final Map<String, int> gameAccents = {};

  Future<void> loadGameAccents() async {
    gameAccents
      ..clear()
      ..addAll(await Prefs.loadGameAccents());
    notifyListeners();
  }

  Color gameAccentOf(Game game) {
    final override = gameAccents[game.id];
    return override == null ? game.accent : Color(override);
  }

  void setGameAccent(String gameId, int color) {
    gameAccents[gameId] = color;
    Prefs.saveGameAccents(gameAccents);
    notifyListeners();
  }
  void bind(String gameId, String uid) {
    bindings[gameId] = uid;
    Prefs.saveBindings(bindings);
    notifyListeners();
  }

  void unbind(String gameId) {
    bindings.remove(gameId);
    Prefs.saveBindings(bindings);
    notifyListeners();
  }

  void setCalendarView(bool value) {
    calendarView = value;
    Prefs.saveCalendarView(value);
    notifyListeners();
  }

  void setShowDeadlineEvents(bool value) {
    showDeadlineEvents = value;
    Prefs.saveShowDeadlineEvents(value);
    notifyListeners();
  }
  void setReminders(bool value) {
    remindersOn = value;
    Prefs.saveRemindersEnabled(value);
    notifyListeners();
  }

  /// 需要提醒的事件：只看已绑定的游戏；一个都没绑就全部提醒
  List<GameEvent> get reminderScope {
    final events = allEvents
        .where((e) => showDeadlineEvents || !isDeadlineEvent(e))
        .toList();
    if (bindings.isEmpty) return events;
    return events.where((e) => bindings.containsKey(e.gameId)).toList();
  }

  int get boundCount => bindings.length;

  /// 把当前绑定导出成 `{"zzz": "123456", ...}`，方便交给数据端采集
  String bindingsJson() {
    final map = {for (final e in bindings.entries) e.key: e.value};
    final body = map.entries.map((e) => '  "${e.key}": "${e.value}"').join(',\n');
    return map.isEmpty ? '{}' : '{\n$body\n}';
  }

  void addCorrection(String eventId, String text) {
    if (text.isEmpty) return;
    corrections.add('$eventId｜$text');
    notifyListeners();
  }
}
