# NijiCal

把二游官方动态里的时间，变成**能订阅、能提醒、能追溯**的日程。

> **一句话**：卡池结束、活动关闭、兑换码过期、补偿领取截止——一个页面看全，到期前提醒你。

**当前版本：2.14.0**（见 [CHANGELOG.md](CHANGELOG.md)）

## 仓库结构

| 目录 | 是什么 |
| :--- | :--- |
| [`app/`](app/) | **Flutter 手机客户端**（产品本体）：数据本机、提醒本地、ICS 机内生成 |
| [`mvp/`](mvp/) | 数据端与工具：`data/*.json` 是打包进 App 的种子数据，`tools/build.py` 校验并生成 `app/assets/data.json` |
| [`updates/`](updates/) | `latest.json`：App 内「检查更新」读取的版本清单 |
| [`.github/workflows/`](.github/workflows/) | 发版流水线：打 tag 自动构建并发布 Release |
| [`CHANGELOG.md`](CHANGELOG.md) | 版本与改动记录（Keep a Changelog） |

## 数据从哪来

**单一来源：B 站官方号动态。**

```
你在 App 内登录 B 站（cookie 只留在 WebView）
        │
        ▼
← feed/space?host_mid=<你绑定的 UID>     逐账号串行拉取
        │
        ▼
大模型规范化 → {游戏, 版本, 类型, 起止时间, 摘要, 标签}
        │   校验不过 / 抽不出时间 → 丢弃，不猜
        ▼
本机事件库（shared_preferences）→ 日历 + 本地提醒 + .ics 导出
```

- App **不预置任何游戏，也不预置任何事件**：装完是空库，游戏和官号都由你自己添加；
- 登录态只活在 WebView 自己的 cookie jar 里，应用代码不读取、不上传；
- 大模型 key 只存在本机私有目录；
- 除了「B 站」和「你自己配置的大模型接口」，App 不连接任何服务器。

## 主要功能

- 月历 + 圆环标记，列表/日历两种视图；
- 事件详情：类型、版本、区间、标签、原文摘要、变更记录；
- 截止提醒（本地系统通知）、导出 `.ics`；
- **每天定时自动刷新**（默认 12:30 / 19:30，走 WorkManager，划掉 App 也会跑）；
- **版本/前瞻预测**：按上一个版本的节奏推算下个版本更新与前瞻，标「预测」，确认后被真实事件取代；
- **应用内检查更新**：从本仓库拉取 `updates/latest.json`，有新版本可直接下载并覆盖安装，数据不丢。

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
#    游戏库 → ＋ → 填官号 UID
#    订阅 → 大模型解析 → 填 API key（DeepSeek 或任意 OpenAI 兼容端点）
#    订阅 → B 站账号 → 登录 → 从 B 站刷新
```

## 发布与更新

App 内「检查更新」读的是 [`updates/latest.json`](updates/latest.json)：

```json
{
  "version": "2.14.0",
  "versionCode": 68,
  "apkUrl": "https://raw.githubusercontent.com/maker114/NijiCal/main/releases/NijiCal-2.14.0.apk",
  "notes": "本次更新说明"
}
```

发布走 **GitHub Actions**：推送 `v*` 标签即自动构建 APK、发 GitHub Release、
并回写 `updates/latest.json`（不依赖本地能否访问 GitHub API，也不再往仓库里塞 54MB 的包）。

```powershell
tool/release.ps1 -Version 2.15.0 -Code 72 -Note "本次更新说明"
```

脚本会：改版本号（`app/pubspec.yaml` + `app/lib/version.dart`）→ 本地 `analyze` + `test`
→ 提交 → 打 `v2.15.0` 标签 → 推送。之后 `.github/workflows/release.yml` 负责：
构建 → 校验签名与版本 → 发布 Release（APK 作为 asset）→ 提交新的 `updates/latest.json`。

**一次性配置（维护者）**

签名必须与历史版本一致，否则应用内「覆盖安装」会被系统拒绝。工作流从仓库 secret
读取 keystore：

1. 取 `~/.android/debug.keystore` 的 base64：
   `[Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:USERPROFILE\.android\debug.keystore"))`
2. GitHub → Settings → Secrets and variables → Actions → New repository secret，
   名称 **`ANDROID_DEBUG_KEYSTORE_BASE64`**，值为上面的字符串。

工作流会把它还原到 `~/.android/debug.keystore` 再构建，因此 CI 产出的 APK 与历史版本
**同一签名**。更换 keystore 会让老用户必须先卸载（数据会丢），务必沿用。

**安装时的系统拦截**（国产 ROM 常见，App 无法绕过）：

- 小米/澎湃：「未知来源」弹窗 → 继续；紧接着可能出现
  「未查询到 ICP 备案信息」→ 继续安装；
  若出现「增强防护提示」，需点右上角 `⋮` → **单次安装授权** → 「仍然安装」；
- 华为/OPPO/vivo 类似，通常也是一到两层确认。

这些都只是厂商侧的安全提示，确认后即为普通的覆盖安装，数据不受影响。

**签名**：应用内更新要求新旧 APK **同一个签名**，否则系统拒绝覆盖安装。
当前发布包使用开发者本机的 debug keystore（Flutter release 默认），
所以请始终用同一台机器/同一份 keystore 出包；换签名会让老用户必须先卸载（数据会丢）。
不要把 keystore 提交进仓库。

## 已知边界

- 未绑定官号 / 未配大模型 key 时，日历是空的——这是预期状态，不是故障；
- 自动刷新依赖系统保活，国产 ROM 需要允许「自启动」+「忽略电池优化」，否则到点不唤醒；
- 预测事件不排提醒，只是提示「大概该有消息了」。

## 许可

[MIT](LICENSE)
