import 'package:flutter/foundation.dart';

import 'format.dart';
import 'model.dart';
import 'services/prefs.dart';

enum RangeFilter {
  today('今天'),
  week('本周'),
  month('30 天'),
  all('全部');

  const RangeFilter(this.label);
  final String label;
}

/// 全局状态：数据 + 筛选 + 官号绑定。MVP 阶段全部在内存里，不落盘。
class AppState extends ChangeNotifier {
  AppState();

  NijiData? data;
  bool loading = true;
  String? error;

  final Set<String> selectedGames = {};
  final Set<String> selectedTypes = {};
  final Map<String, String> bindings = {};
  RangeFilter range = RangeFilter.month;
  String search = '';
  bool remindersOn = false;
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
    try {
      liveEvents = (await Prefs.loadLiveEvents()).map(GameEvent.fromJson).toList();
      liveFetchedAt = await Prefs.loadLiveFetchedAt();
    } catch (_) {
      liveEvents = [];
    }
    notifyListeners();
  }

  /// 内置数据 + 刷新结果的合并视图（同源 URL 以刷新结果为准）
  List<GameEvent> get allEvents {
    final bundled = data?.events ?? const <GameEvent>[];
    if (liveEvents.isEmpty) return bundled;
    final liveUrls = liveEvents.map((e) => e.sourceUrl).whereType<String>().toSet();
    return [
      ...liveEvents,
      ...bundled.where((e) => !liveUrls.contains(e.sourceUrl)),
    ];
  }

  Future<void> applyLive(List<GameEvent> events) async {
    liveEvents = [...events];
    liveFetchedAt = DateTime.now();
    await Prefs.saveLiveEvents(events.map((e) => e.toJson()).toList());
    await Prefs.saveLiveFetchedAt(liveFetchedAt!);
    notifyListeners();
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
    if (selectedTypes.isNotEmpty && !selectedTypes.contains(e.type)) return false;
    final due = e.due;
    final h = hoursUntil(due);
    return switch (range) {
      RangeFilter.today => !due.isBefore(DateTime.now()) && due.isBefore(endOfToday),
      RangeFilter.week => !due.isBefore(DateTime.now()) && due.isBefore(endOfWeek),
      RangeFilter.month => h >= 0 && h <= 24 * 30,
      RangeFilter.all => true,
    };
  }

  List<GameEvent> visibleEvents() {
    final list = allEvents.where(_passes).toList();
    list.sort((a, b) => a.due.compareTo(b.due));
    return list;
  }

  List<GameEvent> eventsOf(String gameId) {
    final list = [
      ...allEvents.where((e) => e.gameId == gameId),
    ]..sort((a, b) => a.due.compareTo(b.due));
    return list;
  }

  List<Game> get games {
    final all = data?.games ?? const <Game>[];
    if (search.trim().isEmpty) return all;
    final q = search.trim().toLowerCase();
    return all.where((g) => g.name.toLowerCase().contains(q) || g.short.toLowerCase().contains(q)).toList();
  }

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

  void toggleType(String t) {
    selectedTypes.contains(t) ? selectedTypes.remove(t) : selectedTypes.add(t);
    notifyListeners();
  }

  void clearFilters() {
    selectedGames.clear();
    selectedTypes.clear();
    notifyListeners();
  }

  void clearGames() {
    selectedGames.clear();
    notifyListeners();
  }

  void clearTypes() {
    selectedTypes.clear();
    notifyListeners();
  }

  void setSearch(String value) {
    search = value;
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

  void setReminders(bool value) {
    remindersOn = value;
    Prefs.saveRemindersEnabled(value);
    notifyListeners();
  }

  /// 需要提醒的事件：只看已绑定的游戏；一个都没绑就全部提醒
  List<GameEvent> get reminderScope {
    final events = allEvents;
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
