import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nijical/app_state.dart';
import 'package:nijical/format.dart';
import 'package:nijical/main.dart';
import 'package:nijical/model.dart';
import 'package:nijical/services/update_service.dart';
import 'package:nijical/services/event_diff.dart';
import 'package:nijical/services/llm_normalizer.dart';
import 'package:nijical/services/reminder_service.dart';
import 'package:nijical/services/uid.dart';
import 'package:nijical/version.dart';
import 'package:shared_preferences/shared_preferences.dart';

GameEvent _ev({
  String id = 'e1',
  String title = '活动结束',
  DateTime? start,
  DateTime? end,
  List<Revision> revisions = const [],
  EventStatus status = EventStatus.confirmed,
  String? hash,
  String gameId = 'arknights',
}) =>
    GameEvent(
      id: id,
      gameId: gameId,
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

    // 等首帧加载完：CI 冷启动比本地慢，不能用固定延时（会停在骨架屏）
    final empty = find.text('还没有日程');
    for (var i = 0; i < 100 && empty.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
    }

    if (empty.evaluate().isEmpty) {
      // 失败时把当前界面上的文字打出来，便于定位卡在哪个状态
      final texts = find.byType(Text).evaluate()
          .map((e) => (e.widget as Text).data)
          .whereType<String>()
          .toList();
      fail('等待加载超时，当前文字：$texts');
    }

    // 主界面默认是列表：没有事件时给空态提示，底部导航仍在
    expect(empty, findsOneWidget);
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

  group('版本/前瞻预测', () {
    AppState stateWith(List<GameEvent> events, {PredictionSetting? setting}) {
      final state = AppState();
      state.loading = false;
      state.data = NijiData(
        dataMode: 'live',
        sampleNotice: '',
        builtAt: '2026-11-17T00:00:00',
        typeOrder: const ['版本更新'],
        alarms: const {},
        games: const [
          Game(id: 'zzz', name: '绝区零', short: '绝区零', accent: Color(0xFFB58F6E)),
        ],
        events: events,
      );
      state.setPrediction('zzz', setting ?? const PredictionSetting(version: true, preview: true));
      return state;
    }

    test('按上次版本更新 + 周期推算下一次版本与其前瞻', () {
      final last = DateTime.now().subtract(const Duration(days: 10));
      final state = stateWith([
        _ev(id: 'v1', title: '3.3 版本更新', start: last, status: EventStatus.confirmed, gameId: 'zzz'),
      ]);

      final predicted = state.predictedEvents();
      expect(predicted, hasLength(2));

      final update = predicted.firstWhere((e) => e.type == '版本更新');
      expect(update.predicted, isTrue);
      expect(
        update.due.difference(last).inDays,
        42,
        reason: '默认版本周期 42 天',
      );

      final preview = predicted.firstWhere((e) => e.type == '前瞻直播');
      expect(update.due.difference(preview.due).inDays, 7, reason: '默认提前 7 天');
      expect(preview.tags, contains('预测'));
    });

    test('预测不会和已有真实版本更新撞在同一天', () {
      final last = DateTime.now().subtract(const Duration(days: 12));
      final next = last.add(const Duration(days: 42));
      final state = stateWith([
        _ev(id: 'v1', title: '3.3 版本更新', start: last, status: EventStatus.confirmed, gameId: 'zzz'),
        _ev(id: 'v2', title: '3.4 版本更新', start: next, status: EventStatus.confirmed, gameId: 'zzz'),
      ]);

      // 基准已经落到真实的 3.4 上，预测指向再下一个版本；不得与任何真实日期重合
      final predicted = state.predictedEvents();
      for (final p in predicted) {
        expect(p.due.difference(last).inDays.abs() <= 2, isFalse);
        expect(p.due.difference(next).inDays.abs() <= 2, isFalse);
      }
    });

    test('没有版本记录时不算出预测，并给出空基准', () {
      final state = stateWith(const []);
      expect(state.predictionBaseOf('zzz'), isNull);
      expect(state.predictedEvents(), isEmpty);
    });

    test('基准可以回退到标题含「版本」的更新事件', () {
      final last = DateTime.now().subtract(const Duration(days: 5));
      final state = stateWith([
        _ev(id: 'x', title: '全新版本「致电」更新', start: last, status: EventStatus.confirmed, gameId: 'zzz'),
      ]);
      expect(state.predictionBaseOf('zzz'), isNotNull);
      expect(state.predictedEvents(), isNotEmpty);
    });

    test('预测事件不进入提醒范围', () {
      final last = DateTime.now().subtract(const Duration(days: 10));
      final state = stateWith([
        _ev(id: 'v1', title: '3.3 版本更新', start: last, status: EventStatus.confirmed, gameId: 'zzz'),
      ]);
      expect(state.reminderScope.where((e) => e.predicted), isEmpty);
    });
  });
  group('更新检查', () {
    test('解析仓库清单', () {
      final info = UpdateInfo.fromJson({
        'version': '2.15.0',
        'versionCode': 69,
        'apkUrl': 'https://example.com/a.apk',
        'notes': '修复若干问题',
      });
      expect(info.version, '2.15.0');
      expect(info.versionCode, 69);
      expect(info.usable, isTrue);
    });

    test('清单缺字段时判为不可用', () {
      final info = UpdateInfo.fromJson({'version': '', 'versionCode': 0});
      expect(info.usable, isFalse);
    });

    test('版本号比较：只有更大才算有更新', () {
      const current = 68;
      expect(const UpdateInfo(version: '', versionCode: 68, apkUrl: '', notes: '').versionCode > current, isFalse);
      expect(const UpdateInfo(version: '', versionCode: 69, apkUrl: '', notes: '').versionCode > current, isTrue);
      expect(const UpdateInfo(version: '', versionCode: 67, apkUrl: '', notes: '').versionCode > current, isFalse);
    });
  });
  group('更新说明拆分', () {
    test('按行拆开并去掉项目符号', () {
      expect(
        splitUpdateNotes('- 修复 A\n- 修复 B\n* 新增 C\n• 优化 D'),
        ['修复 A', '修复 B', '新增 C', '优化 D'],
      );
    });

    test('空行与首尾空白忽略', () {
      expect(splitUpdateNotes('\n\n   \n- 只有一条  \n\n'), ['只有一条']);
    });

    test('单行过长且含分号时再拆成多条', () {
      final items = splitUpdateNotes(
        '- 第一件需要详细说明的事情，涉及若干处修改与回归验证；第二件同样需要说明的事情，也涉及多处改动',
      );
      expect(items, hasLength(2));
      expect(items.first.startsWith('第一件'), isTrue);
    });

    test('较短的句子即使含分号也不拆', () {
      expect(splitUpdateNotes('修复：A；B'), ['修复：A；B']);
    });

    test('空说明得到空列表', () {
      expect(splitUpdateNotes('   \n  '), isEmpty);
    });
  });
  group('提醒通知 id', () {
    test('同一事件的两个提前量不会撞车', () {
      final a = ReminderService.notificationIdFor('b123-end', -1440);
      final b = ReminderService.notificationIdFor('b123-end', -60);
      expect(a, isNot(b));
    });

    test('开始/结束兄弟事件不会撞车', () {
      final start = ReminderService.notificationIdFor('b123-start', -60);
      final end = ReminderService.notificationIdFor('b123-end', -60);
      expect(start, isNot(end));
    });

    test('同样的输入始终得到同样的 id（重排提醒可覆盖旧的）', () {
      expect(
        ReminderService.notificationIdFor('manual-1763000000000', -1440),
        ReminderService.notificationIdFor('manual-1763000000000', -1440),
      );
    });

    test('id 落在 Android 可接受的正整数范围', () {
      for (final id in ['b1', 'manual-1', '很长的中文-id-#@!']) {
        for (final minutes in [-1440, -60, 0, 30]) {
          final v = ReminderService.notificationIdFor(id, minutes);
          expect(v, inInclusiveRange(0, 0x7FFFFFFF));
        }
      }
    });
  });

  group('大模型失败重试判定', () {
    test('超时与网络错误算可重试', () {
      expect(LlmOutcome.isRetryableMessage('TimeoutException after 0:00:25'), isTrue);
      expect(LlmOutcome.isRetryableMessage('SocketException: Connection reset'), isTrue);
      expect(LlmOutcome.isRetryableMessage('HTTP 503: busy'), isTrue);
      expect(LlmOutcome.isRetryableMessage('HTTP 429: rate limited'), isTrue);
    });

    test('鉴权与内容错误不重试', () {
      expect(LlmOutcome.isRetryableMessage('HTTP 401: unauthorized'), isFalse);
      expect(LlmOutcome.isRetryableMessage('模型返回的不是 JSON'), isFalse);
      expect(LlmOutcome.isRetryableMessage('正文过短'), isFalse);
    });
  });

  group('刷新失败游戏的旧事件要保留', () {
    test('全量刷新时，失败游戏的事件不丢', () async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      state.data = NijiData(
        dataMode: 'live',
        sampleNotice: '',
        builtAt: '2026-11-20T00:00:00',
        typeOrder: const ['版本更新'],
        alarms: const {},
        games: const [
          Game(id: 'zzz', name: '绝区零', short: '绝区零', accent: Color(0xFFB58F6E)),
          Game(id: 'arknights', name: '明日方舟', short: '方舟', accent: Color(0xFF7FA38F)),
        ],
        events: const [],
      );
      final now = DateTime.now();
      final oldZzz = _ev(id: 'zzz-1', title: '旧日程', start: now, gameId: 'zzz');
      final oldArk = _ev(id: 'ark-1', title: '方舟旧日程', start: now, gameId: 'arknights');
      state.liveEvents = [oldZzz, oldArk];

      // 本轮只抓到绝区零的新事件，arknights 抓取失败
      final fresh = _ev(id: 'zzz-2', title: '新日程', start: now, gameId: 'zzz');
      await state.applyLive([fresh], preserveGameIds: {'arknights'});

      final ids = state.liveEvents.map((e) => e.id).toSet();
      expect(ids.contains('zzz-2'), isTrue);
      expect(ids.contains('ark-1'), isTrue, reason: '失败游戏的旧事件应保留');
      expect(ids.contains('zzz-1'), isFalse, reason: '成功游戏的旧事件应被替换');
    });
  });
  group('版本号只允许一个真相', () {
    test('pubspec.yaml 与 version.dart 的版本/构建号一致', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final line = RegExp(r'^version:\s*(\S+)$', multiLine: true)
          .firstMatch(pubspec)
          ?.group(1);
      expect(line, isNotNull, reason: 'pubspec.yaml 里缺少 version:');
      final parts = line!.split('+');
      expect(parts, hasLength(2), reason: 'version 必须写成 X.Y.Z+N');

      expect(parts[0], kAppVersion, reason: 'pubspec 版本名与 kAppVersion 不一致');
      expect(int.parse(parts[1]), kAppVersionCode, reason: 'pubspec 构建号与 kAppVersionCode 不一致');
    });
  });
  group('标题指纹与去重', () {
    test('同一场前瞻的不同写法指纹相同', () {
      final a = titleFingerprint('2.0 版本揭幕前瞻特别节目');
      final b = titleFingerprint('终末地 2.0 版本前瞻特别节目');
      final c = titleFingerprint('2.0 版本前瞻特别节目');
      expect(a, b);
      expect(b, c);
      expect(a, isNotEmpty);
    });

    test('不同角色的卡池不会被合并', () {
      final a = titleFingerprint('「挽昼」限定寻访开启');
      final b = titleFingerprint('「卡芙卡」限定寻访开启');
      expect(a, isNot(b));
    });

    test('三条同事件的记录会被去重成一条', () {
      final t = DateTime.parse('2026-11-21T19:30:00+08:00');
      final events = [
        _ev(id: 'a', title: '2.0 版本揭幕前瞻特别节目', start: t, gameId: 'endfield'),
        _ev(id: 'b', title: '终末地 2.0 版本前瞻特别节目', start: t, gameId: 'endfield'),
        _ev(id: 'c', title: '2.0 版本前瞻特别节目', start: t, gameId: 'endfield'),
      ];
      expect(dedupeEvents(events), hasLength(1));
    });

    test('时间不同的同标题事件不合并', () {
      final a = _ev(id: 'a', title: '活动开启', start: DateTime.parse('2026-11-21T10:00:00+08:00'));
      final b = _ev(id: 'b', title: '活动开启', start: DateTime.parse('2026-11-21T20:00:00+08:00'));
      expect(dedupeEvents([a, b]), hasLength(2));
    });
  });}
