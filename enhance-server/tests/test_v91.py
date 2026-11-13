"""v9.1: fast looks (downscale, medium, JPEG), timeouts, no-image/refusal
handling, safety list, parallel top-ups, needs_person. All mocked."""
import base64
import io

import httpx
from PIL import Image

import main
import prompts as P
from test_server import account, jpeg, png_b64  # noqa: F401
from test_v9 import PW, apply, env, login  # noqa: F401


def balance(c, dev):
    return c.get("/v1/account", params={"device_id": dev}).json()["total"]


def test_look_upload_is_1536_medium_jpeg_single_call(env):
    c, _, up = env
    r = c.post("/v1/looks/apply",
               data={"device_id": "dev_v91_1", "custom_prompt": "black suit", "quality": "4k"},
               files={"image": ("big.jpg", jpeg(4000, 3000), "image/jpeg")})
    assert r.status_code == 200, r.text
    assert len(up.calls) == 1  # 4 variations OFF → exactly one upstream call
    p = up.calls[0]
    assert p["quality"] == "medium" and p["output_format"] == "jpeg" and p["n"] == 1
    sent = Image.open(io.BytesIO(base64.b64decode(p["input_references"][0]["image_url"]["url"].split(",", 1)[1])))
    assert max(sent.size) == 1536
    # 4K custom change is clamped to Full HD: 2 credits, not 8.
    assert r.json()["credits_charged"] == 2


def test_hd_custom_change_uses_low(env):
    c, _, up = env
    assert apply(c, custom="black suit", quality="hd").status_code == 200
    assert up.calls[-1]["quality"] == "low"


def test_upstream_timeout_is_504_and_not_charged(env, monkeypatch):
    c, _, up = env

    async def slow(payload):
        up.calls.append(payload)
        raise httpx.ReadTimeout("timed out")

    monkeypatch.setattr(main, "call_openrouter", slow)
    before = balance(c, "dev_v91_2")
    r = apply(c, dev="dev_v91_2", custom="black suit", quality="full_hd")
    assert r.status_code == 504
    assert r.json()["detail"]["reason"] == "timeout"
    assert balance(c, "dev_v91_2") == before


def test_text_only_answer_is_502_no_image_not_charged(env, monkeypatch):
    c, _, _ = env

    async def text_only(payload):
        return 200, {"data": [], "output_text": "There is no person in this photo."}

    monkeypatch.setattr(main, "call_openrouter", text_only)
    before = balance(c, "dev_v91_3")
    r = apply(c, dev="dev_v91_3", custom="black suit", quality="full_hd")
    assert r.status_code == 502 and r.json()["detail"]["reason"] == "no_image"
    assert balance(c, "dev_v91_3") == before
    # Same for a library style (trial stays unused).
    r = apply(c, dev="dev_v91_3", style_id="paris_eiffel")
    assert r.status_code == 502
    assert "library_style" in c.get("/v1/account", params={"device_id": "dev_v91_3"}).json()["trials_available"]


def test_moderation_refusal_is_reported_as_refused(env, monkeypatch):
    c, _, _ = env

    async def refuse(payload):
        return 400, {"error": {"code": "moderation_blocked", "message": "blocked by safety system"}}

    monkeypatch.setattr(main, "call_openrouter", refuse)
    r = apply(c, dev="dev_v91_4", custom="a hat", quality="hd")
    assert r.status_code == 502 and r.json()["detail"]["reason"] == "refused"


def test_blocked_custom_prompt_never_reaches_the_ai(env):
    c, _, up = env
    for bad in ["make her naked", "face swap me with my friend", "add gore"]:
        r = apply(c, dev="dev_v91_5", custom=bad, quality="hd")
        assert r.status_code == 400 and r.json()["detail"]["reason"] == "blocked", bad
    assert up.calls == []
    for ok in ["black suit", "make the sky purple", "turn my cat into a tiger"]:
        assert not P.blocked_custom_prompt(ok)
    assert P.MAX_CUSTOM_PROMPT_CHARS == 200


def test_variations_top_up_in_parallel(env, monkeypatch):
    c, store, _ = env
    s = store.get("paris_eiffel")
    s.model = "custom"  # v11.58: Flare path (Klein is always one per call)
    store.upsert(s)
    ns = []

    async def one_image(payload):
        ns.append(payload["n"])
        return 200, {"data": [{"b64_json": png_b64(60, 80)}], "usage": {"cost": 0.01}}

    monkeypatch.setattr(main, "call_openrouter", one_image)
    c.post("/v1/purchase", json={"device_id": "dev_v91_6", "product_id": "pack_25"})
    r = apply(c, dev="dev_v91_6", style_id="paris_eiffel", variations=4)
    assert r.status_code == 200, r.text
    assert ns == [4, 1, 1, 1] and len(r.json()["images"]) == 4
    assert r.json()["credits_charged"] == 8


def test_needs_person_flag_public_and_admin_editable(env):
    c, store, _ = env
    js = c.get("/v1/styles").json()["styles"]
    assert all(s["needs_person"] is True for s in js)
    login(c)
    s = store.get("swiss_alps")
    r = c.post(f"/admin/styles/{s.id}", data={
        "name": s.name, "category": s.category, "prompt": s.prompt,
        "credit_cost": str(s.credit_cost), "sort_order": str(s.sort_order), "enabled": "1",
    }, follow_redirects=False)
    assert r.status_code == 303
    assert store.get("swiss_alps").needs_person is False
    flags = {x["id"]: x["needs_person"] for x in c.get("/v1/styles").json()["styles"]}
    assert flags["swiss_alps"] is False and flags["paris_eiffel"] is True


def test_enhance_timeout_504_not_charged(env, monkeypatch):
    c, _, _ = env

    async def slow(payload):
        raise httpx.ReadTimeout("timed out")

    monkeypatch.setattr(main, "call_openrouter", slow)
    before = balance(c, "dev_v91_7")
    r = c.post("/v1/enhance", data={"device_id": "dev_v91_7", "quality": "hd"},
               files={"image": ("c.jpg", jpeg(), "image/jpeg")})
    assert r.status_code == 504 and r.json()["detail"]["reason"] == "timeout"
    assert balance(c, "dev_v91_7") == before
