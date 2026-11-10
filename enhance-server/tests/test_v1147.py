"""v11.47: Microscope = detect, then 100x text-only; no spot → photo flow."""
import prompts as P
from tests.test_v11 import env, enc, scene  # noqa: F401


def test_prompt_and_rule():
    assert "{spot}" in P.MACRO_MICROSCOPE_PROMPT and "100x" in P.MACRO_MICROSCOPE_PROMPT
    assert "1000x" in P.MACRO_EXTREME_PROMPT
    assert P.macro_text_only("microscope", "close-up", "tiny hairs")
    assert not P.macro_text_only("microscope", "close-up", None)
    t = P.macro_prompt(P.MACRO_MICROSCOPE_PROMPT, "close-up", "microscope", part="tiny hairs")
    assert "tiny hairs" in t and "{spot}" not in t
    assert P.macro_prompt(P.MACRO_MICROSCOPE_PROMPT, "close-up", "microscope") \
        == P.MACRO_MICROSCOPE_PHOTO_PROMPT
    # an old saved (photo) admin text still gives the 100x text prompt
    old = P.macro_prompt(P.MACRO_MICROSCOPE_PHOTO_PROMPT, None, "microscope", part="plant hairs")
    assert old.startswith("A tiny area of plant hairs")


def _shot(c, dev, part):
    data = {"device_id": dev, "quality": "hd", "zoom": "4", "optical_limit": "4",
            "mode": "macro", "macro_level": "microscope", "subject": "close-up"}
    if part:
        data["part"] = part
    steps = [("steps", ("s.jpg", enc(scene()), "image/jpeg"))]
    return c.post("/v1/enhance", data=data,
                  files=[("image", ("i.jpg", enc(scene()), "image/jpeg"))] + steps)


def test_text_only_and_fallback(env):
    c, _, _, up = env
    c.post("/v1/purchase", json={"device_id": "dev_v1147", "product_id": "pack_25"})
    assert _shot(c, "dev_v1147", "tiny hairs").status_code == 200
    pl = up.calls[-1]
    assert "tiny hairs" in pl["prompt"] and "100x" in pl["prompt"]
    assert not pl.get("input_references")
    assert _shot(c, "dev_v1147", None).status_code == 200
    pl = up.calls[-1]
    assert pl["prompt"] == P.MACRO_MICROSCOPE_PHOTO_PROMPT
    assert pl.get("input_references")
