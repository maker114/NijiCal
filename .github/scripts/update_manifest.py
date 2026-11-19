"""生成 updates/latest.json。

在 CI 里由 release.yml 调用；也可以在本地手动跑：

    VER=2.16.0 CODE=77 REPO=maker114/NijiCal TAG=v2.16.0 \
    NOTES="提交说明" python .github/scripts/update_manifest.py
"""

import datetime
import json
import os
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parents[2]
target = root / "updates" / "latest.json"

ver = os.environ.get("VER", "").strip()
code = os.environ.get("CODE", "").strip()
repo = os.environ.get("REPO", "").strip()
tag = os.environ.get("TAG", "").strip()
notes = os.environ.get("NOTES", "").strip()


def fail(msg: str) -> None:
    print(f"::error::{msg}", file=sys.stderr)
    sys.exit(1)


if not ver or not code or not repo or not tag:
    fail("缺少环境变量：VER / CODE / REPO / TAG 都必须给")

data = {
    "version": ver,
    "versionCode": int(code),
    "apkUrl": f"https://github.com/{repo}/releases/download/{tag}/NijiCal-{ver}.apk",
    "publishedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"),
    "notes": notes,
}

target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"wrote {target}")
print(target.read_text(encoding="utf-8"))
