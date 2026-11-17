"""NijiCal MVP 构建脚本（零依赖，只用标准库）。

做三件事：
  1. 校验 data/games.json 与 data/events.json（字段、时间、外键、类型）
  2. 生成 site/assets/data.js —— 前端直接内联读取，绕开 file:// 的 CORS 限制
  3. 生成 ICS 订阅文件 —— 全部 / 每款游戏 / 单条事件

用法：
  python tools/build.py            # 校验 + 构建
  python tools/build.py --check    # 只校验

设计约束（来自产品文档）：
  - 事件必须有来源、置信度、状态；低于阈值的进“待确认”，不默认强提醒
  - 提醒围绕截止点：结束/截止类提前量与开始类不同
"""

from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
SITE = ROOT / "site"

TZ = timezone(timedelta(hours=8))
TZ_NAME = "Asia/Shanghai"

REQUIRED_EVENT_FIELDS = ("id", "game_id", "type", "title", "status", "confidence", "source")

STATUSES = {"confirmed", "tentative", "changed", "expired"}

# 提醒模板（分钟）。负值 = 提前量；与产品文档 3.1.5 一致。
ALARMS = {
    "前瞻直播": (-1440, -60),
    "版本更新": (-1440, -60),
    "停服维护": (-1440, -60),
    "活动开始": (-1440, -60),
    "卡池开始": (-1440, -60),
    "活动结束": (-1440, -180),
    "卡池结束": (-1440, -180),
    "兑换码截止": (-180, -30),
    "补偿领取截止": (-1440, -180),
}

TYPE_ORDER = [
    "兑换码截止", "补偿领取截止", "卡池结束", "活动结束", "停服维护",
    "版本更新", "前瞻直播", "卡池开始", "活动开始",
]


def load_json(path: Path):
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def parse_dt(value: str | None) -> datetime | None:
    if not value:
        return None
    dt = datetime.fromisoformat(value)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=TZ)
    return dt.astimezone(TZ)


def validate(games: list[dict], events: list[dict], type_catalog: list[str]) -> list[str]:
    """返回错误列表；空列表表示通过。"""
    errors: list[str] = []
    game_ids = {g["id"] for g in games}

    seen: set[str] = set()
    for i, ev in enumerate(events):
        tag = f"events[{i}] ({ev.get('id', '?')})"
        for field in REQUIRED_EVENT_FIELDS:
            if field not in ev:
                errors.append(f"{tag}: 缺少必填字段 {field}")
        if ev.get("id") in seen:
            errors.append(f"{tag}: id 重复")
        seen.add(ev.get("id"))

        if ev.get("game_id") not in game_ids:
            errors.append(f"{tag}: game_id={ev.get('game_id')!r} 不在 games.json")
        if ev.get("type") not in type_catalog:
            errors.append(f"{tag}: type={ev.get('type')!r} 不在类型目录")
        if ev.get("status") not in STATUSES:
            errors.append(f"{tag}: status={ev.get('status')!r} 非法")
        ver = ev.get("version")
        if ver is not None and not re.fullmatch(r"\d+\.\d+", str(ver)):
            errors.append(f"{tag}: version 必须是 x.y 形式，收到 {ver!r}")
        tags = ev.get("tags")
        if tags is not None:
            if not isinstance(tags, list) or any(not isinstance(x, str) for x in tags):
                errors.append(f"{tag}: tags 必须是字符串数组")
            elif len(tags) > 5:
                errors.append(f"{tag}: tags 最多 5 个")
        conf = ev.get("confidence")
        if not isinstance(conf, int) or not 0 <= conf <= 100:
            errors.append(f"{tag}: confidence 必须是 0~100 的整数")

        try:
            start, end = parse_dt(ev.get("start")), parse_dt(ev.get("end"))
        except ValueError as exc:
            errors.append(f"{tag}: 时间格式错误 ({exc})")
            continue
        if not start and not end:
            errors.append(f"{tag}: start 与 end 不能同时为空")
        if start and end and end <= start:
            errors.append(f"{tag}: end 必须晚于 start")

        src = ev.get("source") or {}
        if not src.get("name"):
            errors.append(f"{tag}: source.name 必填（来源透明是产品原则）")
        if not src.get("url"):
            # 不算错误：采集未接入前来源链接允许为空，但要在报告里数出来
            pass

    return errors


