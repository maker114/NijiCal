"""B 站动态采集（方案 B：登录态、单账号、只读、低频）。

凭据**不由本脚本产生，也不会被打印**：从 `mvp/secrets/bili.json` 读取，格式：

    { "sessdata": "xxxx", "buvid3": "可选", "buvid4": "可选" }

这个目录已在 .gitignore 里，不会进仓库。填法见 README「接 B 站动态」。

用法：
    python tools/bili.py --accounts data/accounts.json     # 按游戏→UID 抓一轮
    python tools/bili.py --uid 401742377 --limit 10        # 只抓一个号
    python tools/collect.py --promote 70                   # 和官网采集共用入库逻辑

设计约束（《架构设计》5.7）：
  · 串行 + 每次请求之间 1.5s，单轮最多 20 个号；
  · 只读 space 动态接口，不点赞/不转发/不关注；
  · 撞 -352 / -412 立刻停，不重试轰炸；
  · 任何一条抽不准都进“待确认”，不进自动发布。
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

from collect import classify, clean_title, find_window

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
SECRETS = ROOT / "secrets" / "bili.json"
TZ = timezone(timedelta(hours=8))

API = "https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/space?host_mid={uid}"
UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
)

RISK_CODES = {-352: "风控校验失败（-352）", -412: "请求被拦截（-412）", -101: "未登录（-101）"}


def load_cookie() -> str:
    if not SECRETS.exists():
        raise SystemExit(
            f"[FAIL] 找不到 {SECRETS}\n"
            "        先按 README「接 B 站动态」把 SESSDATA 写进去（不要发在聊天里）。"
        )
    raw = json.loads(SECRETS.read_text(encoding="utf-8"))
    sess = (raw.get("sessdata") or "").strip()
    if not sess:
        raise SystemExit("[FAIL] secrets/bili.json 里 sessdata 为空")
    parts = [f"SESSDATA={sess}"]
    for key, cookie in (("buvid3", "buvid3"), ("buvid4", "buvid4"), ("bili_jct", "bili_jct")):
        val = (raw.get(key) or "").strip()
        if val:
            parts.append(f"{cookie}={val}")
    return "; ".join(parts)


def fetch(uid: str, cookie: str, timeout: int = 20) -> dict:
    req = urllib.request.Request(
        API.format(uid=uid),
        headers={
            "User-Agent": UA,
            "Referer": f"https://space.bilibili.com/{uid}/dynamic",
            "Cookie": cookie,
            "Accept": "application/json, text/plain, */*",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8", errors="ignore"))


def dynamics_text(item: dict) -> tuple[str, str]:
    """返回 (正文, 动态类型)。只取公开可见的正文，不碰图片。"""
    mod = item.get("modules") or {}
    dyn = mod.get("module_dynamic") or {}
    desc = (dyn.get("desc") or {}).get("text") or ""
    major = dyn.get("major") or {}
    opus = major.get("opus") or {}
    title = (opus.get("title") or "").strip()
    summary = " ".join(
        (t.get("text") or "") for t in (opus.get("summary") or {}).get("rich_text_nodes") or []
    )
    text = " ".join(x for x in (title, desc, summary) if x).strip()
    return text or "", item.get("type") or ""


def collect_dynamics(game: str, uid: str, cookie: str, limit: int, now: datetime) -> list[dict]:
    data = fetch(uid, cookie)
    code = data.get("code")
    if code != 0:
        name = RISK_CODES.get(code, f"接口返回 {code}: {data.get('message')}")
        print(f"  [{game}] UID {uid} -> {name}")
        if code in RISK_CODES:
            raise SystemExit("[STOP] 被风控/未登录，立刻停止，不重试。")
        return []

    items = ((data.get("data") or {}).get("items") or [])[:limit]
    print(f"  [{game}] UID {uid}：{len(items)} 条动态")
    out: list[dict] = []
    for item in items:
        text, kind = dynamics_text(item)
        if not text:
            continue
        start, end = find_window(text, now)
        etype = classify(text)
        if etype is None or (start is None and end is None):
            continue
        effective = end or start
        if effective and effective < now - timedelta(hours=6):
            continue
        title = clean_title(text.split(" ")[0] if " " in text else text)
        title = clean_title(text[:40]) or title
        out.append({
            "site": "bilibili",
            "game_id": game,
            "title": title,
            "url": f"https://t.bilibili.com/{item.get('id_str', '')}",
            "type": etype,
            "start": start.isoformat() if start else None,
            "end": end.isoformat() if end else None,
            "times": [],
            "has_window": start is not None,
            "confidence": 88 if start is not None else 72,
            "excerpt": text[:180],
            "fetched_at": now.isoformat(timespec="seconds"),
        })
    return out


def main(argv: list[str]) -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser()
    ap.add_argument("--accounts", default=str(DATA / "accounts.json"), help="游戏 → B 站 UID")
    ap.add_argument("--uid", help="只抓单个 UID（调试用）")
    ap.add_argument("--game", default="zzz", help="配合 --uid 使用")
    ap.add_argument("--limit", type=int, default=12, help="每个号最多看几条动态")
    args = ap.parse_args(argv)

    cookie = load_cookie()
    now = datetime.now(TZ)

    if args.uid:
        pairs = [(args.game, args.uid)]
    else:
        path = Path(args.accounts)
        if not path.exists():
            raise SystemExit(f"[FAIL] 找不到 {path}，先在 App 里绑定官号并复制配置写进去。")
        accounts = json.loads(path.read_text(encoding="utf-8"))
        pairs = [(g, str(u)) for g, u in accounts.items() if u]
        if not pairs:
            raise SystemExit("[FAIL] accounts.json 里没有 UID")

    if len(pairs) > 20:
        raise SystemExit("[FAIL] 单轮最多 20 个号，按额度控制")

    print(f"[..] 本轮 {len(pairs)} 个号，串行 1.5s/次")
    collected: list[dict] = []
    for i, (game, uid) in enumerate(pairs, 1):
        try:
            collected.extend(collect_dynamics(game, uid, cookie, args.limit, now))
        except SystemExit:
            raise
        except urllib.error.HTTPError as exc:
            print(f"  [{game}] UID {uid} HTTP {exc.code}")
        except Exception as exc:  # noqa: BLE001
            print(f"  [{game}] UID {uid} 失败：{exc}")
        if i < len(pairs):
            time.sleep(1.5)

    out = DATA / "candidates.json"
    existing = json.loads(out.read_text(encoding="utf-8")) if out.exists() else []
    known = {c["url"] for c in existing}
    merged = existing + [c for c in collected if c["url"] not in known]
    out.write_text(json.dumps(merged, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print(f"\n[OK] 本轮新增候选 {len(merged) - len(existing)} 条 → {out}")
    print("     下一步：python tools/collect.py --promote 70")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
