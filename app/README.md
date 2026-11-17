# NijiCal App（Flutter）

手机端独立运行的客户端：**不联网、不依赖服务器**，数据内置、提醒本地、`.ics` 机内生成。

## 运行

```powershell
# 数据来自 mvp 数据端（改了 data/*.json 后要先跑这个）
cd ..\mvp
python tools/build.py

cd ..\app
flutter run -d <设备id>      # 连手机直接跑
flutter build apk --debug    # 或产出可安装的 apk
flutter analyze && flutter test
```

## 离线是怎么做到的

| 能力 | 实现 | 说明 |
| :--- | :--- | :--- |
| 事件数据 | `assets/data.json`（构建时由 `mvp/tools/build.py` 生成并打进包内） | 首次打开即有数据，飞行模式可用 |
| 提醒 | `flutter_local_notifications` + `timezone` | 按事件类型的提前量排本地通知，用 `zonedSchedule` 交给系统闹钟；App 被划掉也能收到 |
| 日历导出 | `share_plus` + `path_provider` | 在机内拼 RFC 5545 文本写到临时目录，再唤起系统分享，用户选“日历”即可导入 |
| 绑定 / 纠错 | `shared_preferences` | 全部存本机，不上传 |

Android 侧为此配置了：`POST_NOTIFICATIONS` / `SCHEDULE_EXACT_ALARM` / `RECEIVE_BOOT_COMPLETED` 权限、
`ScheduledNotificationReceiver` 与开机恢复的 `ScheduledNotificationBootReceiver`、
以及 `coreLibraryDesugaring`（插件要求）。

## 目录

```
lib/
├─ main.dart                  应用外壳：AppBar、三个 tab（日历/游戏库/订阅）
├─ theme.dart                 设计令牌：中性底色系 + 强调色预设 + 形状 + 紧迫度色阶
├─ theme_controller.dart      当前主题色（7 套预设，持久化）
├─ model.dart                 数据模型与 assets 解析
├─ format.dart                北京时间格式化、倒计时分级、日历按天归组
├─ app_state.dart             筛选、绑定、提醒开关（in-memory + prefs）
├─ widgets.dart               Tag / SectionLabel / ChoicePill / EmptyState / EventRow
├─ widgets/day_ring.dart      日历格子外圈的“按事件分段圆弧”
├─ sheets.dart                底部抽屉：筛选、外观、事件详情、纠错、绑定官号
├─ screens/
│  ├─ calendar_screen.dart    月历 + 选中日的事件列表
│  ├─ library_screen.dart     游戏库：搜索、版本、最近事件、绑定
│  ├─ subscribe_screen.dart   订阅：提醒、大模型配置入口、导出、边界说明
│  ├─ bili_pages.dart         B 站登录页 + 刷新对话框
│  └─ llm_settings_page.dart  大模型配置（地址 / 模型 / key / 连通性测试）
└─ services/
   ├─ bili_service.dart       B 站动态读取（WebView 直接请求接口，cookie 不离手机）
   ├─ llm_normalizer.dart     动态 → 规范事件（受白名单约束的 JSON）
   ├─ reminder_service.dart   本地通知排期
   ├─ ics_service.dart        ICS 生成与分享（含版本/标签）
   └─ prefs.dart              本机存储（绑定 / 提醒 / 大模型配置 / 刷新结果）
```

## 设计：照搬 GuideLine

