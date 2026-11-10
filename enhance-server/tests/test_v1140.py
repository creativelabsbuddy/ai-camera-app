"""v11.40: macro context photos; Extreme / Ultra never refuse without a spot."""
import prompts as P
from tests.test_v11 import env, enc, scene  # noqa: F401


def _post(c, level, subject=None, part=None, n_steps=2):
    data = {"device_id": "dev_v1140", "quality": "hd", "zoom": "5", "optical_limit": "5",
            "mode": "macro", "macro_level": level}
    if subject:
        data["subject"] = subject
    if part:
        data["part"] = part
    steps = [("steps", (f"s{i}.jpg", enc(scene()), "image/jpeg")) for i in range(n_steps)]
    return c.post("/v1/enhance", data=data,
                  files=[("image", ("i.jpg", enc(scene()), "image/jpeg"))] + steps)


def test_context_line_general():
    t = P.MACRO_CONTEXT_LINE
    assert "{subject}" not in t and "wider context" in t


def test_close_sends_context_photos(env):
    c, _, _, up = env
    c.post("/v1/purchase", json={"device_id": "dev_v1140", "product_id": "pack_25"})
    r = _post(c, "close")
    assert r.status_code == 200, r.text
    pl = up.calls[-1]
    assert len(pl.get("input_references", [])) == 3
    assert P.MACRO_CONTEXT_LINE in pl["prompt"]


def test_extreme_without_spot_sends_photo(env):
    c, _, _, up = env
    c.post("/v1/purchase", json={"device_id": "dev_v1140", "product_id": "pack_25"})
    r = _post(c, "extreme")
    assert r.status_code == 200, r.text
    assert len(up.calls[-1].get("input_references", [])) == 3
    r = _post(c, "extreme", subject="skin", part="pores")
    assert r.status_code == 200, r.text
    assert len(up.calls[-1].get("input_references", [])) == 0
