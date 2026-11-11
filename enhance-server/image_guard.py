"""v11 Pro Night hallucination guard (mirrors lib/services/image_guard.dart).

1. ``night_signal`` / ``too_dark``: a merged night frame with almost no
   signal (very low mean luminance, no highlights, almost no bright pixels) is NOT sent
   to the AI — nothing to recover, so the model would invent content
   (the v10 near-black test came back with pillars / ground). Nothing is
   charged; the app suggests Normal Night or the flash.
2. ``structure_similarity``: after the AI returns, compare the edge
   structure of input and output on a small, contrast-normalised grayscale
   proxy (brightening / denoise keep the structure; new objects or a
   different layout add or move edges). Below ``STRUCTURE_MIN`` the result
   is rejected and nothing is charged.

Pure Pillow + Python (no numpy); proxies are tiny (≤ 64 px wide).
"""
from __future__ import annotations

import io
import math
from dataclasses import dataclass

from PIL import Image, ImageFilter, ImageOps

# Gate thresholds (same numbers in image_guard.dart).
DARK_MEAN_MAX = 0.035         # mean luma (0..1) below this …
DARK_P99_MAX = 0.10           # … no real highlights (99th percentile) …
DARK_BRIGHT_FRAC_MAX = 0.004  # … and fewer than 0.4 % pixels above BRIGHT_LEVEL
BRIGHT_LEVEL = 0.25
STRUCTURE_MIN = 0.50
PROXY_W = 64


@dataclass
class NightSignal:
    mean: float
    bright_frac: float
    p99: float

    @property
    def too_dark(self) -> bool:
        return (self.mean < DARK_MEAN_MAX and self.p99 < DARK_P99_MAX
                and self.bright_frac < DARK_BRIGHT_FRAC_MAX)


def _gray(raw: bytes, width: int) -> Image.Image:
    im = ImageOps.exif_transpose(Image.open(io.BytesIO(raw))).convert("L")
    h = max(1, round(im.height * width / max(1, im.width)))
    return im.resize((width, h), Image.BILINEAR)


def night_signal_from_values(values: list[int]) -> NightSignal:
    n = max(1, len(values))
    mean = sum(values) / n / 255.0
    bright = sum(1 for v in values if v / 255.0 > BRIGHT_LEVEL) / n
    srt = sorted(values)
    p99 = srt[min(len(srt) - 1, int(0.99 * (len(srt) - 1)))] / 255.0 if srt else 0.0
    return NightSignal(mean, bright, p99)


def night_signal(raw: bytes) -> NightSignal:
    return night_signal_from_values(list(_gray(raw, 160).tobytes()))


def too_dark(raw: bytes) -> bool:
    return night_signal(raw).too_dark


def _normalised(im: Image.Image) -> list[float]:
    px = list(im.tobytes())
    n = len(px)
    m = sum(px) / n
    sd = math.sqrt(sum((p - m) ** 2 for p in px) / n) or 1.0
    return [(p - m) / sd for p in px]


def gradient_similarity(a: list[float], b: list[float], w: int, h: int) -> float:
    """Cosine similarity of the two gradient fields (1 = same structure)."""
    num = da = db = 0.0
    for y in range(h - 1):
        r = y * w
        for x in range(w - 1):
            i = r + x
            ax, ay = a[i + 1] - a[i], a[i + w] - a[i]
            bx, by = b[i + 1] - b[i], b[i + w] - b[i]
            num += ax * bx + ay * by
            da += ax * ax + ay * ay
            db += bx * bx + by * by
    if da <= 1e-9 or db <= 1e-9:
        return 1.0 if da <= 1e-9 and db <= 1e-9 else 0.0
    return num / math.sqrt(da * db)


def structure_similarity(src: bytes, out: bytes) -> float:
    a = _gray(src, PROXY_W).filter(ImageFilter.BoxBlur(1))
    b = ImageOps.exif_transpose(Image.open(io.BytesIO(out))).convert("L").resize(a.size, Image.BILINEAR)
    b = b.filter(ImageFilter.BoxBlur(1))
    return gradient_similarity(_normalised(a), _normalised(b), a.width, a.height)


