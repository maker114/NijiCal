"""NijiCal MVP 本地预览服务器（零依赖）。

比 `python -m http.server` 多做两件事：
  1. 给 .ics 正确的 MIME（text/calendar），否则部分日历客户端会当二进制下载
  2. 关掉缓存，改完数据刷新就能看到

用法：python tools/serve.py [端口]
"""

from __future__ import annotations

import http.server
import functools
import socketserver
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "site"

EXTRA_TYPES = {
    ".ics": "text/calendar; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".html": "text/html; charset=utf-8",
    ".svg": "image/svg+xml",
}


class Handler(http.server.SimpleHTTPRequestHandler):
    def guess_type(self, path):  # noqa: D102
        suffix = Path(str(path)).suffix.lower()
        if suffix in EXTRA_TYPES:
            return EXTRA_TYPES[suffix]
        return super().guess_type(path)

    def end_headers(self):  # noqa: D102
        self.send_header("Cache-Control", "no-store, must-revalidate")
        super().end_headers()

    def log_message(self, fmt, *args):  # 输出更安静一点
        if "404" in (fmt % args):
            super().log_message(fmt, *args)


def main(argv: list[str]) -> int:
    port = int(argv[0]) if argv else 8787
    handler = functools.partial(Handler, directory=str(SITE))
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.ThreadingTCPServer(("127.0.0.1", port), handler) as httpd:
        print(f"NijiCal MVP  →  http://127.0.0.1:{port}/")
        print(f"ICS 订阅      →  http://127.0.0.1:{port}/calendar/all.ics")
        print("Ctrl+C 停止")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n已停止")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
