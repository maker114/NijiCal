# NijiCal 数据端（种子数据 + 构建工具）

> **2.0.0 起，事件由 App 内的「B 站动态 → 大模型」链路生成。**
> 本目录只负责三件事：种子数据 `data/*.json`、`build.py` 的校验与打包、`.ics` 预览。
> 官网采集通道已归档到 `tools/archive/collect_official.py`，不再参与构建。

产品本体在 [`../app/`](../app/)，手机端独立运行。

## 快速开始

```powershell
cd mvp
python tools/build.py          # 校验数据 → 生成 app/assets/data.json 与 site/
python tools/serve.py          # 可选：http://127.0.0.1:8787/ 看 Web 预览
```

只用标准库，不需要 `pip install`。

## 目录

```
mvp/
├─ data/
│  ├─ games.json          4 款游戏（异环 / 明日方舟 / 终末地 / 绝区零）+ 类型目录
│  ├─ events.json         种子事件（2.0.0 起为空，事件由 App 刷新产生）
│  └─ archive/            历史示例数据（演示用，不参与构建）
├─ tools/
│  ├─ build.py            校验 + 生成 app/assets/data.json 与 site/（含 .ics）
│  ├─ add.py              手工录一条事件（仍然可用）
│  ├─ bili.py             电脑端 B 站脚本（可选；App 内已能自己拉）
│  ├─ serve.py            本地预览服务器
│  ├─ shot.mjs            开发辅助：CDP 截图自检
│  └─ archive/
│     └─ collect_official.py   旧官网采集器（已停用，留档）
└─ secrets/               bili.example.json 模板（bili.json 已被 .gitignore 忽略）
```

## 事件字段

```json
{
  "id": "b...",
  "game_id": "arknights",
  "type": "活动结束",
  "title": "「时间啊，向前！」创作征集活动结束",
  "start": "2026-11-01T12:00:00+08:00",
  "end": "2026-12-01T23:59:00+08:00",
  "status": "confirmed",
  "confidence": 92,
  "version": "2.7",
  "tags": ["活动", "限时"],
  "summary": "…",
  "fetched_at": "2026-11-17T12:00:00+08:00",
  "source": { "name": "B站动态 · 明日方舟", "url": "https://t.bilibili.com/…" },
  "revisions": []
}
```

`build.py` 会拦下：缺必填字段、时间倒挂、游戏/类型不在目录、置信度越界、
`version` 不是 `x.y`、`tags` 超过 5 个或不是字符串数组。

## 和 App 的关系

```
data/*.json ──build.py──► app/assets/data.json（打进安装包，当作“出厂种子”）
                                   │
                          用户在 App 内刷新（B 站 + 大模型）
                                   ▼
                      shared_preferences（本机事件，覆盖同 URL 的种子）
```

所以：改了 `data/` 只是换“出厂数据”，用户手机上的实际数据由他刷新决定。

## 已知限制

- 种子为空时日历就是空的，这是预期状态；
- `add.py` 仍按老格式写入，不写 `version`/`tags`（缺省为 null / 空数组，校验允许）；
- `bili.py` 需要自备 SESSDATA，仅在你想在电脑端批量抓时才用。

## 下一步

- 打包时把种子数据与用户刷新结果做一次去重合并（现在以本机为准）；
- 审核队列：低置信事件不再直接丢弃，而是进“待确认”列表。
