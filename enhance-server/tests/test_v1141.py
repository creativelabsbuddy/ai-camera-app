"""v11.41: no background colour tint — prompt line + capped regional shift."""
import io
from PIL import Image
import color_match as CM
import prompts as P

LINE = "do not let the background colour tint the subject"


def test_prompt_line_general():
    assert LINE in P.MACRO_MICROSCOPE_PHOTO_PROMPT
    for t in (P.MACRO_PROMPT, P.MACRO_CLOSE_PROMPT, P.MACRO_MICROSCOPE_PHOTO_PROMPT):
        assert "subject's own natural colours" in t  # v11.42
        for w in ("peanut", "purple", "cloth"):
            assert w not in t.lower()


def _jpg(im):
    b = io.BytesIO(); im.save(b, "JPEG", quality=95); return b.getvalue()


def test_regional_shift_capped():
    assert CM.REGION_MAX_SHIFT == 10
    src = Image.new("RGB", (64, 64), (150, 60, 170))  # strong coloured source
    out = Image.new("RGB", (64, 64), (200, 170, 120))  # natural-coloured result
    res = Image.open(io.BytesIO(CM.match_colors(_jpg(out), _jpg(src)))).convert("YCbCr")
    assert res.size == (64, 64)
