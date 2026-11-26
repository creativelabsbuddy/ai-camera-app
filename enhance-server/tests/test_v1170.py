"""v11.70: one Pro AI enhance tier — Flare low, 1 credit, no upscale (no
Real-ESRGAN, no Lanczos), the Ultra HD detail line in the prompt. Old app
tiers (full_hd / ultra_hd / 4k) map to it. Zoom mode keeps Sunburst.
Mocked — no real API calls."""
import io
import os

from PIL import Image

import ledger as L
import main
import prompts as P
from test_server import APP, _dart_string_const
from test_v11 import enc, env, scene, enhance  # noqa: F401

SUNBURST = "openai/gpt-image-2.5-sunburst"
FLARE = "openai/gpt-image-2.5-flare"


def _buy(c, dev):
    r = c.post("/v1/purchase", json={"device_id": dev, "product_id": "pack_25"})
    assert r.status_code == 200, r.text


def test_flag_defaults_on():
    assert L.SINGLE_TIER is True
    assert L.ENHANCE_TIER == "hd"
    assert main.UPSCALE_TIERS == {}
    assert L.TIERS["hd"] == ("HD", 1, "low", "1K", 1024)


def test_enhance_tier_mapping_pure():
    f = L.enhance_tier
    for q in ("hd", "full_hd", "ultra_hd", "4k"):
        assert f(q, "photo", single=True) == "hd"
        assert f(q, "portrait", single=True) == "hd"
        assert f(q, "night", single=True) == "hd"
    # Macro keeps its own HD / Full HD qualities.
    assert f("full_hd", "macro", single=True) == "full_hd"
    # Undo path (SINGLE_TIER=0): unchanged.
    assert f("ultra_hd", "photo", single=False) == "ultra_hd"
    assert f("weird", "photo", single=True) == "weird"


def test_prompt_line_and_dart_parity():
    assert P.SINGLE_TIER_SENTENCE == "Target a very detailed Ultra HD result with crisp fine texture."
    p = P.build_prompt(tier="hd", single_tier=True)
    assert p == P.UNIVERSAL_ENHANCE_PROMPT + " " + P.SINGLE_TIER_SENTENCE
    assert P.build_prompt(tier="hd") == P.UNIVERSAL_ENHANCE_PROMPT  # undo path
    path = os.path.join(APP, "lib", "services", "prompt_builder.dart")
    if not os.path.exists(path):
        import pytest
        pytest.skip("app source not present")
    src = open(path, encoding="utf-8").read()
    assert _dart_string_const(src, "kSingleTierSentence") == P.SINGLE_TIER_SENTENCE
    assert _dart_string_const(src, "kUniversalEnhancePrompt") == P.UNIVERSAL_ENHANCE_PROMPT


def test_old_app_tiers_charge_one_credit_flare_low_no_upscale(env, monkeypatch):  # noqa: F811
    c, _, _, up = env
    runware = []

    async def no_runware(tasks):
        runware.append(tasks)
        return 500, "should not be called"

    monkeypatch.setattr(main, "call_runware", no_runware)
    dev = "dev_v1170a"
    _buy(c, dev)
    up.reply = enc(scene(600, 800), "PNG")
    for q in ("hd", "full_hd", "ultra_hd", "4k"):
        r = enhance(c, enc(scene(600, 800)), dev=dev, quality=q)
        assert r.status_code == 200, (q, r.text)
        assert r.headers["X-Credits-Charged"] == "1", q
        assert r.headers.get("X-Trials-Used", "") == ""  # no UHD trial burnt
        pl = up.calls[-1]
        assert pl["model"] == FLARE
        assert pl["quality"] == "low" and pl["resolution"] == "1K"
        assert pl["prompt"].endswith(P.SINGLE_TIER_SENTENCE)
        assert pl["prompt"].count(P.SINGLE_TIER_SENTENCE) == 1
        # Delivered as Flare returned it (no upscale / resize).
        assert Image.open(io.BytesIO(r.content)).size == (600, 800)
    assert runware == []


def test_zoom_mode_keeps_sunburst_single_tier(env):  # noqa: F811
    from tests.test_v1130 import _post
    c, _, _, up = env
    up.reply = enc(scene(1200, 900), "PNG")
    r = _post(c, "dev_v1170z", {"zoom": "40", "optical_limit": "3", "zoom_clean": "true",
                                "quality": "full_hd"}, 0)
    assert r.status_code == 200, r.text
    pl = up.calls[-1]
    assert pl["model"] == SUNBURST
    assert pl["quality"] == "low"


def test_products_lists_the_enhance_tier(env):  # noqa: F811
    c, _, _, _ = env
    p = c.get("/v1/products").json()
    assert p["enhance_tier"] == "hd"
