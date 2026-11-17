import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import '../model.dart';
import '../sheets.dart';
import '../theme.dart';
import '../widgets.dart';
import '../widgets/day_ring.dart';

/// 日历页 —— 直接搬 GuideLine 的 `task_calendar_page.dart`：
/// 月视图 + 日期圆环（一条事件一段弧）+ 点某天在下面列出当天事件。
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key, required this.state});

  final AppState state;

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  late DateTime _month;
  String? _picked;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
  }

  String get _selected => _picked ?? todayKey();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final events = widget.state.visibleEvents();
        final games = widget.state.data!.gamesById;
        final marks = marksByDate(events, games);
        final dayEvents = eventsOn(_selected, events);
        final undated = widget.state.data!.events.where((e) => e.start == null && e.end == null).length;

        return ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: <Widget>[
            _MonthBar(
              month: _month,
              onPrevious: () => setState(() => _month = DateTime(_month.year, _month.month - 1)),
              onNext: () => setState(() => _month = DateTime(_month.year, _month.month + 1)),
              onToday: () => setState(() {
                final now = DateTime.now();
                _month = DateTime(now.year, now.month);
                _picked = todayKey();
              }),
            ),
            const _WeekdayHeader(),
            _MonthGrid(
              month: _month,
              marks: marks,
              selected: _selected,
              onSelect: (date) => setState(() => _picked = date),
            ),
            const SizedBox(height: 8),
            _TagBar(state: widget.state),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '${monthDayLabel(_selected)} · ${weekdayLabelOf(_selected)}'
                      '${dayEvents.isEmpty ? '' : ' · ${dayEvents.length} 条'}',
                      style: theme.textTheme.labelLarge,
                    ),
                  ),
                  if (undated > 0) Text('另有 $undated 条没排期', style: theme.textTheme.labelSmall),
                ],
              ),
            ),
            if (dayEvents.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text('这一天没有事件', style: theme.textTheme.bodySmall),
              )
            else
              for (final event in dayEvents)
                Column(
                  children: <Widget>[
                    EventRow(
                      event: event,
                      game: games[event.gameId],
                      onTap: () => showDetailSheet(context, widget.state, event),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                  ],
                ),
          ],
        );
      },
    );
  }
}

/// 日期 → 这一天各条事件的标记色（**一条事件一段弧**）。
Map<String, List<Color>> marksByDate(List<GameEvent> events, Map<String, Game> games) {
  final marks = <String, List<Color>>{};
  for (final event in events) {
    final day = dayPartOf(event.due);
    if (day.isEmpty) continue;
    marks.putIfAbsent(day, () => <Color>[]).add(games[event.gameId]?.accent ?? const Color(0xFF8A8A8A));
  }
  return marks;
}

/// 某天的事件（按时间排）。
List<GameEvent> eventsOn(String date, List<GameEvent> events) =>
    events.where((e) => dayPartOf(e.due) == date).toList()..sort((a, b) => a.due.compareTo(b.due));

/// 格子 Key（给测试点某一天用）。
@visibleForTesting
Key calendarDayKey(String date) => Key('NijiCal.calendar.$date');

class _MonthBar extends StatelessWidget {
  const _MonthBar({
    required this.month,
    required this.onPrevious,
    required this.onNext,
    required this.onToday,
  });

  final DateTime month;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onToday;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: '上个月',
            icon: const Icon(Icons.chevron_left),
            onPressed: onPrevious,
          ),
          Expanded(
            child: Text(
              '${month.year} 年 ${month.month} 月',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          TextButton(onPressed: onToday, child: const Text('今天')),
          IconButton(
            tooltip: '下个月',
            icon: const Icon(Icons.chevron_right),
            onPressed: onNext,
          ),
        ],
      ),
    );
  }
}

class _WeekdayHeader extends StatelessWidget {
  const _WeekdayHeader();

  static const List<String> _labels = <String>['一', '二', '三', '四', '五', '六', '日'];

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Row(
        children: <Widget>[
          for (final label in _labels)
            Expanded(child: Text(label, textAlign: TextAlign.center, style: style)),
        ],
      ),
    );
  }
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.marks,
    required this.selected,
    required this.onSelect,
  });

  final DateTime month;
  final Map<String, List<Color>> marks;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final first = DateTime(month.year, month.month, 1);
    // 周一 = 0（DateTime.monday == 1）
    final leading = (first.weekday - DateTime.monday) % 7;
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final today = todayKey();

    final cells = <Widget>[
      for (var i = 0; i < leading; i += 1) const SizedBox.shrink(),
      for (var day = 1; day <= daysInMonth; day += 1)
        _DayCell(
          date: dateKeyOf(month.year, month.month, day),
          day: day,
          colors: marks[dateKeyOf(month.year, month.month, day)] ?? const <Color>[],
          selected: dateKeyOf(month.year, month.month, day) == selected,
          isToday: dateKeyOf(month.year, month.month, day) == today,
          onTap: onSelect,
        ),
    ];

    final rows = <Widget>[];
    for (var i = 0; i < cells.length; i += 7) {
      rows.add(
        Row(
          children: <Widget>[
            for (var j = 0; j < 7; j += 1)
              Expanded(child: i + j < cells.length ? cells[i + j] : const SizedBox.shrink()),
          ],
        ),
      );
    }
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Column(children: rows));
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.date,
    required this.day,
    required this.colors,
    required this.selected,
    required this.isToday,
    required this.onTap,
  });

  final String date;
  final int day;
  final List<Color> colors;
  final bool selected;
  final bool isToday;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      key: calendarDayKey(date),
      onTap: () => onTap(date),
      borderRadius: BorderRadius.circular(AppShapes.nestedRadius),
      child: SizedBox(
        height: 46,
        child: Center(
          child: DayRing(
            colors: colors,
            selected: selected,
            child: Text(
              '$day',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: isToday ? theme.colorScheme.primary : null,
                fontWeight: isToday ? FontWeight.w600 : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 日历里的标签筛选条：与游戏筛选并行，可多选
class _TagBar extends StatelessWidget {
  const _TagBar({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          _chip(context, label: '全部', selected: state.selectedTags.isEmpty, onTap: state.clearTags),
          for (final tag in kTagGroups.keys)
            _chip(
              context,
              label: tag,
              selected: state.selectedTags.contains(tag),
              onTap: () => state.toggleTag(tag),
            ),
          if (state.selectedGames.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 12, bottom: 12),
              child: Text('· 已按游戏过滤', style: theme.textTheme.labelSmall),
            ),
        ],
      ),
    );
  }

  Widget _chip(
    BuildContext context, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 8, top: 6, bottom: 6),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: selected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}