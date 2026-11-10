import base64
import io

from PIL import Image

import image_guard as G
import main
import prompts as P
from test_v11 import env, scene, enc  # noqa: F401  (fixture + helpers)

FINAL = enc(scene(2400, 1800))


def _post(c, dev, n_steps=2):
    steps = [("steps", (f"s{i}.jpg", enc(scene(seed=i + 2)), "image/jpeg")) for i in range(n_steps)]
    return c.post("/v1/enhance", data={"device_id": dev, "quality": "hd", "zoom": "100",
                                       "optical_limit": "1", "zoom_ladder": "true"},
                  files=[("image", ("i.jpg", FINAL, "image/jpeg"))] + steps)


def test_final_first_1536_refs_after(env):
    c, _, _, up = env
    c.post("/v1/purchase", json={"device_id": "dev_v1131a", "product_id": "pack_25"})
    up.reply = FINAL
    r = _post(c, "dev_v1131a")
    assert r.status_code == 200, r.text
    pl = up.calls[-1]
    assert pl["prompt"] == P.ZOOM_LADDER_PROMPT
    refs = pl["input_references"]
    first = Image.open(io.BytesIO(base64.b64decode(refs[0]["image_url"]["url"].split(",", 1)[1])))
    assert max(first.size) == 1536 and len(refs) == 3
    assert float(r.headers["x-structure"]) >= G.FRAMING_MIN


def test_reference_framing_rejected_not_charged(env):
    c, _, _, up = env
    c.post("/v1/purchase", json={"device_id": "dev_v1131b", "product_id": "pack_25"})
    before = c.get("/v1/account", params={"device_id": "dev_v1131b"}).json()
    up.reply = enc(scene(seed=9).transpose(Image.ROTATE_180))  # a different framing
    r = _post(c, "dev_v1131b")
    assert r.status_code == 422, r.text
    d = r.json()["detail"]
    assert d["reason"] == "framing_changed"
    assert d["message"] == "Couldn't enhance this zoom — credit refunded"
    assert c.get("/v1/account", params={"device_id": "dev_v1131b"}).json() == before


def test_framing_similarity_values():
    im = scene(480, 360)
    a = enc(im)
    assert G.framing_similarity(a, a) > 0.95
    shifted = enc(im.transform((480, 360), Image.AFFINE, (1, 0, 8, 0, 1, 5)))
    assert G.framing_similarity(a, shifted) >= G.FRAMING_MIN
    # The v11.30 bug: the result came back with a reference's WIDE framing.
    full = scene(1920, 1440)
    zoomed = full.crop((720, 540, 1200, 900)).resize((960, 720))
    assert G.framing_similarity(enc(zoomed), enc(full)) < G.FRAMING_MIN
    assert G.framing_similarity(enc(zoomed), enc(zoomed.resize((480, 360)))) > 0.9


def test_version():
    assert tuple(map(int, main.app.version.split("."))) >= (11, 1, 26)
