"""v11.59 sharp-source zoom parity + zoom output check (fake upstream only)."""
import base64
import io

from PIL import Image

import image_guard as G
import main
import prompts as P
from test_v11 import env, scene, enc  # noqa: F401  (fixture + helpers)


def _post(c, dev, data, image: bytes, steps: list[bytes]):
    c.post("/v1/purchase", json={"device_id": dev, "product_id": "pack_25"})
    files = [("image", ("i.jpg", image, "image/jpeg"))] + [
        ("steps", (f"s{i}.jpg", b, "image/jpeg")) for i, b in enumerate(steps)]
    return c.post("/v1/enhance", data={"device_id": dev, "quality": "hd", **data}, files=files)


def _imgs(pl):
    return [Image.open(io.BytesIO(base64.b64decode(r["image_url"]["url"].split(",", 1)[1])))
            for r in pl["input_references"]]


def test_version():
    assert main.app.version == "11.1.59"


def test_prompts_safe_and_match_app():
    import os
    import re
    assert P.ZOOM_CLEAN_PROMPT == P.UNIVERSAL_ENHANCE_PROMPT
    assert P.ZOOM_SOURCE_PROMPT.startswith("The first image is a sharp photo")
    assert "only to match the framing" in P.ZOOM_SOURCE_PROMPT
    path = os.path.join(os.path.dirname(__file__), "..", "..", "ai_camera", "lib", "services",
                        "prompt_builder.dart")
    src = open(path, encoding="utf-8").read()
    m = re.search(r"const String kZoomSourcePrompt =\s*\n\s*'((?:[^'\\]|\\.)*)';", src)
    assert m.group(1).replace("\\'", "'") == P.ZOOM_SOURCE_PROMPT
    assert P.zoom_source_prompt("oil", None) == P.ZOOM_SOURCE_PROMPT + " Style: oil"


def test_source_first_final_second(env):
    c, _, _, up = env
    source = scene(600, 450, seed=4)
    final = scene(1200, 900, seed=4).resize((1200, 900))
    up.reply = enc(source, "PNG")
    r = _post(c, "dev_v1159a", {"zoom": "30", "optical_limit": "2", "zoom_source": "true"},
              enc(source), [enc(final)])
    assert r.status_code == 200, r.text
    pl = up.calls[-1]
    assert pl["prompt"] == P.ZOOM_SOURCE_PROMPT
    ims = _imgs(pl)
    assert len(ims) == 2
    assert max(ims[0].size) == 600          # the sharp source (native, ≤1536)
    assert max(ims[1].size) == P.ZOOM_FRAMING_LONG  # the final, framing only


def test_source_without_framing_fails_closed_no_call_no_charge(env):
    c, _, _, up = env
    n = len(up.calls)
    r = _post(c, "dev_v1159b", {"zoom": "30", "optical_limit": "2", "zoom_source": "true"},
              enc(scene(600, 450)), [])
    assert r.status_code == 422
    assert r.json()["detail"]["reason"] == "no_sharp_source"
    assert len(up.calls) == n  # no AI call (rejected before the ledger decides → no charge)


def test_changed_zoom_result_rejected_against_source(env):
    c, _, _, up = env
    source = scene(600, 450, seed=4)
    up.reply = enc(Image.new("RGB", (600, 450), (250, 20, 200)), "PNG")
    r = _post(c, "dev_v1159c", {"zoom": "30", "optical_limit": "2", "zoom_source": "true"},
              enc(source), [enc(scene(1200, 900, seed=4))])
    assert r.status_code == 422
    assert r.json()["detail"]["reason"] == "structure_changed"
    # flagship single-photo zoom too
    r = _post(c, "dev_v1159c", {"zoom": "20", "optical_limit": "3", "zoom_clean": "true"},
              enc(source), [])
    assert r.status_code == 422
    assert r.json()["detail"]["reason"] == "structure_changed"


def test_zoom_output_ok_unit():
    a = enc(scene(400, 300, seed=2))
    assert G.zoom_output_ok(a, enc(scene(400, 300, seed=2), "PNG"))[0]
    assert not G.zoom_output_ok(a, enc(Image.new("RGB", (400, 300), (0, 255, 0)), "PNG"))[0]
    # a chosen look may change colours (structure still checked)
    tinted = Image.eval(scene(400, 300, seed=2), lambda v: min(255, v + 120))
    assert G.zoom_output_ok(a, enc(tinted, "PNG"), check_colour=False)[0]
