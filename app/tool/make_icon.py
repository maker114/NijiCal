"""生成 NijiCal 的 Android 图标。

设计：深墨色圆角底 + 一页白色日历 + 右侧一段彩色圆环（对应 App 里的 DayRing）。
一个脚本产出全部尺寸，改配色只改这里的常量。

用法：python tool/make_icon.py
"""

from pathlib import Path

from PIL import Image, ImageDraw

INK = (55, 71, 79)          # #37474F 主色（ink）
INK_DEEP = (38, 50, 56)     # #263238 渐变下缘
SHEET = (250, 250, 248)     # 日历纸
SHEET_EDGE = (225, 226, 222)
LINE = (208, 212, 210)      # 纸上的横线
ACCENT = (127, 163, 143)    # #7FA38F 方舟绿，作为圆环主色
ACCENTS = [(138, 127, 168), (127, 163, 143), (127, 143, 168), (181, 143, 110)]  # 四款游戏的标识色

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "android" / "app" / "src" / "main" / "res"


def rounded(draw, box, radius, fill):
    draw.rounded_rectangle(box, radius=radius, fill=fill)


def shade(size, top, bottom):
    """竖向渐变底"""
    img = Image.new("RGB", (size, size), top)
    d = ImageDraw.Draw(img)
    for y in range(size):
        t = y / max(size - 1, 1)
        color = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        d.line([(0, y), (size, y)], fill=color)
    return img


def draw_background(size):
    """满幅底：墨色渐变"""
    return shade(size, INK, INK_DEEP)


def draw_foreground(size):
    """透明前景：日历纸 + 圆环，尺寸按 108dp 画布，内容落在安全区内"""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    s = size

    # 纸张：略偏左，给右侧圆环留位
    left, top, right, bottom = s * 0.22, s * 0.26, s * 0.76, s * 0.74
    radius = s * 0.055
    d.rounded_rectangle([left + s * 0.006, top + s * 0.012, right + s * 0.006, bottom + s * 0.012],
                        radius=radius, fill=(0, 0, 0, 55))  # 投影
    d.rounded_rectangle([left, top, right, bottom], radius=radius, fill=SHEET + (255,))

    # 顶部装订条：两块深色小圆
    bar_y = top + s * 0.075
    d.rounded_rectangle([left + s * 0.03, bar_y - s * 0.022, right - s * 0.03, bar_y + s * 0.022],
                        radius=s * 0.022, fill=INK + (255,))

    # 纸上的三条横线
    line_x0, line_x1 = left + s * 0.055, right - s * 0.055
    for i, width_ratio in enumerate((1.0, 0.78, 0.86)):
        y = top + s * 0.155 + i * s * 0.075
        d.rounded_rectangle([line_x0, y, line_x0 + (line_x1 - line_x0) * width_ratio, y + s * 0.024],
                            radius=s * 0.012, fill=LINE + (255,))

    # 右侧圆环：三段弧，取自 App 的 DayRing
    cx, cy, ring_r = s * 0.735, s * 0.66, s * 0.185
    width = s * 0.058
    box = [cx - ring_r, cy - ring_r, cx + ring_r, cy + ring_r]
    spans = [(-90, 30, ACCENTS[0]), (30, 150, ACCENTS[1]), (150, 270, ACCENTS[2])]
    for start, end, color in spans:
        d.arc(box, start=start, end=end, fill=color + (255,), width=int(width))

    # 圆环中心一个小圆点
    dot = s * 0.03
    d.ellipse([cx - dot, cy - dot, cx + dot, cy + dot], fill=INK + (255,))
    return img


def legacy_icon(size):
    """老式图标：底 + 前景，圆角（系统可能再裁一次，所以给满幅圆角）"""
    base = draw_background(size).convert("RGBA")
    fg = draw_foreground(size)
    base.alpha_composite(fg)
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=int(size * 0.22), fill=255)
    base.putalpha(mask)
    return base


def main():
    sizes = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
    for density, px in sizes.items():
        out = RES / f"mipmap-{density}" / "ic_launcher.png"
        out.parent.mkdir(parents=True, exist_ok=True)
        legacy_icon(1024).resize((px, px), Image.LANCZOS).save(out)
        print("wrote", out)

    # 自适应图标：前景 432dp 画布（108dp * 4x）
    for density, scale in {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}.items():
        px = int(108 * scale)
        out = RES / f"mipmap-{density}" / "ic_launcher_foreground.png"
        draw_foreground(1024).resize((px, px), Image.LANCZOS).save(out)
        print("wrote", out)

    # 背景色（纯色即可，避免多放一张大图）
    (RES / "values").mkdir(parents=True, exist_ok=True)
    (RES / "values" / "ic_launcher_background.xml").write_text(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        "<resources>\n"
        f"    <color name=\"ic_launcher_background\">#{INK[0]:02X}{INK[1]:02X}{INK[2]:02X}</color>\n"
        "</resources>\n",
        encoding="utf-8",
    )

    # 自适应图标描述
    anydpi = RES / "mipmap-anydpi-v26"
    anydpi.mkdir(parents=True, exist_ok=True)
    adaptive = (
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        "<adaptive-icon xmlns:android=\"http://schemas.android.com/apk/res/android\">\n"
        "    <background android:drawable=\"@color/ic_launcher_background\" />\n"
        "    <foreground android:drawable=\"@mipmap/ic_launcher_foreground\" />\n"
        "</adaptive-icon>\n"
    )
    (anydpi / "ic_launcher.xml").write_text(adaptive, encoding="utf-8")
    print("wrote", anydpi / "ic_launcher.xml")

    # 一张 512 的大图，方便发给别人看
    preview = ROOT.parent / "dist" / "icon-512.png"
    preview.parent.mkdir(parents=True, exist_ok=True)
    legacy_icon(1024).resize((512, 512), Image.LANCZOS).save(preview)
    print("wrote", preview)


if __name__ == "__main__":
    main()
