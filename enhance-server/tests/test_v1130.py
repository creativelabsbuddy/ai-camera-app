import asyncio

import main
import prompts as P
from test_v11 import env, scene, enc  # noqa: F401  (fixture + helpers)


def _post(c, dev, data, n_steps):
    steps = [("steps", (f"s{i}.jpg", enc(scene(seed=i + 2)), "image/jpeg")) for i in range(n_steps)]
    c.post("/v1/purchase", json={"device_id": dev, "product_id": "pack_25"})
    return c.post("/v1/enhance", data={"device_id": dev, "quality": "hd", **data},
                  files=[("image", ("i.jpg", enc(scene(1200, 900)), "image/jpeg"))] + steps)


def _sizes(pl):
    from PIL import Image
    import base64
    import io
    out = []
    for r in pl["input_references"]:
        b = base64.b64decode(r["image_url"]["url"].split(",", 1)[1])
        out.append(max(Image.open(io.BytesIO(b)).size))
    return out


def test_extreme_and_ultra_send_no_photo(env):
    c, _, _, up = env
    for level in ("extreme", "ultra"):
        r = _post(c, "dev_v1130a", {"zoom": "25", "optical_limit": "25", "mode": "macro",
                                    "macro_level": level, "subject": "leaf",
                                    "part": "green leaf veins"}, 2)
        assert r.status_code == 200, r.text
        pl = up.calls[-1]
        assert "input_references" not in pl
        assert "green leaf veins" in pl["prompt"]
        assert pl["aspect_ratio"] == "4:3"  # still from the uploaded crop


def test_build_payload_text_only():
    p = main.build_payload("hi", "hd", "1:1", None, None)
    assert "input_references" not in p and p["prompt"] == "hi"


def test_mock_handles_text_only(monkeypatch):
    monkeypatch.setenv("ENHANCE_MOCK", "1")
    st, body = asyncio.run(main.call_openrouter(main.build_payload("x", "hd", "1:1", None, None)))
    assert st == 200 and body["data"][0]["b64_json"]


def test_zoom_ladder_one_call_refs_first_final_last(env):
    c, _, _, up = env
    n0 = len(up.calls)
    up.reply = enc(scene(1200, 900))  # v11.31: result keeps the final framing
    r = _post(c, "dev_v1130b", {"zoom": "40", "optical_limit": "1", "zoom_ladder": "true"}, 4)
    assert r.status_code == 200, r.text
    assert len(up.calls) - n0 == 1
    pl = up.calls[-1]
    assert pl["prompt"] == P.ZOOM_LADDER_PROMPT
    refs = pl["input_references"]
    assert len(refs) == 4  # ≤3 references + the final photo
    sz = _sizes(pl)
    assert sz[0] == 1200 and all(s <= 768 for s in sz[1:])  # v11.31: final first, native
    assert r.headers["x-context-used"] == "1"


def test_zoom_ladder_flag_ignored_without_steps_or_in_macro(env):
    c, _, _, up = env
    up.reply = enc(scene(1200, 900), "PNG")  # v11.59 output check: keeps the photo
    r = _post(c, "dev_v1130c", {"zoom": "40", "optical_limit": "1", "zoom_ladder": "true"}, 0)
    assert r.status_code == 200
    assert up.calls[-1]["prompt"] == P.ZOOM_CLEAN_PROMPT  # v11.34: final only
    r = _post(c, "dev_v1130c", {"zoom": "3", "optical_limit": "3", "mode": "macro",
                                "macro_level": "macro", "zoom_ladder": "true"}, 2)
    assert r.status_code == 200
    assert P.ZOOM_LADDER_PROMPT not in up.calls[-1]["prompt"]


def test_ladder_prompt_simple_and_version():
    assert P.ZOOM_LADDER_PROMPT.startswith(P.ZOOM_CLEAN_PROMPT)  # v11.59
    assert P.zoom_ladder_prompt(None, None) == P.ZOOM_LADDER_PROMPT
    assert tuple(map(int, main.app.version.split("."))) >= (11, 1, 25)
