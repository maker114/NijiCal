# NijiCal

把二游官方动态里的时间，变成**能订阅、能提醒、能追溯**的日程。

> **一句话**：卡池结束、活动关闭、兑换码过期、补偿领取截止——一个页面看全，到期前提醒你。

**当前版本：2.2.0**（见 [CHANGELOG.md](CHANGELOG.md)）

## 仓库结构

| 目录 | 是什么 | 谁在用 |
| :--- | :--- | :--- |
| [`app/`](app/) | **Flutter 手机客户端**（产品本体）。数据内置、提醒本地、ICS 机内生成 | 玩家 |
| [`mvp/`](mvp/) | 数据端与工具：`data/*.json` 是打包进 App 的种子数据，`tools/build.py` 校验并生成 `app/assets/data.json` | 开发 |
| [`CHANGELOG.md`](CHANGELOG.md) | 版本与改动记录（Keep a Changelog） | — |
| [`DSH通用规范.md`](DSH通用规范.md) | 本仓库的版本 / 提交 / 日志 / 协作规则 | — |

## 数据从哪来

**单一来源：B 站官方号动态。**

```
你在 App 内登录 B 站（cookie 只留在 WebView）
        │
        ▼
← feed/space?host_mid=<你绑定的 UID>     逐账号串行拉取
        │
        ▼
大模型规范化 → {游戏, 版本, 类型, 起止时间, 摘要, 置信度, 标签}
        │   校验不过 / 抽不出时间 → 丢弃，不猜
        ▼
本机事件库（shared_preferences）→ 日历 + 本地提醒 + .ics 导出
```

- 官网新闻抓取通道已于 2.0.0 **移除**（页面结构各异、4 款游戏里 2 款抓不到正文时间）；
- 事件全部由大模型解析产生，`mvp/data/events.json` 只作种子（当前为空）。

## 跑起来

```powershell
# 1. 校验并生成 App 内置数据（事件为空时也能跑）
cd mvp
python tools/build.py

# 2. 构建并装到手机
cd ..\app
flutter build apk --release
adb install -r build\app\outputs\flutter-apk\app-release.apk

# 3. 手机上的三步
#    游戏库 → 绑定 4 个官号 UID
#    订阅 → 配置大模型 key（DeepSeek 或任意 OpenAI 兼容端点）
#    订阅 → 登录 B 站 → 从 B 站刷新
```

## 现在能做什么 / 还不能做什么

✅ 月历 + 圆环标记、选中日事件列表、事件详情（来源/置信度/版本/标签/变更记录）、游戏库绑定、B 站动态刷新、大模型规范化、本地提醒、导出 .ics

❌ 变更 diff 与「改期」推送、审核队列、云端同步、多端

⚠️ 未绑定官号 / 未配大模型 key 时，日历是空的——这是预期状态，不是故障。

## 路线

1. **Phase 0（已完成）**：人工录入 + 官网采集，验证「统一日历 + 截止提醒」成立；
2. **Phase 1（当前）**：B 站单一来源 + 大模型规范化 + 版本/标签；
3. **Phase 2**：事件 diff 与改期推送、低置信审核队列、来源扩展。
