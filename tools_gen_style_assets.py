"""Generates bundled style thumbnails (150px) + before/after previews.

Synthetic sample scene (sky, sun, hills, city, a person silhouette) graded per
style. Placeholders until real sample photos are shot.
"""
import json, math, os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageEnhance, ImageOps

ROOT = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(ROOT, "ai_camera", "assets", "styles")
lib = json.load(open(os.path.join(ASSETS, "library.json")))

W, H = 480, 640

def base_scene():
    im = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(im)
    for y in range(H):
        t = y / H
        r = int(120 + 100 * t); g = int(170 + 50 * t); b = int(235 - 60 * t)
        d.line([(0, y), (W, y)], fill=(r, g, b))
    d.ellipse([320, 80, 410, 170], fill=(255, 236, 170))
    # hills
    pts = [(0, 420)] + [(x, 400 - 40 * math.sin(x / 70.0)) for x in range(0, W + 1, 8)] + [(W, H), (0, H)]
    d.polygon(pts, fill=(70, 130, 80))
    # city blocks
    for i, x in enumerate(range(10, W, 46)):
        h = 70 + (i * 37) % 90
        d.rectangle([x, 430 - h, x + 36, 470], fill=(150 + (i * 13) % 60, 120, 110 + (i * 7) % 50))
        for wy in range(430 - h + 10, 460, 16):
            d.rectangle([x + 6, wy, x + 12, wy + 7], fill=(255, 220, 140))
            d.rectangle([x + 22, wy, x + 28, wy + 7], fill=(255, 220, 140))
    d.rectangle([0, 470, W, H], fill=(110, 95, 85))
    # person
    d.ellipse([200, 360, 270, 440], fill=(205, 150, 120))
    d.rounded_rectangle([180, 440, 290, 640], radius=30, fill=(180, 40, 60))
    d.ellipse([196, 350, 274, 395], fill=(40, 30, 30))
    return im

def grade(im, sid):
    a = np.asarray(im).astype(np.float32) / 255.0
    def out(x): return Image.fromarray((np.clip(x, 0, 1) * 255).astype(np.uint8))
    if sid == "cinematic":
        lum = a.mean(axis=2, keepdims=True)
        a = a + (1 - lum) * np.array([-0.06, 0.02, 0.08]) + lum * np.array([0.08, 0.03, -0.06])
        a = (a - 0.5) * 1.15 + 0.5
    elif sid == "night":
        a = a * 0.45 + np.array([0.0, 0.02, 0.10]); a = a ** 1.1
    elif sid == "studio_portrait":
        a = (a - 0.5) * 1.05 + 0.53; a = a * 0.9 + a.mean(axis=2, keepdims=True) * 0.1
    elif sid == "vintage":
        a = a * 0.85 + 0.08 + np.array([0.06, 0.02, -0.05])
    elif sid == "golden_hour":
        a = a * np.array([1.12, 1.0, 0.82]) + np.array([0.05, 0.02, 0.0])
    elif sid == "black_white":
        l = (a * np.array([0.3, 0.59, 0.11])).sum(axis=2, keepdims=True); a = np.repeat((l - 0.5) * 1.2 + 0.5, 3, axis=2)
    elif sid == "vivid_travel":
        l = a.mean(axis=2, keepdims=True); a = l + (a - l) * 1.45; a = (a - 0.5) * 1.08 + 0.5
    elif sid == "soft_skin":
        im2 = im.filter(ImageFilter.GaussianBlur(2)); a = np.asarray(im2).astype(np.float32) / 255 * 1.05 + 0.03
    elif sid == "moody_film":
        l = a.mean(axis=2, keepdims=True); a = l + (a - l) * 0.65; a = a * 0.9 + np.array([0.0, 0.02, 0.05])
    elif sid == "bright_airy":
        a = a * 0.8 + 0.22; l = a.mean(axis=2, keepdims=True); a = l + (a - l) * 0.8
    elif sid == "festive_glow":
        a = a * np.array([1.15, 1.02, 0.85]); l = a.mean(axis=2, keepdims=True); a = l + (a - l) * 1.25 + 0.03
    elif sid == "food_pop":
        l = a.mean(axis=2, keepdims=True); a = l + (a - l) * 1.3; a = a * np.array([1.05, 1.02, 0.95])
    res = out(a)
    if sid in ("vintage", "cinematic", "moody_film"):
        # vignette
        yy, xx = np.mgrid[0:H, 0:W]; d = ((xx - W / 2) ** 2 + (yy - H / 2) ** 2) / ((W / 2) ** 2 + (H / 2) ** 2)
        v = 1 - 0.35 * d ** 1.5
        res = out(np.asarray(res).astype(np.float32) / 255 * v[..., None])
    return res

base = base_scene()
os.makedirs(os.path.join(ASSETS, "previews"), exist_ok=True)
os.makedirs(os.path.join(ASSETS, "thumbs"), exist_ok=True)
base.save(os.path.join(ASSETS, "previews", "before.jpg"), quality=82)
for s in lib["styles"]:
    g = grade(base, s["id"])
    g.save(os.path.join(ASSETS, "previews", s["id"] + ".jpg"), quality=82)
    # 150px thumb: square crop around person + city
    t = g.crop((60, 260, 420, 620)).resize((150, 150), Image.LANCZOS)
    t.save(os.path.join(ASSETS, "thumbs", s["id"] + ".png"), optimize=True)
print("ok", len(lib["styles"]))