def structure_ok(src: bytes, out: bytes) -> tuple[bool, float]:
    s = structure_similarity(src, out)
    return s >= STRUCTURE_MIN, s


# v11.31 zoom framing check (mirrors framingSimilarity in image_guard.dart):
# shift-tolerant edge similarity of the AI result vs. the final photo.
FRAMING_PROXY_W = 48
FRAMING_MAX_SHIFT = 3
FRAMING_MIN = 0.35


def framing_similarity_values(a: list[float], b: list[float], w: int, h: int,
                              max_shift: int = FRAMING_MAX_SHIFT) -> float:
    best = -1.0
    for dy in range(-max_shift, max_shift + 1):
        for dx in range(-max_shift, max_shift + 1):
            num = da = db = 0.0
            for y in range(max_shift, h - 1 - max_shift):
                for x in range(max_shift, w - 1 - max_shift):
                    i = y * w + x
                    j = (y + dy) * w + x + dx
                    ax, ay = a[i + 1] - a[i], a[i + w] - a[i]
                    bx, by = b[j + 1] - b[j], b[j + w] - b[j]
                    num += ax * bx + ay * by
                    da += ax * ax + ay * ay
                    db += bx * bx + by * by
            if da <= 1e-9 or db <= 1e-9:
                s = 1.0 if da <= 1e-9 and db <= 1e-9 else 0.0
            else:
                s = num / math.sqrt(da * db)
            best = max(best, s)
    return best


def framing_similarity(src: bytes, out: bytes) -> float:
    a = _gray(src, FRAMING_PROXY_W).filter(ImageFilter.BoxBlur(2))
    b = ImageOps.exif_transpose(Image.open(io.BytesIO(out))).convert("L").resize(a.size, Image.BILINEAR)
    b = b.filter(ImageFilter.BoxBlur(2))
    return framing_similarity_values(_normalised(a), _normalised(b), a.width, a.height)


def framing_ok(src: bytes, out: bytes) -> tuple[bool, float]:
    s = framing_similarity(src, out)
    return s >= FRAMING_MIN, s


# v11.59 zoom output check (mirrors zoomOutputCheck in image_guard.dart): the
# AI result must keep the SOURCE area's structure (the sharp source when one
# was sent, else the final zoom) and, without a chosen look, its colours.
ZOOM_STRUCTURE_MIN = STRUCTURE_MIN
ZOOM_COLOUR_MAX_DIST = 70.0
ZOOM_COLOUR_PROXY_W = 16


def _rgb_proxy(raw: bytes, w: int, h: int) -> list[tuple[int, int, int]]:
    im = ImageOps.exif_transpose(Image.open(io.BytesIO(raw))).convert("RGB")
    im = im.resize((w, h), Image.BOX)
    b = im.tobytes()
    return [(b[i], b[i + 1], b[i + 2]) for i in range(0, len(b), 3)]


def mean_colour_distance(src: bytes, out: bytes) -> float:
    im = Image.open(io.BytesIO(src))
    sw, sh = im.size
    w = ZOOM_COLOUR_PROXY_W
    h = max(1, round(w * sh / max(1, sw)))
    a, b = _rgb_proxy(src, w, h), _rgb_proxy(out, w, h)
    n = min(len(a), len(b))
    if n == 0:
        return 0.0
    return sum(math.dist(a[i], b[i]) for i in range(n)) / n


def zoom_output_ok(src: bytes, out: bytes, check_colour: bool = True) -> tuple[bool, float]:
    s = structure_similarity(src, out)
    ok = s >= ZOOM_STRUCTURE_MIN
    if ok and check_colour:
        ok = mean_colour_distance(src, out) <= ZOOM_COLOUR_MAX_DIST
    return ok, s