# ---------------------------------------------------------------- ICS


def ics_escape(text: str) -> str:
    return (
        text.replace("\\", "\\\\")
        .replace(";", "\\;")
        .replace(",", "\\,")
        .replace("\r\n", "\\n")
        .replace("\n", "\\n")
    )


def fold(line: str) -> str:
    """按 RFC 5545 折行：每行不超过 75 个八位组。"""
    raw = line.encode("utf-8")
    if len(raw) <= 75:
        return line
    out, chunk, buf = [], b"", b""
    for ch in line:
        b = ch.encode("utf-8")
        if len(buf) + len(b) > 73:
            out.append(buf)
            buf = b""
        buf += b
    out.append(buf)
    return ("\r\n ".join(seg.decode("utf-8") for seg in out))


def duration(minutes: int) -> str:
    """把提前量分钟转成 RFC 5545 的 DURATION。"""
    assert minutes < 0
    m = -minutes
    if m % 1440 == 0:
        return f"-P{m // 1440}D"
    if m % 60 == 0:
        return f"-PT{m // 60}H"
    return f"-PT{m}M"


def local_stamp(dt: datetime) -> str:
    return dt.strftime("%Y%m%dT%H%M%S")


def event_block(ev: dict, game: dict) -> list[str]:
    start = parse_dt(ev.get("start"))
    end = parse_dt(ev.get("end"))

    if start and end:
        dt_start, dt_end = start, end
    elif start:                              # 点事件（如前瞻直播）
        dt_start, dt_end = start, start + timedelta(hours=1)
    else:                                    # 截止事件：截止时刻即事件时刻
        dt_start, dt_end = end, end + timedelta(minutes=15)

    kind = "截止" if not start else "开始"
    when = dt_start.strftime("%m月%d日 %H:%M")
    summary = f"【{game['short']}】{ev['title']}"
    desc_lines = [
        ev.get("summary") or "",
        f"类型：{ev['type']}｜{kind}：{when}",
        f"置信度：{ev['confidence']}%（{status_label(ev)}）",
        f"来源：{(ev.get('source') or {}).get('name', '未标注')}",
    ]
    if ev.get("revisions"):
        last = ev["revisions"][-1]
        desc_lines.append(f"变更：{last.get('field')} {last.get('from')} → {last.get('to')}")
    if ev.get("status") == "tentative":
        desc_lines.append("该事件为待确认状态，时间可能变动。")

    lines = [
        "BEGIN:VEVENT",
        f"UID:{ev['id']}@nijical",
        f"DTSTAMP:{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}",
        f"DTSTART;TZID={TZ_NAME}:{local_stamp(dt_start)}",
        f"DTEND;TZID={TZ_NAME}:{local_stamp(dt_end)}",
        fold(f"SUMMARY:{ics_escape(summary)}"),
        fold(f"DESCRIPTION:{ics_escape(chr(10).join(x for x in desc_lines if x))}"),
        fold(f"CATEGORIES:{ics_escape(ev['type'])}"),
        f"STATUS:{'TENTATIVE' if ev.get('status') == 'tentative' else 'CONFIRMED'}",
        "TRANSP:TRANSPARENT",
        f"X-NIJICAL-CONFIDENCE:{ev['confidence']}",
        f"X-NIJICAL-STATE:{ev['status']}",
    ]
    src_url = (ev.get("source") or {}).get("url")
    if src_url:
        lines.append(f"URL:{src_url}")

    for offset in ALARMS.get(ev["type"], (-1440, -60)):
        lines += [
            "BEGIN:VALARM",
            "ACTION:DISPLAY",
            fold(f"DESCRIPTION:{ics_escape('NijiCal：' + summary)}"),
            f"TRIGGER:{duration(offset)}",
            "END:VALARM",
        ]

    lines.append("END:VEVENT")
    return lines


def status_label(ev: dict) -> str:
    return {
        "confirmed": "官方确认",
        "tentative": "待确认",
        "changed": "已变更",
        "expired": "已过期",
    }.get(ev.get("status"), ev.get("status", ""))


