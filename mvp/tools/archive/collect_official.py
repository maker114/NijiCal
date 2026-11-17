"""官方公告采集器（Phase 0.5：无账号、只读、低频）。

流程：
  官方新闻列表页（无头 Edge 渲染）→ 抽条目（标题 + 链接）
    → 逐条渲染详情页 → 正则抽时间区间 → 关键词判类型
    → 输出 data/candidates.json（带来源、原文摘录、置信度）

再运行 `python tools/collect.py --promote 85` 把高置信候选写进 data/events.json。

设计约束（照《架构设计》5.3 / 5.4）：
  · 只读公开公告页，串行 + 每次之间 sleep，不并发；
  · 不下载图片、不绕验证；
  · 每条都必须留来源 URL 与原文摘录，抽不准就进“待确认”。

用法：
  python tools/collect.py                    # 抓全部站点，输出候选
  python tools/collect.py --site arknights   # 只抓一站
  python tools/collect.py --limit 4          # 每站最多 4 条
  python tools/collect.py --promote 85       # 把置信度 ≥85 的候选写进事件库
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
EDGE = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
TZ = timezone(timedelta(hours=8))

# 一个站点 = 新闻列表页 + 详情链接的模式
# 只保留当前追踪的 4 款游戏：异环 / 明日方舟 / 终末地 / 绝区零
# （终末地的列表页把卡片渲染成 div、不带详情链接，暂时接不了，见 README）
SITES = {
    "nte": {
        "game_id": "nte",
        "name": "异环",
        "list": "https://nte.perfectworld.com/cn/article/news/gamenews/index.html",
        "detail": re.compile(r"^/cn/article/news/gamenews/\d+/\d+\.html$"),
    },
    "arknights": {
        "game_id": "arknights",
        "name": "明日方舟",
        "list": "https://ak.hypergryph.com/news",
        "detail": re.compile(r"^/news/\d+$"),
    },
    "zzz": {
        "game_id": "zzz",
        "name": "绝区零",
        "list": "https://zzz.mihoyo.com/news",
        "detail": re.compile(r"^/news/\d+$"),
    },
}

ORIGIN = {
    "nte": "https://nte.perfectworld.com",
    "arknights": "https://ak.hypergryph.com",
    "zzz": "https://zzz.mihoyo.com",
}

END_WORDS = ("结束", "关闭", "截止", "失效", "下架")
START_WORDS = ("开启", "上线", "开始", "开放")


def render(url: str, budget: int = 8000) -> str:
    proc = subprocess.run(
        [EDGE, "--headless=new", "--disable-gpu", "--no-sandbox",
         f"--virtual-time-budget={budget}", "--dump-dom", url],
        capture_output=True,
        timeout=120,
    )
    return proc.stdout.decode("utf-8", errors="ignore")


def plain_text(html: str) -> str:
    t = re.sub(r"<script.*?</script>", " ", html, flags=re.S)
    t = re.sub(r"<style.*?</style>", " ", t, flags=re.S)
    t = re.sub(r"<[^>]+>", " ", t)
    t = t.replace("&nbsp;", " ").replace("&amp;", "&")
    return re.sub(r"\s+", " ", t).strip()


def list_items(html: str, detail_re: re.Pattern[str]) -> list[tuple[str, str]]:
    """从列表页抽 (标题, 绝对链接)，按出现顺序去重。"""
    out: list[tuple[str, str]] = []
    seen: set[str] = set()
    for m in re.finditer(r'<a\b[^>]*href="([^"]+)"[^>]*>(.*?)</a>', html, re.S):
        href, inner = m.group(1), m.group(2)
        if not detail_re.search(href):
            continue
        title = plain_text(inner)
        title = re.sub(r"^[\s•·|]+", "", title)
        if len(title) < 8 or len(title) > 90:
            continue
        if href in seen:
            continue
        seen.add(href)
        out.append((title, href))
    return out


MONTH_DAY = re.compile(r"(\d{1,2})\s*月\s*(\d{1,2})\s*日\s*(\d{1,2})\s*[:：]\s*(\d{2})")

# 「维护时间：2026年11月08日16:00 ~ 17:00」这类带标签的时间窗
WINDOW_LABELS = (
    "维护时间", "闪断更新时间", "停服维护时间", "更新时间",
    "活动时间", "开放时间", "祈愿时间", "跃迁时间", "寻访时间",
    "卡池时间", "领取时间", "有效期",
)
WINDOW_RE = re.compile(
    r"(?:(\d{4})\s*年\s*)?(\d{1,2})\s*月\s*(\d{1,2})\s*日\s*(\d{1,2})\s*[:：]\s*(\d{2})"
    r"\s*[~～\-—－至到]\s*"
    r"(?:(\d{1,2})\s*月\s*)?(?:(\d{1,2})\s*日\s*)?(\d{1,2})\s*[:：]\s*(\d{2})"
)

TITLE_PREFIX = re.compile(r"^\s*(公告|活动|新闻|资讯|通知|情报)\s*\d{4}\s*//\s*\d{1,2}\s*/\s*\d{1,2}\s*")


def clean_title(raw: str) -> str:
    t = TITLE_PREFIX.sub("", raw)
    t = re.sub(r"\s*-\s*(明日方舟|原神|崩坏：星穹铁道|绝区零|鸣潮|异环|终末地)\s*$", "", t)
    # 列表页常把「标题 + 日期 + 分类」拼在一起
    t = re.sub(r"\s+20\d{2}[./-]\d{1,2}[./-]\d{1,2}\s*$", "", t)
    t = re.sub(r"\s*(新闻|公告|活动|资讯|情报)\s*$", "", t)
    # 列表里的 <a> 常常把正文摘要也带进来，按这些词切断
    for marker in (" 亲爱", " 各位", " 二相", " 开拓者", " 绳匠", " 博士", " 管理员",
                   " 完成活动", " 活动期间", " • ", " 活动说", " 检定员"):
        t = t.split(marker)[0]
    # 标题被重复了两遍的情况（完美世界那套模板常见）
    t = t.strip()
    for cut in range(len(t) // 2, 5, -1):
        head, tail = t[:cut].strip(), t[cut:].strip()
        if head and tail.startswith(head):
            t = head
            break
    t = t.strip()
    return t[:40] + "…" if len(t) > 40 else t


def find_window(text: str, now: datetime) -> tuple[datetime | None, datetime | None]:
    """在正文里找时间窗：优先取「活动时间：…～…」这类带标签的，其次取第一个能解析的。"""
    fallback: tuple[datetime, datetime] | None = None
    for m in WINDOW_RE.finditer(text):
        y, mo, d, h, mi, mo2, d2, h2, mi2 = m.groups()
        year = int(y) if y else now.year
        try:
            start = datetime(year, int(mo), int(d), int(h), int(mi), tzinfo=TZ)
        except ValueError:
            continue
        end_month = int(mo2) if mo2 else int(mo)
        end_day = int(d2) if d2 else int(d)
        try:
            end = datetime(year, end_month, end_day, int(h2), int(mi2), tzinfo=TZ)
        except ValueError:
            continue
        if end < start:                       # 跨年
            end = end.replace(year=year + 1)
        if end <= start:
            continue
        labelled = any(lb in text[max(0, m.start() - 30):m.start()] for lb in WINDOW_LABELS)
        if labelled:
            return start, end
        if fallback is None:
            fallback = (start, end)
    return fallback if fallback else (None, None)


def extract_times(text: str, now: datetime) -> list[datetime]:
    """抽「11月28日 03:59」这类时间，并补全年份。"""
    found: list[datetime] = []
    for m in MONTH_DAY.finditer(text):
        month, day, hour, minute = (int(g) for g in m.groups())
        if not (1 <= month <= 12 and 1 <= day <= 31 and hour <= 23 and minute <= 59):
            continue
        for year in (now.year, now.year + 1):
            try:
                dt = datetime(year, month, day, hour, minute, tzinfo=TZ)
            except ValueError:
                continue
            # 早于“60 天前”的一律算下一年（公告里的时间都是未来或刚过去）
            if dt >= now - timedelta(days=60):
                found.append(dt)
                break
    # 去重且排序
    uniq = sorted({dt for dt in found})
    return uniq


def classify(title: str) -> str | None:
    t = title
    if "兑换码" in t or "礼包码" in t:
        return "兑换码截止"
    if "补偿" in t:
        return "补偿领取截止"
    if "前瞻" in t or "特别节目" in t or "直播节目" in t:
        return "前瞻直播"
    if any(w in t for w in ("停机维护", "停服", "闪断更新", "维护公告", "更新公告", "维护")):
        return "停服维护"
    if any(w in t for w in ("版本更新", "新版本", "版本上线")):
        return "版本更新"
    if any(w in t for w in ("寻访", "祈愿", "跃迁", "卡池", "限定")):
        return "卡池结束" if any(w in t for w in END_WORDS) else "卡池开始"
    if any(w in t for w in ("活动", "征集", "复刻", "签到")):
        return "活动结束" if any(w in t for w in END_WORDS) else "活动开始"
    return None


def score(has_window: bool, n_times: int, etype: str | None, title: str) -> int:
    s = 55                       # 官方站来源
    if has_window:
        s += 25                  # 有「活动时间/维护时间」标注
    elif n_times:
        s += 8                   # 只有零散时间，容易抽错
    if etype:
        s += 10
    if re.search(r"\d{1,2}月\d{1,2}日", title):
        s += 5
    return min(s, 96)


def collect_site(key: str, limit: int) -> list[dict]:
    site = SITES[key]
    now = datetime.now(TZ)
    print(f"\n[{site['name']}] 列表页 {site['list']}")
    html = render(site["list"])
    items = list_items(html, site["detail"])
    print(f"  抽到 {len(items)} 条新闻")

    results: list[dict] = []
    for idx, (raw_title, href) in enumerate(items[:limit], 1):
        title = clean_title(raw_title)
        url = href if href.startswith("http") else ORIGIN[key] + href
        try:
            detail_html = render(url, budget=6000)
        except Exception as exc:  # noqa: BLE001
            print(f"  [{idx}] 详情失败 {url}: {exc}")
            continue
        text = plain_text(detail_html)
        start, end = find_window(text, now)
        fallback = extract_times(text, now)
        etype = classify(title)
        has_window = start is not None

        if start is None and fallback:
            single = fallback[-1]
            if etype in ("活动开始", "卡池开始"):
                # 只有一个时间时，它几乎总是“截止”，把类型翻成对应的结束事件
                etype = "活动结束" if etype == "活动开始" else "卡池结束"
                end = single
            elif etype in ("兑换码截止", "补偿领取截止", "活动结束", "卡池结束"):
                end = single
            elif len(fallback) >= 2:
                start, end = fallback[0], fallback[-1]
            else:
                start = single

        conf = score(has_window, len(fallback), etype, title)

        # 已经过去的事件不要（只要还有未来意义）
        effective = end or start
        if effective and effective < now - timedelta(hours=6):
            print(f"  [{idx}] 跳过（已过期）{title[:30]}")
            continue
        if etype is None or (start is None and end is None):
            print(f"  [{idx}] 跳过（看不出类型/时间）{title[:30]}")
            continue

        print(f"  [{idx}] {title[:32]:<32} {etype:<8} 置信 {conf}  "
              f"{start.strftime('%m/%d %H:%M') if start else '—'} ~ {end.strftime('%m/%d %H:%M') if end else '—'}")
        results.append({
            "site": key,
            "game_id": site["game_id"],
            "title": title,
            "url": url,
            "type": etype,
            "start": start.isoformat() if start else None,
            "end": end.isoformat() if end else None,
            "times": [t.isoformat() for t in fallback],
            "has_window": has_window,
            "confidence": conf,
            "excerpt": text[:180],
            "fetched_at": now.isoformat(timespec="seconds"),
        })
        time.sleep(0.8)      # 别把人家站扫炸
    return results


def promote(threshold: int) -> int:
    """把高置信候选写进 data/events.json（幂等：按来源 URL 去重）。"""
    path = DATA / "candidates.json"
    if not path.exists():
        print("[FAIL] 还没有 candidates.json，先跑一次采集", file=sys.stderr)
        return 1
    cand = json.loads(path.read_text(encoding="utf-8"))
    events_path = DATA / "events.json"
    doc = json.loads(events_path.read_text(encoding="utf-8"))

    known_urls = {(e.get("source") or {}).get("url") for e in doc["events"]}
    ids = [int(m.group(1)) for e in doc["events"] if (m := re.match(r"e(\d+)$", e["id"]))]
    next_id = max(ids, default=0) + 1

    added = 0
    for c in cand:
        if c["confidence"] < threshold:
            continue
        start, end = c.get("start"), c.get("end")
        if not start and not end:
            continue
        if c["url"] in known_urls:
            continue

        title = clean_title(c["title"])
        status = "confirmed" if c["confidence"] >= 90 else "tentative"
        base = {
            "game_id": c["game_id"],
            "status": status,
            "confidence": c["confidence"],
            "summary": c["excerpt"][:120],
            "fetched_at": c["fetched_at"],
            "source": {"name": "官网公告", "url": c["url"]},
            "revisions": [],
        }

        # 有时间窗的活动/卡池 → 拆成“开始”和“结束”两条，提醒才会落在截止点上
        if start and end and c["type"] in ("活动开始", "卡池开始"):
            prefix = "活动" if c["type"] == "活动开始" else "卡池"
            rows = [
                {"type": f"{prefix}开始", "start": start, "end": None},
                {"type": f"{prefix}结束", "start": None, "end": end},
            ]
        else:
            rows = [{"type": c["type"], "start": start, "end": end}]

        for row in rows:
            doc["events"].append({
                "id": f"e{next_id:03d}",
                "title": title,
                **row,
                **base,
            })
            next_id += 1
            added += 1

        known_urls.add(c["url"])

    events_path.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"[OK] 新增 {added} 条事件（阈值 {threshold}）→ data/events.json")
    return 0


def main(argv: list[str]) -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser()
    ap.add_argument("--site", action="append", help="只抓指定站点（可多次）")
    ap.add_argument("--limit", type=int, default=6, help="每站最多几条详情")
    ap.add_argument("--promote", type=int, metavar="CONF", help="把置信度 ≥CONF 的候选写进事件库")
    args = ap.parse_args(argv)

    if args.promote is not None:
        return promote(args.promote)

    keys = args.site or list(SITES)
    all_items: list[dict] = []
    for key in keys:
        if key not in SITES:
            print(f"[FAIL] 未知站点 {key}", file=sys.stderr)
            return 1
        try:
            all_items.extend(collect_site(key, args.limit))
        except Exception as exc:  # noqa: BLE001
            print(f"[WARN] {SITES[key]['name']} 采集失败：{exc}")

    out = DATA / "candidates.json"
    out.write_text(json.dumps(all_items, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    ok = [c for c in all_items if c["type"] and c["times"]]
    print(f"\n[OK] 候选 {len(all_items)} 条，其中可直接入库 {len(ok)} 条 → {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
