import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_state.dart';
import 'screens/calendar_screen.dart';
import 'screens/library_screen.dart';
import 'screens/bili_pages.dart';
import 'screens/subscribe_screen.dart';
import 'services/avatar_store.dart';
import 'services/reminder_service.dart';
import 'sheets.dart';
import 'theme.dart';
import 'theme_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NijiCalApp());
}

class NijiCalApp extends StatefulWidget {
  const NijiCalApp({super.key});

  @override
  State<NijiCalApp> createState() => _NijiCalAppState();
}

class _NijiCalAppState extends State<NijiCalApp> {
  final state = AppState();
  final themeController = ThemeController();

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    state.dispose();
    themeController.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    // 插件在测试 / 桌面环境可能不可用，降级为“没有提醒”而不是崩掉
    try {
      await ReminderService.init();
    } catch (_) {}
    try {
      await themeController.restore();
      await state.restore();
      await AvatarStore.load();
    } catch (_) {}
    await state.load();
    try {
      await _reschedule();
    } catch (_) {}
  }

  Future<void> _reschedule() async {
    if (state.data == null) return;
    if (!state.remindersOn && state.bindings.isEmpty) return;
    state.scheduledCount = await ReminderService.schedule(state.reminderScope, state.data!.alarms);
  }

  Future<void> _enableReminders(BuildContext context) async {
    final ok = await ReminderService.requestPermission();
    if (!context.mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没拿到通知权限，需要在系统设置里允许通知')),
      );
      return;
    }
    state.setReminders(true);
    await _reschedule();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已排上 ${state.scheduledCount} 条本地提醒')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: themeController,
      builder: (context, _) => MaterialApp(
        title: 'NijiCal',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(accentId: themeController.accentId),
        home: RootShell(
          state: state,
          themeController: themeController,
          onEnableReminders: _enableReminders,
          onReschedule: _reschedule,
        ),
      ),
    );
  }
}

class RootShell extends StatelessWidget {
  const RootShell({
    super.key,
    required this.state,
    required this.themeController,
    required this.onEnableReminders,
    required this.onReschedule,
  });

  final AppState state;
  final ThemeController themeController;
  final Future<void> Function(BuildContext context) onEnableReminders;
  final Future<void> Function() onReschedule;

  static const _titles = ['日历', '游戏库', '订阅'];

  @override
  Widget build(BuildContext context) {
    // 数据加载完成 / 筛选变化都要重绘外壳；主题色由更外层的 ListenableBuilder 负责
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => _ShellBody(
        state: state,
        themeController: themeController,
        onEnableReminders: onEnableReminders,
        onReschedule: onReschedule,
        titles: _titles,
      ),
    );
  }
}

class _ShellBody extends StatefulWidget {
  const _ShellBody({
    required this.state,
    required this.themeController,
    required this.onEnableReminders,
    required this.onReschedule,
    required this.titles,
  });

  final AppState state;
  final ThemeController themeController;
  final Future<void> Function(BuildContext context) onEnableReminders;
  final Future<void> Function() onReschedule;
  final List<String> titles;

  @override
  State<_ShellBody> createState() => _ShellBodyState();
}

class _ShellBodyState extends State<_ShellBody> {
  int tab = 0;

  @override
  Widget build(BuildContext context) {
    if (widget.state.loading) {
      return Scaffold(body: Center(child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary)));
    }
    if (widget.state.error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('NijiCal')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline_rounded, size: 40),
                const SizedBox(height: 16),
                const Text('数据加载失败'),
                const SizedBox(height: 8),
                Text('${widget.state.error}', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.titles[tab]),
        actions: [
          if (tab == 0)
            IconButton(
              tooltip: '从 B 站刷新',
              onPressed: () async {
                if (widget.state.bindings.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('先去游戏库绑定官号 UID')),
                  );
                  return;
                }
                final changed = await showDialog<bool>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => BiliRefreshDialog(state: widget.state),
                );
                if (!context.mounted) return;
                if (changed == true) {
                  await widget.onReschedule();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('已更新 ${widget.state.liveEvents.length} 条事件')),
                  );
                }
              },
              icon: const Icon(Icons.refresh),
            ),
          if (tab == 0)
            IconButton(
              tooltip: widget.state.calendarView ? '切换为列表' : '切换为日历',
              onPressed: () => widget.state.setCalendarView(!widget.state.calendarView),
              icon: Icon(widget.state.calendarView ? Icons.view_list_outlined : Icons.calendar_month_outlined),
            ),
          if (tab == 0)
            IconButton(
              tooltip: '筛选',
              onPressed: () => showFilterSheet(context, widget.state),
              icon: const Icon(Icons.tune),
            ),
          if (tab == 1)
            IconButton(
              tooltip: '复制绑定配置',
              onPressed: () async {
                final json = widget.state.bindingsJson();
                if (widget.state.bindings.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('还没绑定官号')),
                  );
                  return;
                }
                await Clipboard.setData(ClipboardData(text: json));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('绑定配置已复制，可以交给数据端采集')),
                );
              },
              icon: const Icon(Icons.copy_all_outlined),
            ),
          if (tab == 2)
            IconButton(
              tooltip: '外观',
              onPressed: () => showAppearanceSheet(context, widget.themeController),
              icon: const Icon(Icons.palette_outlined),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: IndexedStack(
        index: tab,
        children: [
          CalendarScreen(state: widget.state),
          LibraryScreen(state: widget.state),
          SubscribeScreen(
            state: widget.state,
            onEnableReminders: () => widget.onEnableReminders(context),
            onReschedule: widget.onReschedule,
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.calendar_month_outlined), selectedIcon: Icon(Icons.calendar_month), label: '日历'),
          NavigationDestination(icon: Icon(Icons.grid_view_outlined), selectedIcon: Icon(Icons.grid_view), label: '游戏库'),
          NavigationDestination(icon: Icon(Icons.notifications_none), selectedIcon: Icon(Icons.notifications_active), label: '订阅'),
        ],
      ),
    );
  }
}
