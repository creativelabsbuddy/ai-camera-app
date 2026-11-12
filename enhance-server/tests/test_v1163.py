"""v11.63: Phosor-only video, simple enhance prompts, last-photo zoom path."""
import os
import re

import prompts as P
import video_providers as VP
from tests.test_v11 import env, enc, scene  # noqa: F401
from tests.test_v1130 import _post  # noqa: F401


PHOTO = "Clean up and sharpen this image, with a natural tone."
PORTRAIT = (
    "Clean up and sharpen this image, with a natural tone. "
    "Blur only the background with a natural bokeh, and keep the subject sharp."
)


def test_credit_table_and_route():
    t = VP.credit_table()
    assert t["minimax_5_480p"] == 3
    assert t["minimax_5_768p"] == 7
    assert (t["minimax_8_480p"], t["minimax_10_480p"], t["minimax_15_480p"]) == (7, 9, 13)
    assert (t["minimax_8_768p"], t["minimax_10_768p"], t["minimax_15_768p"]) == (11, 13, 20)
    assert VP.route("t2v", "p", 5, "480p", "9:16").provider == VP.MINIMAX
    assert VP.route("i2v", "p", 5, "768p", "9:16").provider == VP.MINIMAX
    assert VP.provisional_credits(0.57 * 5) == 5  # formula would be 5; we hard-set 3


def test_no_8scale_api_in_providers():
    src = open(os.path.join(os.path.dirname(__file__), "..", "video_providers.py"), encoding="utf-8").read()
    assert "8scale.run" not in src
    assert "/wan-2.2/" not in src
    assert "EIGHTSCALE" not in src
    assert "phosor.ai" in src
    # HMAC still mixes both keys so in-flight job ids verify.
    assert "_key(WAN) + _key(MINIMAX)" in src


def test_prompt_strings_exact_and_parity():
    assert P.UNIVERSAL_ENHANCE_PROMPT == PHOTO
    assert P.ZOOM_CLEAN_PROMPT == PHOTO
    assert P.PORTRAIT_ENHANCE_PROMPT == PORTRAIT
    assert P.PORTRAIT_PROMPT == PORTRAIT
    dart = open(os.path.join(os.path.dirname(__file__), "..", "..", "ai_camera",
                             "lib", "services", "prompt_builder.dart"), encoding="utf-8").read()
    m = re.search(r"const String kUniversalEnhancePrompt =\s*((?:'[^']*'\s*)+);", dart)
    assert "".join(re.findall(r"'([^']*)'", m.group(1))) == P.UNIVERSAL_ENHANCE_PROMPT
    assert "const String kZoomCleanPrompt = kUniversalEnhancePrompt;" in dart
    mp = open(os.path.join(os.path.dirname(__file__), "..", "..", "ai_camera",
                           "lib", "services", "mode_prompts.dart"), encoding="utf-8").read()
    assert PORTRAIT in mp


def test_photo_zoom_uses_simple_prompt(env):
    c, _, _, up = env
    up.reply = enc(scene(1200, 900), "PNG")
    r = _post(c, "dev_v1163a", {"zoom": "80", "optical_limit": "2", "zoom_clean": "true",
                                "mode": "photo"}, 0)
    assert r.status_code == 200, r.text
    assert up.calls[-1]["prompt"] == PHOTO


def test_portrait_at_high_zoom_uses_bokeh_prompt_not_photo(env):
    c, _, _, up = env
    r = _post(c, "dev_v1163b", {"zoom": "100", "optical_limit": "2", "zoom_clean": "true",
                                "mode": "portrait"}, 0)
    assert r.status_code == 200, r.text
    assert up.calls[-1]["prompt"] == PORTRAIT
    assert up.calls[-1]["prompt"] != PHOTO


def test_1x_photo_uses_simple_prompt(env):
    c, _, _, up = env
    r = _post(c, "dev_v1163c", {"zoom": "1", "optical_limit": "1", "mode": "photo"}, 0)
    assert r.status_code == 200, r.text
    assert up.calls[-1]["prompt"] == PHOTO