UI 语言来自 [`maker114/Guide-Line`](https://github.com/maker114/Guide-Line) 的 `lib/ui/theme`，不是自己另起一套：

- **底色永远中性灰**：把 Material 3 推出来的 surface 家族统一去色（只保留明度层级），
  换主题只换前景那支强调色 —— 页面底、卡片底、输入框底都不变；
- **7 套强调色预设**：墨黑 `#37474F`（默认，和用户自己在 GuideLine 里选的一致）、默认蓝、松绿、陶土、梅紫、沙金、海松；
- **形状**：能点的用胶囊（按钮/输入框/标签），装东西的用 20 圆角卡片，抽屉只圆上缘 28；
- **不靠阴影浮起**：卡片用 `surfaceContainerLow`，层级靠底色 + 一条 `outlineVariant` 分隔线；
- **紧迫度色阶**：绿 → 黄 → 橙 → 红（`UrgencyColors`，注册在主题里），列表右侧按档位取色；
- **AppBar 不随滚动变色**（`scrolledUnderElevation: 0` + `surfaceTintColor: transparent`）；
- **中文兜底字体链**：只给 `fontFamilyFallback`、不设 `fontFamily`，否则 Windows 上中文会落成宋体。

## 日历：搬自 GuideLine 的 `task_calendar_page.dart`

- 月视图，周一开头，格子 46 高；
- 每天数字外面一圈 **`DayRing`**：一天有一条事件画一段弧，两条各占一半、三条各占三分之一，
  颜色取该游戏的标识色（`DayRingPainter` 用 `drawArc` 从 12 点方向顺时针铺满，段间不留缝）；
- 选中的那天圆里填一层强调色 16% 的淡底，今天用强调色加粗；
- 点某天，分隔线下面列出当天的事件（`EventRow`），点进去是详情抽屉。

## 构建环境备注（踩过的坑，换机器时照抄）

1. **插件版本上限**：`flutter_local_notifications` 固定用 `^22.3.3`。
   23.x 要求 `compileSdk 37`，而当前 AGP 9.1.0 官方最高只到 36，会直接构建失败。
2. **Kotlin 增量缓存**：本机 pub 缓存在 `D:`、工程在 `E:`，Kotlin 增量编译会报
   `this and base files have different roots` 并把构建搞挂。
   已在 `android/gradle.properties` 里设 `kotlin.incremental=false`。
3. **gradle.properties 必须是 UTF-8**：用 PowerShell `Add-Content` 写中文注释会写成
   GBK，Flutter 读配置时直接 crash（`Failed to decode data using encoding 'utf-8'`）。
4. **Gradle 镜像**：`android/settings.gradle.kts` 的 `pluginManagement` 里加了阿里云镜像，
   国内网络下 `gradlePluginPortal` 经常卡住（表现为构建长时间停在
   `Running Gradle task 'assembleDebug'...`）。
5. **Web 预览缺中文字体**：`flutter build web` 的 CanvasKit 运行时才去下 Noto，
   网络受限时中文显示成方框。**这只是 Web 预览的问题，Android 用系统字体正常**。

## 刷新：B 站动态 → 大模型 → 事件

日历右上角 **↻** 或「订阅 → 从 B 站刷新」，流程是：

```
用你绑定的 UID 逐个 request api.bilibili.com/x/polymer/web-dynamic/v1/feed/space
        │  （WebView 直接导航到接口地址，浏览器自动带 cookie，正文就是 JSON）
        ▼
逐条动态 → 大模型 → 受白名单约束的 JSON
        │  {游戏, 版本, 类型, 起止时间, 摘要, 置信度, 标签}
        ▼
结构校验 → 通过则入库（存 shared_preferences），失败则丢弃并计入“非事件/解析失败”
```

三条硬约束：

1. **cookie 不出手机**：登录在 WebView 里完成，App 代码不读、不存、不上传 SESSDATA；
2. **不猜时间**：模型只给相对表达（“版本更新后”）时一律置空；起止都为空的事件不入库；
3. **只读**：只请求 feed/space，不点赞、不转发、不关注。

大模型走 OpenAI 兼容接口，默认 `https://api.deepseek.com` + `deepseek-chat`；
key 存在本机应用私有目录，换机或清数据需重填。
## 已知限制

1. **空日历是正常状态**：没绑官号、没配大模型 key、或还没刷新过，日历就是空的。
2. **登录态约 30 天失效**：过期后刷新会提示“登录已失效”，重新登录即可。
3. **绑定只在本机**：换机/卸载即丢，暂时没有导出。
4. **iOS 未配置**：项目只生成了 `android` / `web` 两个平台；iOS 需要 macOS 环境再 `flutter create --platforms=ios .`。
5. **通知精确度**：使用 `inexactAllowWhileIdle`，系统省电策略下可能有几分钟漂移；需要严格准点（如兑换码前 30 分钟）可改用精确闹钟并引导用户授予权限。
6. **时区固定 +08:00**：海外用户看到的仍是北京时间。

## 下一步

- 事件 diff 与“改期”推送（同一动态被编辑 → 重新排期 + 通知）；
- 低置信事件的审核闸门（现在直接丢弃，改为进队列）；
- iOS 平台配置与通知权限流程；
- 绑定 / 纠错 / 大模型配置的本地导出与迁移。
