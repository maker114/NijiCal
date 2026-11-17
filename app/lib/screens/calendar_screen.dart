import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import '../model.dart';
import '../sheets.dart';
import '../theme.dart';
import '../widgets.dart';
import '../widgets/day_ring.dart';

/// 主界面：默认是可滚动的列表，右上角可切成日历。
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key, required this.state});

  final AppState state;

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  String? _picked;

  String get _selected => _picked ?? todayKey();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final events = widget.state.visibleEvents();
        final games = widget.state.gameMap;
        return widget.state.calendarView
            ? _buildCalendar(context, events, games)
            : _buildList(context, events, games);
      },
    );
  }

  // ---------------------------------------------------------------- 列表

  Widget _buildList(BuildContext context, List<GameEvent> events, Map<String, Game> games) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final upcoming = events.where((e) => !e.due.isBefore(now)).toList()
      ..sort((a, b) => a.due.compareTo(b.due));
    final expired = widget.state.expiredEvents()
      ..sort((a, b) => b.due.compareTo(a.due));

    if (events.isEmpty) {
      final hiddenDeadlines = widget.state.allEvents.where(AppState.isDeadlineEvent).length;
      return ListView(
        children: [
          const SizedBox(height: 80),
          EmptyState(
            title: hiddenDeadlines > 0 ? '截止类事件已隐藏' : '还没有日程',
            body: hiddenDeadlines > 0
                ? '当前有 $hiddenDeadlines 条「（截止）」条目被开关隐藏，可在订阅页打开。'
                : '绑定官号后，在订阅页从 B 站刷新一次，事件会落到这里。',
            icon: hiddenDeadlines > 0 ? Icons.visibility_off_outlined : Icons.event_note_outlined,
          ),
        ],
      );
    }

    final children = <Widget>[];
    String? lastDay;
    for (final event in upcoming) {
      final day = dayPartOf(event.due);
      if (day != lastDay) {
        children.add(_DayHeader(day: day));
        lastDay = day;
      }
      children.add(_EventTile(event: event, game: games[event.gameId], state: widget.state));
    }

    if (expired.isNotEmpty) children.add(_ExpiredSection(events: expired, games: games, state: widget.state));

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            upcoming.isEmpty ? '没有即将到来的日程' : '接下来 ${upcoming.length} 条',
            style: theme.textTheme.labelSmall,
          ),
        ),
        ...children,
      ],
    );
  }

  // ---------------------------------------------------------------- 日历

  Widget _buildCalendar(BuildContext context, List<GameEvent> events, Map<String, Game> games) {
    final theme = Theme.of(context);
    final calendarList = widget.state.calendarEvents();
    final marks = marksByDate(calendarList, games, widget.state);
    final dayEvents = eventsOn(_selected, calendarList);

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
            _EventTile(event: event, game: games[event.gameId], state: widget.state),
      ],
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.day});

  final String day;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isToday = day == todayKey();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Row(
        children: [
          Text(
            '${monthDayLabel(day)} · ${weekdayLabelOf(day)}',
            style: theme.textTheme.labelLarge?.copyWith(
              color: isToday ? theme.colorScheme.primary : null,
            ),
          ),
          if (isToday) ...[
            const SizedBox(width: 6),
            Text('今天', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary)),
          ],
        ],
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event, required this.game, required this.state});

  final GameEvent event;
  final Game? game;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        EventRow(
          event: event,
          game: game,
          accent: game == null ? null : state.gameAccentOf(game!),

          onTap: () => showDetailSheet(context, state, event),
        ),
        const Divider(height: 1, indent: 16, endIndent: 16),
      ],
    );
  }
}

/// 已过期条目默认折叠，避免把“接下来”冲掉
class _ExpiredSection extends StatefulWidget {
  const _ExpiredSection({required this.events, required this.games, required this.state});

  final List<GameEvent> events;
  final Map<String, Game> games;
  final AppState state;

  @override
  State<_ExpiredSection> createState() => _ExpiredSectionState();
}

class _ExpiredSectionState extends State<_ExpiredSection> {
  bool open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        InkWell(
          onTap: () => setState(() => open = !open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Text('已过期 ${widget.events.length} 条', style: theme.textTheme.labelLarge),
                const Spacer(),
                Icon(open ? Icons.expand_less : Icons.expand_more, size: 20),
              ],
            ),
          ),
        ),
        if (open)
          for (final event in widget.events)
            _EventTile(
              event: event,
              game: widget.games[event.gameId],
              state: widget.state,
            ),
      ],
    );
  }
}

// ---------------------------------------------------------------- 月份网格

Map<String, List<Color>> marksByDate(
  List<GameEvent> events,
  Map<String, Game> games,
  AppState state,
) {
  final marks = <String, List<Color>>{};
  for (final event in events) {
    final day = dayPartOf(event.due);
    final game = games[event.gameId];
    final base = game == null ? const Color(0xFF8A8A8A) : state.gameAccentOf(game);
    // 已过期的事件用低饱和度的同一支色，日历上仍能看出「那天有过什么」
    // 过期事件统一用一个灰，不再按游戏着色，避免和未来事件抢注意力
    final color = _isPast(event) ? const Color(0xFFC9C9C9) : base;
    marks.putIfAbsent(day, () => <Color>[]).add(color);
    if (marks[day]!.length > 3) {
      marks[day] = marks[day]!.take(3).toList();
    }
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
          IconButton(tooltip: '上个月', icon: const Icon(Icons.chevron_left), onPressed: onPrevious),
          Expanded(
            child: Text(
              '${month.year} 年 ${month.month} 月',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          TextButton(onPressed: onToday, child: const Text('今天')),
          IconButton(tooltip: '下个月', icon: const Icon(Icons.chevron_right), onPressed: onNext),
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
/// 事件是否已经过去（只用来决定日历上的颜色）
bool _isPast(GameEvent event) => event.due.isBefore(DateTime.now());