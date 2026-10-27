"""make-icons.py — draw the Logonoff icon (clock on a teal tile).

Writes www/icon-192.png, www/icon-512.png (maskable: the tile fills the
square, the clock stays in the safe zone), www/favicon.png and
packaging/logonoff.ico (embedded in the exe by windres).
Usage: python3 tools/make-icons.py   (needs Pillow)
"""
import math
import os
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BG = (15, 118, 110)       # teal-700
FG = (255, 255, 255)
ACCENT = (253, 186, 116)  # orange-300


def draw(size, rounded):
    s = size * 4  # supersample
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if rounded:
        d.rounded_rectangle([0, 0, s - 1, s - 1], radius=s // 5, fill=BG)
    else:
        d.rectangle([0, 0, s - 1, s - 1], fill=BG)
    c = s / 2
    r = s * 0.30  # inside the maskable safe zone (40% radius)
    w = max(4, int(s * 0.045))
    d.ellipse([c - r, c - r, c + r, c + r], outline=FG, width=w)
    # elapsed-time wedge from 12 o'clock to 4 o'clock
    d.pieslice([c - r + w * 1.6, c - r + w * 1.6, c + r - w * 1.6, c + r - w * 1.6],
               start=-90, end=30, fill=ACCENT)
    # hands
    def hand(angle_deg, length, width):
        a = math.radians(angle_deg - 90)
        d.line([c, c, c + math.cos(a) * length, c + math.sin(a) * length], fill=FG, width=width)
    hand(0, r * 0.62, w)
    hand(120, r * 0.78, int(w * 0.8))
    d.ellipse([c - w, c - w, c + w, c + w], fill=FG)
    return img.resize((size, size), Image.LANCZOS)


os.makedirs(os.path.join(ROOT, "www"), exist_ok=True)
os.makedirs(os.path.join(ROOT, "packaging"), exist_ok=True)
draw(192, False).save(os.path.join(ROOT, "www", "icon-192.png"))
draw(512, False).save(os.path.join(ROOT, "www", "icon-512.png"))
draw(64, True).save(os.path.join(ROOT, "www", "favicon.png"))
draw(256, True).save(os.path.join(ROOT, "packaging", "logonoff.ico"),
                     sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
print("icons written")
