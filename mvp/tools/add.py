"""NijiCal MVP —— 人工录入一条事件（Phase 0 的主要工作方式）。

Phase 0 的策略是“人工优先”：编辑看完官方动态，用这个脚本把时间录进来，
再由 build.py 生成页面与 ICS。等采集接了，这个脚本仍然有用（补录/纠错）。

交互式：
  python tools/add.py

带参数（适合批量/脚本）：
  python tools/add.py --game genshin --type 卡池结束 \\
      --title "「月之六」角色活动祈愿结束" \\
      --end "2026-11-17 17:59" --confidence 96 \\
      --summary "祈愿结束后角色获取途径关闭。" \\
      --source-name "B站官方号" --source-url "https://space.bilibili.com/xxx/dynamic"

时间写法：`2026-11-17 17:59`、`2026-11-17T17:59+08:00` 都可以，一律按 +08:00 理解。
只有开始时间就传 --start；只有截止时间就传 --end。
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
TZ = timezone(timedelta(hours=8))


def parse_time(value: str) -> str:
    """把多种写法统一成带 +08:00 的 ISO 字符串。"""
    raw = value.strip().replace("/", "-")
    for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%d %H:%M:%S", "%m-%d %H:%M", "%Y-%m-%d"):
        try:
            dt = datetime.strptime(raw, fmt)
            if fmt == "%m-%d %H:%M":
                dt = dt.replace(year=datetime.now(TZ).year)
            return dt.replace(tzinfo=TZ).isoformat()
        except ValueError:
            continue
    dt = datetime.fromisoformat(raw)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=TZ)
    return dt.astimezone(TZ).isoformat()


def prompt(label: str, default: str = "") -> str:
    suffix = f" [{default}]" if default else ""
    val = input(f"{label}{suffix}: ").strip()
    return val or default


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--game")
    ap.add_argument("--type")
    ap.add_argument("--title")
    ap.add_argument("--start")
    ap.add_argument("--end")
    ap.add_argument("--confidence", type=int)
    ap.add_argument("--status", default="confirmed", choices=["confirmed", "tentative", "changed", "expired"])
    ap.add_argument("--summary", default="")
    ap.add_argument("--source-name", default="B站官方号")
    ap.add_argument("--source-url", default=None)
    ap.add_argument("--no-build", action="store_true", help="录完不自动重新构建")
    args = ap.parse_args(argv)

    games_doc = json.loads((DATA / "games.json").read_text(encoding="utf-8"))
    games = games_doc["games"]
    games_by_id = {g["id"]: g for g in games}
    catalog = games_doc["meta"]["type_catalog"]
    events_path = DATA / "events.json"
    doc = json.loads(events_path.read_text(encoding="utf-8"))

    # 交互补齐
    if not args.game:
        print("可选游戏：")
        for i, g in enumerate(games, 1):
            print(f"  {i:>2}. {g['id']:<12} {g['name']}")
        args.game = prompt("游戏 id 或序号")
        if args.game.isdigit():
            args.game = games[int(args.game) - 1]["id"]
    if args.game not in games_by_id:
        print(f"[FAIL] 未知游戏 {args.game!r}", file=sys.stderr)
        return 1

    if not args.type:
        print("可选类型：" + "、".join(catalog))
        args.type = prompt("类型")
    if args.type not in catalog:
        print(f"[FAIL] 未知类型 {args.type!r}", file=sys.stderr)
        return 1

    if not args.title:
        args.title = prompt("标题（照抄公告，别自己改数字）")
    if not args.title:
        print("[FAIL] 标题必填", file=sys.stderr)
        return 1

    if not (args.start or args.end):
        print("至少填一个时间。只有截止就填 end；只有开始就填 start。")
        args.end = prompt("截止/结束时间（留空则填开始）") or None
        if not args.end:
            args.start = prompt("开始时间")

    if args.confidence is None:
        raw = prompt("置信度 0~100（官方明确时间一般 90+，模糊表达 55~70）", "90")
        args.confidence = int(re.sub(r"\D", "", raw) or 90)

    if not args.summary:
        args.summary = prompt("一句话摘要（可留空）")

    try:
        start = parse_time(args.start) if args.start else None
        end = parse_time(args.end) if args.end else None
    except ValueError as exc:
        print(f"[FAIL] 时间解析失败：{exc}", file=sys.stderr)
        return 1

    if start and end and end <= start:
        print("[FAIL] end 必须晚于 start", file=sys.stderr)
        return 1

    ids = [int(m.group(1)) for e in doc["events"] if (m := re.match(r"e(\d+)$", e["id"]))]
    next_id = f"e{max(ids, default=0) + 1:03d}"

    event = {
        "id": next_id,
        "game_id": args.game,
        "type": args.type,
        "title": args.title,
        "start": start,
        "end": end,
        "status": args.status,
        "confidence": args.confidence,
        "summary": args.summary,
        "fetched_at": datetime.now(TZ).isoformat(timespec="seconds"),
        "source": {"name": args.source_name, "url": args.source_url},
        "revisions": [],
    }
    doc["events"].append(event)
    events_path.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print(f"[OK] 已写入 {next_id}：{games_by_id[args.game]['name']} · {args.type} · {args.title}")

    if not args.no_build:
        print("[..] 重新构建站点…")
        return subprocess.call([sys.executable, str(ROOT / "tools" / "build.py")])
    print("下一步：python tools/build.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
