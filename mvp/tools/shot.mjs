// 开发辅助：用 Edge 的 CDP 给指定锚点/滚动位置截图，便于视觉自检。
// 用法：node tools/shot.mjs <url> <选择器或 0 表示顶部> <输出文件名> [宽] [高]
// 依赖：系统安装了 Edge（Windows 默认路径）；Node 22+ 自带 WebSocket。

import { spawn } from "node:child_process";
import { writeFile } from "node:fs/promises";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const EDGE = "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe";
const [url, selector = "0", out = "shot.png", w = "1440", h = "1000", expr = ""] = process.argv.slice(2);
const PORT = 9333;

const profile = await mkdtemp(join(tmpdir(), "nijical-shot-"));
const child = spawn(
  EDGE,
  [
    "--headless=new",
    "--disable-gpu",
    "--hide-scrollbars",
    `--remote-debugging-port=${PORT}`,
    `--user-data-dir=${profile}`,
    `--window-size=${w},${h}`,
    "about:blank",
  ],
  { stdio: "ignore" }
);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function findTarget() {
  for (let i = 0; i < 60; i++) {
    try {
      const res = await fetch(`http://127.0.0.1:${PORT}/json/list`);
      const list = await res.json();
      const page = list.find((t) => t.type === "page");
      if (page?.webSocketDebuggerUrl) return page.webSocketDebuggerUrl;
    } catch {
      /* 还没起来 */
    }
    await sleep(250);
  }
  throw new Error("没等到 CDP 端点");
}

const wsUrl = await findTarget();
const ws = new WebSocket(wsUrl);
let id = 0;
const pending = new Map();

ws.addEventListener("message", (ev) => {
  const msg = JSON.parse(ev.data);
  if (msg.id && pending.has(msg.id)) {
    pending.get(msg.id)(msg.result);
    pending.delete(msg.id);
  }
});

const send = (method, params = {}) =>
  new Promise((resolve) => {
    const mid = ++id;
    pending.set(mid, resolve);
    ws.send(JSON.stringify({ id: mid, method, params }));
  });

await new Promise((r) => ws.addEventListener("open", r));

await send("Page.enable");
await send("Emulation.setDeviceMetricsOverride", {
  width: Number(w),
  height: Number(h),
  deviceScaleFactor: 1,
  mobile: Number(w) < 600,
});
await send("Page.navigate", { url });
await sleep(1800);

if (selector !== "0") {
  await send("Runtime.evaluate", {
    expression: `(() => { const el = document.querySelector(${JSON.stringify(selector)});
      if (!el) return "missing"; el.scrollIntoView({block:"start"}); window.scrollBy(0,-24); return el.offsetTop; })()`,
  });
  await sleep(700);
}

if (expr) {
  const r = await send("Runtime.evaluate", { expression: expr, returnByValue: true });
  console.log("eval:", JSON.stringify(r?.result?.value ?? r?.exceptionDetails ?? null));
  await sleep(900);
}

const shot = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: false });
await writeFile(out, Buffer.from(shot.data, "base64"));
console.log(`saved ${out}`);
ws.close();
child.kill();
