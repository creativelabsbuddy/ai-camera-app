"""v11.66: Microscope / Extreme / Ultra zoom-gate photos (micro_steps)."""
import prompts as P
from tests.test_v11 import env, enc, scene  # noqa: F401


def _shot(c, dev, level, micro_steps, n_steps=2):
    data = {"device_id": dev, "quality": "hd", "zoom": "12", "optical_limit": "4",
            "mode": "macro", "macro_level": level, "subject": "red soda can",
            "part": "side of a red soda can"}
    if micro_steps:
        data["micro_steps"] = "true"
    steps = [("steps", (f"s{i}.jpg", enc(scene(seed=i + 2)), "image/jpeg"))
             for i in range(n_steps)]
    return c.post("/v1/enhance", data=data,
                  files=[("image", ("i.jpg", enc(scene()), "image/jpeg"))] + steps)


def test_gate_photos_sent_with_steps_line(env):
    c, _, _, up = env
    for level in ("microscope", "extreme", "ultra"):
        dev = f"dev_v1166_{level}"
        c.post("/v1/purchase", json={"device_id": dev, "product_id": "pack_25"})
        assert _shot(c, dev, level, True).status_code == 200
        pl = up.calls[-1]
        assert pl["prompt"].startswith(P.MICRO_STEPS_LINE)
        assert "side of a red soda can" in pl["prompt"]
        # 2 gate photos + the final frame
        assert len(pl.get("input_references") or []) == 3


def test_old_clients_unchanged(env):
    c, _, _, up = env
    c.post("/v1/purchase", json={"device_id": "dev_v1166b", "product_id": "pack_25"})
    assert _shot(c, "dev_v1166b", "extreme", False).status_code == 200
    pl = up.calls[-1]
    assert not pl.get("input_references")  # text-only spot prompt as before
    assert not pl["prompt"].startswith(P.MICRO_STEPS_LINE)