def calendar(events: list[dict], games_by_id: dict, name: str) -> str:
    lines = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//NijiCal//MVP//CN",
        "CALSCALE:GREGORIAN",
        "METHOD:PUBLISH",
        fold(f"X-WR-CALNAME:{ics_escape(name)}"),
        f"X-WR-TIMEZONE:{TZ_NAME}",
        "BEGIN:VTIMEZONE",
        f"TZID:{TZ_NAME}",
        "BEGIN:STANDARD",
        "DTSTART:19700101T000000",
        "TZOFFSETFROM:+0800",
        "TZOFFSETTO:+0800",
        "TZNAME:CST",
        "END:STANDARD",
        "END:VTIMEZONE",
    ]
    for ev in events:
        lines += event_block(ev, games_by_id[ev["game_id"]])
    lines.append("END:VCALENDAR")
    return "\r\n".join(lines) + "\r\n"


# ---------------------------------------------------------------- main


def main(argv: list[str]) -> int:
    check_only = "--check" in argv

    games_doc = load_json(DATA / "games.json")
    events_doc = load_json(DATA / "events.json")
    games = games_doc["games"]
    events = events_doc["events"]
    catalog = games_doc["meta"]["type_catalog"]
    games_by_id = {g["id"]: g for g in games}

    errors = validate(games, events, catalog)
    if errors:
        print(f"[FAIL] 校验未通过，共 {len(errors)} 条：", file=sys.stderr)
        for e in errors:
            print("  - " + e, file=sys.stderr)
        return 1

    now = datetime.now(TZ)
    upcoming = [e for e in events if (parse_dt(e.get("end")) or parse_dt(e.get("start"))) >= now]
    no_source = [e["id"] for e in events if not (e.get("source") or {}).get("url")]

    print("[OK] 数据校验通过")
    print(f"     游戏 {len(games)} 款｜事件 {len(events)} 条｜未到期 {len(upcoming)} 条")
    print(f"     来源链接缺失 {len(no_source)} 条（采集未接入，属预期）")

    if check_only:
        return 0

    (SITE / "assets").mkdir(parents=True, exist_ok=True)
    (SITE / "calendar" / "event").mkdir(parents=True, exist_ok=True)

    # 清掉上一次的 ICS，避免删掉的事件留下陈旧文件（日历客户端会读到“幽灵事件”）
    for stale in (SITE / "calendar").glob("*.ics"):
        stale.unlink()
    for stale in (SITE / "calendar" / "event").glob("*.ics"):
        stale.unlink()

    payload = {
        "meta": {
            **events_doc["meta"],
            "built_at": now.isoformat(timespec="seconds"),
            "event_count": len(events),
            "game_count": len(games),
        },
        "type_catalog": catalog,
        "type_order": TYPE_ORDER,
        "alarms": {k: list(v) for k, v in ALARMS.items()},
        "games": games,
        "events": events,
    }
    (SITE / "assets" / "data.js").write_text(
        "window.NIJICAL_DATA = " + json.dumps(payload, ensure_ascii=False, indent=2) + ";\n",
        encoding="utf-8",
    )

    # 给 Flutter 客户端供数：同一份 payload，App 内置后即可离线运行
    app_assets = ROOT.parent / "app" / "assets"
    if app_assets.parent.exists():
        app_assets.mkdir(parents=True, exist_ok=True)
        (app_assets / "data.json").write_text(
            json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
        )

    (SITE / "calendar" / "all.ics").write_text(
        calendar(events, games_by_id, "NijiCal · 全部二游日程"), encoding="utf-8", newline=""
    )
    per_game = 0
    for g in games:
        sub = [e for e in events if e["game_id"] == g["id"]]
        if not sub:
            continue
        (SITE / "calendar" / f"{g['id']}.ics").write_text(
            calendar(sub, games_by_id, f"NijiCal · {g['name']}"), encoding="utf-8", newline=""
        )
        per_game += 1
    for ev in events:
        (SITE / "calendar" / "event" / f"{ev['id']}.ics").write_text(
            calendar([ev], games_by_id, f"NijiCal · {ev['title']}"), encoding="utf-8", newline=""
        )

    print(f"[OK] 已生成 site/assets/data.js")
    print(f"[OK] 已生成 ICS：all.ics + {per_game} 个游戏日历 + {len(events)} 条单事件")
    if (ROOT.parent / "app" / "assets" / "data.json").exists():
        print(f"[OK] 已生成 app/assets/data.json（Flutter 内置数据）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
