"""v11.42: framing-preserving prompts; colour match skip + global cap."""
import io
from PIL import Image
import color_match as CM
import prompts as P


def _jpg(c):
    b = io.BytesIO(); Image.new("RGB", (32, 32), c).save(b, "JPEG", quality=95); return b.getvalue()


def test_prompts():
    for t in (P.MACRO_PROMPT, P.MACRO_CLOSE_PROMPT):
        assert "same framing" in t
        assert "strongly zoomed" not in t and "filling the frame" not in t
    assert "strongly zoomed in" in P.MACRO_MICROSCOPE_PHOTO_PROMPT
    assert "zoomed centre" not in P.MACRO_CONTEXT_LINE


def test_colour_skip_and_cap():
    assert CM.skip_match([128, 100, 160], [128, 128, 128])
    assert not CM.skip_match([128, 126, 130], [128, 128, 128])
    assert CM.GLOBAL_MAX_SHIFT == 10
    far = _jpg((60, 170, 60))
    assert CM.match_colors(far, _jpg((190, 200, 60))) == far
