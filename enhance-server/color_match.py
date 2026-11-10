"""v11.5/v11.7: server-side colour match of an AI macro result to its source crop.

Matches the mean and spread of the chroma channels (Cb, Cr) and the mean of
luma (Y) in YCbCr, so the hue / white balance / overall brightness follow the
real photo (fixes "leaf turned greener") while the AI's fine detail and local
contrast stay. Pure PIL (no numpy)."""
from __future__ import annotations

import io

from PIL import Image, ImageChops, ImageFilter, ImageStat

# v11.7 regional chroma match: the output's low-frequency colour (an 8x8 grid,
# bilinearly smoothed) is replaced by the source crop's, so e.g. a golden
# patch on uniform silver metal goes back to silver; fine chroma detail stays.
REGION_GRID = 8

# Spread scaling is clamped so a flat source can't blow up the result.
# v11.39: never amplify chroma spread (coloured RGB dots on skin / hair / paper).
_MIN_GAIN, _MAX_GAIN = 0.6, 1.0

# v11.42: overall (global) Y/Cb/Cr mean shift cap, and the average Cb/Cr
# difference above which the colour match is skipped entirely.
GLOBAL_MAX_SHIFT = 10
COLOR_SKIP_DIFF = 12


def skip_match(mean_out, mean_src) -> bool:
    return (abs(mean_out[1] - mean_src[1]) + abs(mean_out[2] - mean_src[2])) / 2 > COLOR_SKIP_DIFF


def _stats(im: Image.Image):
    st = ImageStat.Stat(im)
    return st.mean, st.stddev


def _lut(mean_o: float, std_o: float, mean_s: float, std_s: float, match_spread: bool):
    gain = 1.0
    if match_spread and std_o > 1e-3:
        gain = max(_MIN_GAIN, min(_MAX_GAIN, std_s / std_o))
    return [max(0, min(255, round((v - mean_o) * gain + mean_s))) for v in range(256)]


def match_colors(out_bytes: bytes, source_bytes: bytes, strength: float = 1.0) -> bytes:
    """Returns JPEG bytes of [out_bytes] with the source crop's colour stats."""
    out = Image.open(io.BytesIO(out_bytes)).convert("RGB")
    src = Image.open(io.BytesIO(source_bytes)).convert("RGB")
    probe_o = out.copy(); probe_o.thumbnail((256, 256))
    probe_s = src.copy(); probe_s.thumbnail((256, 256))
    (mo, so), (ms, ss) = _stats(probe_o.convert("YCbCr")), _stats(probe_s.convert("YCbCr"))
    # v11.42: result colours far from the source (the AI changed what is in the
    # frame) → no colour match; else the overall shift is capped.
    if skip_match(mo, ms):
        return out_bytes
    ms = [mo[i] + max(-GLOBAL_MAX_SHIFT, min(GLOBAL_MAX_SHIFT, ms[i] - mo[i])) for i in range(3)]
    y, cb, cr = out.convert("YCbCr").split()
    y = y.point(_lut(mo[0], so[0], ms[0], ss[0], match_spread=False))
    cb = cb.point(_lut(mo[1], so[1], ms[1], ss[1], match_spread=True))
    cr = cr.point(_lut(mo[2], so[2], ms[2], ss[2], match_spread=True))
    cb = _regional(cb, src_cb := src.convert("YCbCr").split()[1])
    cr = _regional(cr, src.convert("YCbCr").split()[2])
    del src_cb
    matched = Image.merge("YCbCr", (y, cb, cr)).convert("RGB")
    if strength < 1.0:
        matched = Image.blend(out, matched, max(0.0, strength))
    b = io.BytesIO()
    matched.save(b, "JPEG", quality=94)
    return b.getvalue()


def chroma_distance(a_bytes: bytes, b_bytes: bytes) -> float:
    """Mean Cb/Cr difference (0..255) — used by tests / verification."""
    def m(bb):
        im = Image.open(io.BytesIO(bb)).convert("RGB"); im.thumbnail((256, 256))
        return ImageStat.Stat(im.convert("YCbCr")).mean
    x, y = m(a_bytes), m(b_bytes)
    return (abs(x[1] - y[1]) + abs(x[2] - y[2])) / 2


def _low(ch: Image.Image, size) -> Image.Image:
    small = ch.resize((REGION_GRID, REGION_GRID), Image.Resampling.BOX)
    return small.resize(size, Image.Resampling.BILINEAR)


# v11.41: the regional correction per area is limited to ±this (0..255), so a
# strong background colour in a grid cell can't tint a small subject inside it.
REGION_MAX_SHIFT = 10


def _regional(out_ch: Image.Image, src_ch: Image.Image) -> Image.Image:
    """out + clamp(low(src) - low(out)): source low-frequency colour, output
    detail; the shift is capped (v11.41) so background colour can't leak."""
    size = out_ch.size
    diff = ImageChops.subtract(_low(src_ch, size), _low(out_ch, size), scale=1.0, offset=128)
    m = REGION_MAX_SHIFT
    diff = diff.point([max(128 - m, min(128 + m, v)) for v in range(256)])
    return ImageChops.add(out_ch, diff, scale=1.0, offset=-128)


def regional_chroma_spread(bb: bytes) -> float:
    """Max difference (0..255) of grid-averaged Cb/Cr across the image —
    0 for uniform colour (tests: "golden top on silver")."""
    im = Image.open(io.BytesIO(bb)).convert("YCbCr")
    worst = 0.0
    for ch in im.split()[1:]:
        g = ch.resize((4, 4), Image.Resampling.BOX)
        lo, hi = g.getextrema()
        worst = max(worst, float(hi - lo))
    return worst


def soften_chroma(jpg: bytes, radius: float = 1.5) -> bytes:
    """v11.39 Macro input clean-up: blur only Cb/Cr (colour noise of phone
    crops at the optical limit); luma detail untouched."""
    im = Image.open(io.BytesIO(jpg)).convert("YCbCr")
    y, cb, cr = im.split()
    cb = cb.filter(ImageFilter.GaussianBlur(radius))
    cr = cr.filter(ImageFilter.GaussianBlur(radius))
    out = io.BytesIO()
    Image.merge("YCbCr", (y, cb, cr)).convert("RGB").save(out, "JPEG", quality=92)
    return out.getvalue()
