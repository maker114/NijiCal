/// 自动刷新跑完后的播报档位（弹系统通知）。
///
/// 定时刷新是后台行为：每天两条「刷新完成」只会把通知栏占满，
/// 用户顺手把整个 App 的通知一关，连真正要紧的改期提醒也一起丢了。
/// 所以默认静默，要播报得自己去设置里挑一档。
enum AutoNotifyMode {
  /// 不播报：跑完什么都不弹，结果只留在设置页的「上次结果」里
  silent('不播报', '跑完不弹任何通知，结果只留在本页「上次结果」里'),

  /// 部分播报：日程条目有增删才弹，且只报这两个条数
  partial('部分播报', '日程有新增 / 删除时才弹一条：新增 3 条｜删除 1 条'),

  /// 完整播报：每次都弹完整摘要
  full('完整播报', '每次都弹完整摘要：拉取、新增、删除、改期、未通过都写上');

  const AutoNotifyMode(this.label, this.hint);

  /// 设置页上的档位名
  final String label;

  /// 选中这一档时给一句人话解释
  final String hint;

  /// 存进 SharedPreferences 的整数
  int get code => index;

  /// 读回来的整数一律走这里：越界 / 没存过都按最安静的档位处理
  static AutoNotifyMode fromCode(int? code) =>
      code != null && code >= 0 && code < values.length ? values[code] : silent;
}

/// 一条待播报的标题与正文
class AutoNotice {
  const AutoNotice(this.title, this.body);

  final String title;
  final String body;
}

abstract final class AutoNotify {
  /// 按档位决定这一轮要不要播报、播什么。`null` = 按设置不该弹。
  ///
  /// 纯函数：不读设置、不碰通知插件，方便单测与文案预览。
  static AutoNotice? noticeFor({
    required AutoNotifyMode mode,
    required bool ok,
    required String message,
    required int added,
    required int removed,
    required String source,
  }) {
    switch (mode) {
      case AutoNotifyMode.silent:
        return null;
      case AutoNotifyMode.partial:
        // 只有日程本身增删了才值得打扰；失败、无变化都闭嘴
        if (added <= 0 && removed <= 0) return null;
        return AutoNotice(
          'NijiCal 日程有更新',
          [
            if (added > 0) '新增 $added 条',
            if (removed > 0) '删除 $removed 条',
          ].join('｜'),
        );
      case AutoNotifyMode.full:
        return AutoNotice(
          ok ? 'NijiCal $source完成' : 'NijiCal $source失败',
          message,
        );
    }
  }
}
