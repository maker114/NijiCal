import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nijical/app_state.dart';
import 'package:nijical/format.dart';
import 'package:nijical/main.dart';
import 'package:nijical/model.dart';
import 'package:nijical/services/event_diff.dart';
import 'package:nijical/services/uid.dart';
import 'package:nijical/services/wbi.dart';
import 'package:shared_preferences/shared_preferences.dart';

GameEvent _ev({
  String id = 'e1',
  String title = '活动结束',
  DateTime? start,
  DateTime? end,
  List<Revision> revisions = const [],
  EventStatus status = EventStatus.confirmed,
  String? hash,
}) =>
    GameEvent(
      id: id,
      gameId: 'arknights',
      type: end == null ? '活动开始' : '活动结束',
      title: title,
      start: start,
      end: end,
      status: status,
      confidence: 90,
      sourceHash: hash,
      revisions: revisions,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('北京时间格式化与区间展示', () {
    final due = DateTime.parse('2026-11-17T17:59:00+08:00');
    expect(mdhm(due), '11月17日 17:59');
    expect(eventRange(null, due), '截止 11月17日 17:59');
    expect(
      eventRange(due, due.add(const Duration(hours: 5))),
      '11月17日 17:59 → 11月17日 22:59',
    );
  });

  test('倒计时分级', () {
    final soon = DateTime.now().add(const Duration(hours: 2));
    expect(countdownOf(soon).level, 1);
    final later = DateTime.now().add(const Duration(hours: 40));
    expect(countdownOf(later).level, 3);
    final past = DateTime.now().subtract(const Duration(hours: 1));
    expect(countdownOf(past).text, '已过期');
  });

  test('日历按天归组', () {
    expect(dayPartOf(DateTime.parse('2026-11-17T17:59:00+08:00')), '2026-11-17');
    expect(dayPartOf(DateTime.parse('2026-11-17T23:59:00+08:00')), '2026-11-17');
    expect(monthDayLabel('2026-11-17'), '11 月 17 日');
    expect(weekdayLabelOf('2026-11-17'), '周二');
  });

  group('事件 diff（按原文指纹判定）', () {
    final t1 = DateTime.parse('2026-12-01T23:59:00+08:00');
    final t2 = DateTime.parse('2026-12-03T23:59:00+08:00');
    const h1 = 'aaaa1111';
    const h2 = 'bbbb2222';

    test('原文没变、时间抖动 → 不算改期', () {
      final old = [_ev(end: t1, hash: h1)];
      final fresh = [_ev(end: t2, hash: h1)];
      expect(diffEvents(old, fresh), isEmpty);
    });

    test('原文变了且时间变了 → 记一条改期', () {
      final changes = diffEvents([_ev(end: t1, hash: h1)], [_ev(end: t2, hash: h2)]);
      expect(changes, hasLength(1));
      expect(changes.first.field, '结束时间');
      expect(changes.first.to, contains('12 月 3 日'));
    });

    test('原文变了但时间没变 → 不算改期', () {
      final changes = diffEvents([_ev(end: t1, hash: h1)], [_ev(end: t1, hash: h2)]);
      expect(changes, isEmpty);
    });

    test('新增事件不算变更', () {
      expect(diffEvents([], [_ev(end: t1, hash: h1)]), isEmpty);
    });

    test('历史数据没有指纹 → 不判定改期', () {
      final changes = diffEvents([_ev(end: t1)], [_ev(end: t2, hash: h1)]);
      expect(changes, isEmpty);
    });

    test('合并时原文没变就沿用旧事件，不被模型抖动覆盖', () {
      final old = [_ev(end: t1, hash: h1)];
      final fresh = [_ev(end: t2, hash: h1)];
      final merged = mergeEvents(old, fresh, DateTime.now());
      expect(merged.changes, isEmpty);
      expect(merged.events.single.end, t1);
    });

    test('withChanges 会追加历史并把状态标成已变更', () {
      final changes = diffEvents([_ev(end: t1, hash: h1)], [_ev(end: t2, hash: h2)]);
      final updated = withChanges(_ev(end: t2, hash: h2), changes, DateTime.now());
      expect(updated.status, EventStatus.changed);
      expect(updated.revisions, hasLength(1));
      expect(updated.revisions.first.field, '结束时间');
    });

    test('事件经 JSON 往返后仍是同一时刻，不会被误判成改期', () {
      // 回归：JSON 里是 +08:00，解析成 UTC 瞬时点；曾经在别处又加 8 小时，
      // 导致每次刷新都把全部事件判成“改期”。
      final fresh = _ev(end: DateTime.parse('2026-11-26T11:59:00+08:00'), hash: h1);
      final stored = GameEvent.fromJson(fresh.toJson());
      expect(diffEvents([stored], [fresh]), isEmpty);
      expect(mdhm(stored.end!), '11月26日 11:59');
    });

    test('内容指纹稳定：同一段文本得到同一个值', () {
      expect(contentHash('活动 11 月 20 日截止'), contentHash('活动 11 月 20 日截止'));
      expect(contentHash('活动 11 月 20 日截止'), isNot(contentHash('活动 11 月 21 日截止')));
    });
  });

  testWidgets('启动后能加载内置数据并渲染日历', (tester) async {
    await tester.pumpWidget(const NijiCalApp());
    // 让 assets 读取与插件降级走完真实异步
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 主界面默认是列表：没有事件时给空态提示，底部导航仍在
    expect(find.text('还没有日程'), findsOneWidget);
    expect(find.text('日历'), findsWidgets);
    expect(find.text('游戏库'), findsWidgets);
  });

  test('同一公告被多条动态解析时会去重', () {
    final t = DateTime.parse('2026-11-05T00:00:00+08:00');
    final events = [
      _ev(id: 'a', title: '全新版本「致电，空想迷数」更新', start: t, hash: 'h1'),
      _ev(id: 'b', title: '致电，空想迷数版本更新', start: t, hash: 'h1'),
      _ev(id: 'c', title: '致电空想迷数版本更新', start: t, hash: 'h1'),
      _ev(id: 'd', title: '霜寒环线特别路线结束', end: t, hash: 'h2'),
    ];
    final deduped = dedupeEvents(events);
    expect(deduped, hasLength(2));
    expect(deduped.map((e) => e.id), containsAll(<String>['a', 'd']));
  });
  group('游戏库增删与提醒跟随开关', () {
    AppState readyState() {
      final state = AppState();
      state.loading = false;
      state.data = NijiData(
        dataMode: 'live',
        sampleNotice: '',
        builtAt: '2026-11-17T00:00:00',
        typeOrder: const ['活动开始', '活动结束'],
        alarms: const {},
        games: const [
          Game(id: 'arknights', name: '明日方舟', short: '方舟', accent: Color(0xFF7FA38F)),
          Game(id: 'zzz', name: '绝区零', short: '绝区零', accent: Color(0xFFB58F6E)),
        ],
        events: const [],
      );
      return state;
    }

    test('添加的游戏出现在库里，移除后消失', () {
      final state = readyState();
      expect(state.allGames.length, 2);

      state.addGame(name: '鸣潮', accent: 0xFF123456, uid: '12345');
      expect(state.allGames.length, 3);
      final added = state.allGames.last;
      expect(added.name, '鸣潮');
      expect(state.bindings[added.id], '12345');

      state.removeGame(added.id);
      expect(state.allGames.length, 2);
      expect(state.bindings.containsKey(added.id), isFalse);
    });

    test('移除内置游戏只是隐藏，可以恢复', () {
      final state = readyState();
      final first = state.allGames.first;

      state.removeGame(first.id);
      expect(state.allGames.length, 1);
      expect(state.hiddenGames, contains(first.id));

      state.restoreGame(first.id);
      expect(state.allGames.length, 2);
    });

    test('关掉截止事件后，截止条目不再排提醒', () {
      final state = readyState();
      final t = DateTime.now().add(const Duration(days: 3));
      state.liveEvents = [
        _ev(id: 'b1', end: t, title: '活动结束', status: EventStatus.confirmed),
        _ev(id: 'b2', start: t, title: '活动开启', status: EventStatus.confirmed),
      ];

      state.setShowDeadlineEvents(false);
      expect(state.reminderScope.length, 1);
      expect(state.reminderScope.single.id, 'b2');

      state.setShowDeadlineEvents(true);
      expect(state.reminderScope.length, 2);
    });
  });
  group('UID 归一化', () {
    test('去掉 UID 前缀与冒号', () {
      expect(normalizeUid('UID:123456'), '123456');
      expect(normalizeUid('uid：123456'), '123456');
      expect(normalizeUid('UID : 123456'), '123456');
    });

    test('从空间链接里取数字', () {
      expect(normalizeUid('https://space.bilibili.com/123456?spm=333.999'), '123456');
      expect(normalizeUid('space.bilibili.com/123456/'), '123456');
    });

    test('纯数字与空白照常处理', () {
      expect(normalizeUid('  123456  '), '123456');
      expect(normalizeUid('abc'), 'abc');
    });
  });
  test('拆分出来的开始事件会回填区间', () {
    final t1 = DateTime.parse('2026-11-16T02:00:00+08:00');
    final t2 = DateTime.parse('2026-11-29T19:59:00+08:00');
    final start = _ev(id: 'b1-start', title: '活动开启', start: t1, hash: 'h1');
    final end = _ev(id: 'b1-end', title: '活动结束', end: t2, hash: 'h1');

    final filled = backfillRanges([start, end]);
    expect(filled.first.displayEnd, t2);
    expect(filled.first.start, t1);
  });
  test('MD5 与标准测试向量一致（WBI 签名依赖它）', () {
    expect(Wbi.md5Of(''), 'd41d8cd98f00b204e9800998ecf8427e');
    expect(Wbi.md5Of('abc'), '900150983cd24fb0d6963f7d28e17f72');
    expect(Wbi.md5Of('message digest'), 'f96b697d7cb7938d525a2f31aaf161d0');
  });}
