import 'package:flutter_test/flutter_test.dart';
import 'package:nijical/format.dart';
import 'package:nijical/main.dart';

void main() {
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

  testWidgets('启动后能加载内置数据并渲染日历', (tester) async {
    await tester.pumpWidget(const NijiCalApp());
    // 让 assets 读取与插件降级走完真实异步
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final now = DateTime.now();
    expect(find.text('${now.year} 年 ${now.month} 月'), findsOneWidget);
    expect(find.text('日历'), findsWidgets);
    expect(find.text('今天'), findsWidgets);
  });
}
