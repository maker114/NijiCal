# AGENTS.md — 本项目对 AI 协作者的工作约定

> 通用规范（版本号、commit、更新日志、PL-/Q- 协议）见 [`DSH通用规范.md`](DSH通用规范.md)；
> 本文件只写 **NijiCal 这个项目特有**的部分，冲突时以本文件为准。

## 1. 项目一句话

Flutter 手机 App：把二游官号（B 站）的动态，经大模型规范化成带截止时间的事件，
进日历、发本地提醒、可导出 `.ics`。**全离线于手机运行**，只有两个出网方向：
B 站（用户自己的登录态）和用户自配的大模型接口。

- 仓库：`git@github.com:maker114/NijiCal.git`（公开，默认分支 `main`）
- 客户端：`app/`（Flutter 3.47.5 / Dart 3.13.4）
- 数据种子与工具：`mvp/`
- 发版产物：GitHub Releases（APK 资产），清单 `updates/latest.json`

## 2. 红线（任何情况下都不做）

1. **不读取、不落盘、不上传 B 站 cookie**（`SESSDATA` 等）。登录只在 WebView 自己的 jar 里。
2. **不把敏感物提交进仓库**：大模型 API key、cookie、真实账号 UID、本机绝对路径、
   `key.properties`、`*.jks`、`keystore`。审查时连 git 历史一起看。
3. **不编造数据**：不预设官方 UID，不伪造事件；抽不出时间就丢弃，不猜。
4. **不动别人的东西**：工作区里不是自己产生的改动（如 `DSH通用规范.md`）不提交、不撤销。
5. **不覆盖用户数据**：本地测试包不得清空用户已绑定的游戏/事件；需要清数据先问。

## 3. 迭代与验证流程（**重要，决定速度**）

默认走「本地快循环」，只有到发版节点才上云：

```
改代码 → flutter analyze + flutter test（十几秒）
      → 本地构建 APK（约 1–3 分钟）
      → adb install -r 装到手机
      → 让用户自己试，或我用 adb 点按 + 截图确认
      → 反复调整（此时不发版、不改版本号）
      → 攒够一批 / 用户说「发版」 → 才走云端发布
```

**必须遵守的分工：**

| 改动类型 | 验证方式 | 是否发版 |
| :--- | :--- | :--- |
| 纯逻辑、文案、格式 | `flutter test` / 单测 | 否 |
| UI / 交互 | 本地装 APK，真机点按 | 否（攒批） |
| CI 流水线本身 | 推 `v*` 标签验证 | 是（必须走真 CI） |

**禁止**：为一句文案或一个小修就单独发一版；每轮改动最多构建一次、装机一次。

## 4. 发版（只在用户说「发版」或明确同意时执行）

```powershell
tool/release.ps1 -Version X.Y.Z -Code N -Note "第1条;第2条;第3条"
```

它会：改 `app/pubspec.yaml` + `app/lib/version.dart` → 本地 analyze/test → 提交
（`-Note` 每条转成提交正文的 `- 条目`）→ 打 `vX.Y.Z` 标签 → 推送。

之后 GitHub Actions（`.github/workflows/release.yml`）自动完成：
构建 → 校验签名指纹 → 发 Release（APK 作为资产）→ 回写 `updates/latest.json`。

**要点**

- 版本号只有一个源头：`pubspec.yaml` 与 `app/lib/version.dart` 必须同步，构建号逐版递增；
- **签名必须沿用同一把 keystore**（仓库 secret `ANDROID_DEBUG_KEYSTORE_BASE64`），
  否则用户覆盖安装会被系统拒绝；
- 清单 `notes` 支持多行：App 的「检查更新」按行拆分显示，所以每条更新说明单独一行；
- 版本号规则按 `DSH通用规范.md`：新功能升次位、修缺陷/文案升修订位、纯外观升修订位。

## 5. 真机验证要点

- 设备：`51dabb34`（小米 2410DPN6CC，1080×2400）。截图预览坐标 ×1.289 即为 adb 点按坐标；
- 截图用 `adb shell screencap` 后 `adb pull`，看完即删，不要提交进仓库；
- 装机时小米会弹三层确认：未知来源 → ICP 备案 → 增强防护（右上 `⋮` → 单次安装授权 → 仍然安装）；
- 手机锁屏或被用户占用时**不要驱动界面**，等用户解锁或让对方自己试。

## 6. 提交纪律

按 `DSH通用规范.md` 执行，且在本项目额外注意：

- 提交前 `git diff --cached --name-only` 核对，只提交自己的路径；
- 不用 `git add -A` / `git add .`；
- 推送前先 `git fetch` + `git rebase origin/main`（历史上出现过 push 被拒却没报错）；
- 更新日志 `CHANGELOG.md` 与代码改动同提交。
