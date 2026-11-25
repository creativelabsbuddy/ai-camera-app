"""v11.69: Zoom mode → GPT Image 2.5 Sunburst; Pro Photo Natural (Sunburst) /
Studio (Flare); everything else stays on Flare. App/server parity."""
import os
import re

import main
from test_server import APP
from test_v11 import enc, env, scene, enhance  # noqa: F401

SUNBURST = "openai/gpt-image-2.5-sunburst"
FLARE = "openai/gpt-image-2.5-flare"


def _buy(c, dev):
    r = c.post("/v1/purchase", json={"device_id": dev, "product_id": "pack_25"})
    assert r.status_code == 200, r.text


def test_constants_and_parity():
    assert main.MODEL == FLARE
    assert main.SUNBURST_MODEL == SUNBURST
    path = os.path.join(APP, "lib", "config", "ai_config.dart")
    if not os.path.exists(path):
        import pytest
        pytest.skip("app source not present")
    src = open(path, encoding="utf-8").read()
    assert re.search(r"sunburstModel\s*=\s*'openai/gpt-image-2\.5-sunburst'", src)
    assert re.search(r"String model\s*=\s*'openai/gpt-image-2\.5-flare'", src)


def test_model_router_pure(monkeypatch):
    f = main.enhance_model_for
    assert f("photo", True, None) == SUNBURST          # Zoom mode
    assert f("photo", True, "studio") == SUNBURST      # Zoom mode ignores the look
    assert f("photo", False, "natural") == SUNBURST
    assert f("photo", False, "NATURAL ") == SUNBURST
    assert f("photo", False, "studio") == FLARE
    assert f("photo", False, None) == FLARE            # older apps
    assert f("photo", False, "weird") == FLARE
    assert f("photo", False, "natural", has_filter=True) == FLARE  # AI filters unchanged
    for mode in ("portrait", "night", "macro"):
        assert f(mode, False, "natural") == FLARE
        assert f(mode, True, "natural") == FLARE
    monkeypatch.setattr(main, "ZOOM_SUNBURST", False)
    assert f("photo", True, None) == FLARE
    monkeypatch.setattr(main, "PRO_LOOK", False)
    assert f("photo", False, "natural") == FLARE


def test_zoom_clean_request_uses_sunburst(env):  # noqa: F811
    from tests.test_v1130 import _post
    c, _, _, up = env
    up.reply = enc(scene(1200, 900), "PNG")
    r = _post(c, "dev_v1169z", {"zoom": "20", "optical_limit": "3", "zoom_clean": "true"}, 0)
    assert r.status_code == 200, r.text
    pl = up.calls[-1]
    assert pl["model"] == SUNBURST
    # same payload as Flare: quality / resolution / n / jpeg / references
    assert pl["quality"] == "low" and pl["resolution"] == "1K"
    assert pl["n"] == 1 and pl["output_format"] == "jpeg"
    assert len(pl["input_references"]) == 1
    assert r.headers["X-Enhance-Model"] == SUNBURST


def test_pro_photo_natural_and_studio(env):  # noqa: F811
    c, _, _, up = env
    img = enc(scene(600, 800))
    _buy(c, "dev_v1169p")
    r = enhance(c, img, dev="dev_v1169p", photo_look="natural")
    assert r.status_code == 200, r.text
    assert up.calls[-1]["model"] == SUNBURST
    assert r.headers["X-Enhance-Model"] == SUNBURST
    natural_prompt = up.calls[-1]["prompt"]
    charged_n = r.headers["X-Credits-Charged"]

    r = enhance(c, img, dev="dev_v1169p", photo_look="studio")
    assert r.status_code == 200, r.text
    assert up.calls[-1]["model"] == FLARE
    assert up.calls[-1]["prompt"] == natural_prompt  # same prompt logic
    assert r.headers["X-Credits-Charged"] == charged_n  # same credits

    r = enhance(c, img, dev="dev_v1169p")  # older app → Flare
    assert r.status_code == 200, r.text
    assert up.calls[-1]["model"] == FLARE


def test_portrait_and_night_stay_flare(env):  # noqa: F811
    c, _, _, up = env
    _buy(c, "dev_v1169m")
    r = enhance(c, enc(scene(600, 800)), dev="dev_v1169m", mode="portrait",
                photo_look="natural")
    assert r.status_code == 200, r.text
    assert up.calls[-1]["model"] == FLARE
