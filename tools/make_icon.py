"""生成 App 图标（1024x1024，不透明 PNG）。用法: python tools/make_icon.py"""
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import os

S = 2048  # 先画 2 倍大再缩小，边缘更平滑
OUT = os.path.join(os.path.dirname(__file__), "..", "App", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")
FONTS = "C:/Windows/Fonts/"

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

# 背景：左上靛蓝 → 右下紫红 的对角渐变
top, bottom = (52, 64, 230), (176, 56, 214)
bg = Image.new("RGB", (S, S))
px = bg.load()
for y in range(S):
    for x in range(S):
        px[x, y] = lerp(top, bottom, (x + y) / (2 * S))

def rounded(draw, box, r, fill):
    x0, y0, x1, y1 = box
    draw.rectangle([x0 + r, y0, x1 - r, y1], fill=fill)
    draw.rectangle([x0, y0 + r, x1, y1 - r], fill=fill)
    for cx, cy in [(x0, y0), (x1 - 2 * r, y0), (x0, y1 - 2 * r), (x1 - 2 * r, y1 - 2 * r)]:
        draw.ellipse([cx, cy, cx + 2 * r, cy + 2 * r], fill=fill)

def bubble(box, r, fill, tail):
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    rounded(d, box, r, fill)
    d.polygon(tail, fill=fill)
    return layer

def shadow(layer, offset=(0, 36), blur=50, alpha=90):
    a = layer.split()[3].point(lambda v: v * alpha // 255)
    sh = Image.new("RGBA", (S, S), (20, 10, 60, 0))
    sh.putalpha(a)
    sh = sh.filter(ImageFilter.GaussianBlur(blur))
    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    out.paste(sh, offset, sh)
    return out

canvas = bg.convert("RGBA")

# 白色气泡（英文 A），左上
white = bubble((300, 330, 1290, 1180), 190, (255, 255, 255, 255),
               [(470, 1120), (700, 1120), (420, 1420)])
# 黄色气泡（中文 中），右下
yellow = bubble((760, 880, 1750, 1730), 190, (255, 210, 50, 255),
                [(1580, 1670), (1350, 1670), (1640, 1960)])

for layer in (white, yellow):
    canvas = Image.alpha_composite(canvas, shadow(layer))
    canvas = Image.alpha_composite(canvas, layer)

d = ImageDraw.Draw(canvas)
fa = ImageFont.truetype(FONTS + "arialbd.ttf", 620)
fz = ImageFont.truetype(FONTS + "msyhbd.ttc", 560)

def center_text(text, font, box, fill, dy=0):
    x0, y0, x1, y1 = box
    # 兼容旧版 Pillow（没有 textbbox）
    l, t, r, b = font.getmask(text).getbbox()
    ox, oy = font.getoffset(text)
    l, t, r, b = l + ox, t + oy, r + ox, b + oy
    w, h = r - l, b - t
    d.text(((x0 + x1 - w) / 2 - l, (y0 + y1 - h) / 2 - t + dy), text, font=font, fill=fill)

center_text("A", fa, (300, 330, 1060, 1060), (60, 60, 210))
center_text("中", fz, (760, 880, 1750, 1730), (40, 30, 80))

icon = canvas.convert("RGB").resize((1024, 1024), Image.LANCZOS)
icon.save(OUT, "PNG")
print("saved", os.path.abspath(OUT))
