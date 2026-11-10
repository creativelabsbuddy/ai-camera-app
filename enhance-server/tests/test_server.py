"""Server tests — all upstream calls are mocked (no real OpenRouter spend)."""
import base64
import datetime as dt
import io
import json
import os
import re

import pytest
from fastapi.testclient import TestClient
from PIL import Image

import ledger as L
import main
import prompts as P

UTC = dt.timezone.utc
T0 = dt.datetime(2026, 10, 7, 10, 0, tzinfo=UTC)  # 15:30 IST


def jpeg(w=300, h=400, color=(200, 100, 50)) -> bytes:
    b = io.BytesIO()
    Image.new("RGB", (w, h), color).save(b, "JPEG")
    return b.getvalue()


def png_b64(w, h) -> str:
    b = io.BytesIO()
    Image.new("RGB", (w, h), (10, 120, 200)).save(b, "PNG")
    return base64.b64encode(b.getvalue()).decode()


class Upstream:
    """Fake OpenRouter: records payloads, configurable behaviour."""

    def __init__(self):
        self.calls = []
        self.mode = "ok"  # ok | fail | reject_two

    async def __call__(self, payload):
        self.calls.append(payload)
        if self.mode == "fail":
            return 500, {"error": "upstream down"}
        if self.mode == "reject_two" and len(payload["input_references"]) == 2:
            return 400, {"error": "only one input image supported"}
        return 200, {"data": [{"b64_json": png_b64(600, 800)}], "usage": {"cost": 0.02}}


@pytest.fixture()
def env(tmp_path, monkeypatch):
    main.reset_ledger(str(tmp_path / "ledger.sqlite3"))
    main.reset_styles(str(tmp_path / "styles.sqlite3"), str(tmp_path / "media" / "styles"))
    clock = {"now": T0}
    monkeypatch.setattr(main, "now_utc", lambda: clock["now"])
    up = Upstream()
    monkeypatch.setattr(main, "call_openrouter", up)
    monkeypatch.setenv("ALLOW_TEST_PURCHASES", "1")
    return TestClient(main.app), clock, up


def enhance(client, dev="dev_test_1", ctx=True, **fields):
    files = {"image": ("crop.jpg", jpeg(), "image/jpeg")}
    if ctx:
        files["context"] = ("ctx.jpg", jpeg(150, 200), "image/jpeg")
    data = {"device_id": dev, "quality": "hd", "zoom": "1", "optical_limit": "5"}
    data.update({k: str(v) for k, v in fields.items()})
    return client.post("/v1/enhance", data=data, files=files)


def account(client, dev="dev_test_1"):
    r = client.get("/v1/account", params={"device_id": dev})
    assert r.status_code == 200
    return r.json()


# --------------------------------------------------------------------------
def test_health_and_products(env):
    c, _, _ = env
    assert c.get("/health").json()["ok"] is True
    p = c.get("/v1/products").json()
    ids = {x["id"]: x for x in p["products"]}
    assert ids["pro_monthly"]["price_inr"] == 99 and ids["pro_monthly"]["credits"] == 100
    assert (ids["pack_25"]["price_inr"], ids["pack_60"]["price_inr"], ids["pack_140"]["price_inr"]) == (49, 99, 199)
    assert [t["credits"] for t in p["tiers"]] == [1, 2, 4, 8]


def test_new_device_gets_two_free_hd(env):
    c, _, _ = env
    a = account(c)
    assert a["state"]["free_daily"] == 2 and a["total"] == 2
    assert a["trials_available"] == ["high_zoom", "ai_filter", "library_style", "uhd_4k"]


def test_deduct_only_on_success(env):
    c, _, up = env
    up.mode = "fail"
    r = enhance(c)
    assert r.status_code == 502
    assert account(c)["state"]["free_daily"] == 2  # nothing charged
    up.mode = "ok"
    r = enhance(c)
    assert r.status_code == 200, r.text
    assert r.headers["x-credits-charged"] == "1"
    assert account(c)["state"]["free_daily"] == 1
    # Header carries the new state for the app.
    hdr = json.loads(base64.urlsafe_b64decode(r.headers["x-account"] + "=="))
    assert hdr["free_daily"] == 1


def test_daily_reset_ist_no_rollover(env):
    c, clock, _ = env
    assert enhance(c).status_code == 200
    assert enhance(c).status_code == 200
    r = enhance(c)
    assert r.status_code == 402 and r.json()["detail"]["reason"] == "no_credits"
    clock["now"] = dt.datetime(2026, 10, 7, 18, 29, tzinfo=UTC)  # 23:59 IST
    assert account(c)["state"]["free_daily"] == 0
    clock["now"] = dt.datetime(2026, 10, 7, 18, 30, tzinfo=UTC)  # 00:00 IST
    a = account(c)
    assert a["state"]["free_daily"] == 2 and a["date_ist"] == "2026-10-08"
    # Skip days without using: still 2 (no stacking).
    clock["now"] = dt.datetime(2026, 10, 12, 6, 0, tzinfo=UTC)
    assert account(c)["state"]["free_daily"] == 2


def test_two_images_sent_with_context_sentence(env):
    c, _, up = env
    r = enhance(c, zoom=15, optical_limit=5, quality="hd")
    # 15x > optical 5 → free user's one-time high-zoom trial (free shot).
    assert r.status_code == 200
    assert r.headers["x-trials-used"] == "high_zoom"
    assert r.headers["x-credits-charged"] == "0"
    assert r.headers["x-context-used"] == "1"
    p = up.calls[-1]
    assert len(p["input_references"]) == 2
    assert P.CONTEXT_IMAGE_SENTENCE in p["prompt"]
    assert p["prompt"].startswith(P.LOCKED_ENHANCE_PROMPT)
    assert "carefully recover" in p["prompt"]  # 3x over optical
    assert (p["quality"], p["resolution"]) == ("low", "1K")


def test_two_image_rejection_falls_back(env):
    c, _, up = env
    up.mode = "reject_two"
    r = enhance(c)
    assert r.status_code == 200
    assert r.headers["x-context-used"] == "0"
    assert [len(x["input_references"]) for x in up.calls] == [2, 1]
    assert P.CONTEXT_IMAGE_SENTENCE not in up.calls[-1]["prompt"]
    assert account(c)["state"]["free_daily"] == 1  # charged once


def test_trial_once_only_then_pro_only(env):
    c, _, up = env
    assert enhance(c, zoom=30).headers["x-trials-used"] == "high_zoom"
    r = enhance(c, zoom=30)
    assert r.status_code == 402 and r.json()["detail"]["reason"] == "zoom_needs_pro"
    n = len(up.calls)
    assert enhance(c, zoom=30).status_code == 402
    assert len(up.calls) == n  # denied → no upstream spend
    # Failed attempt must not burn a trial.
    up.mode = "fail"
    assert enhance(c, filter_id="studio").status_code == 502
    assert "ai_filter" in account(c)["trials_available"]
    up.mode = "ok"
    assert enhance(c, filter_id="studio").headers["x-trials-used"] == "ai_filter"
    assert enhance(c, filter_id="studio").json()["detail"]["reason"] == "filter_needs_pro"
    r = enhance(c, quality="4k")
    assert r.headers["x-trials-used"] == "uhd_4k"
    assert enhance(c, quality="4k").json()["detail"]["reason"] == "no_credits"
    # Trials are per device.
    assert enhance(c, dev="other_device", zoom=30).headers["x-trials-used"] == "high_zoom"


def test_pro_purchase_zoom_and_expiry(env):
    c, clock, up = env
    a = c.post("/v1/purchase", json={"device_id": "dev_test_1", "product_id": "pro_monthly"}).json()
    assert a["is_pro"] and a["state"]["sub_credits"] == 100 and a["test_mode"]
    r = enhance(c, zoom=50, quality="ultra_hd")
    assert r.status_code == 200
    assert r.headers["x-trials-used"] == ""  # Pro never burns trials
    assert r.headers["x-credits-charged"] == "4"  # cost = tier only, not zoom
    assert account(c)["state"]["sub_credits"] == 96
    # Expiry drops unused sub credits (no rollover).
    clock["now"] = T0 + dt.timedelta(days=31)
    a = account(c)
    assert not a["is_pro"] and a["state"]["sub_credits"] == 0


def test_packs_pay_premium_tiers(env):
    c, _, _ = env
    c.post("/v1/purchase", json={"device_id": "dev_test_1", "product_id": "pack_25"})
    r = enhance(c, quality="full_hd")
    assert r.headers["x-credits-charged"] == "2"
    a = account(c)
    assert a["state"]["pack_credits"] == 23 and a["state"]["free_daily"] == 2


def test_output_upscaled_to_tier_target(env):
    c, _, _ = env
    c.post("/v1/purchase", json={"device_id": "dev_test_1", "product_id": "pack_25"})
    r = enhance(c, quality="full_hd")
    im = Image.open(io.BytesIO(r.content))
    assert max(im.size) >= 1920


def test_purchase_validation_and_test_mode_switch(env, monkeypatch):
    c, _, _ = env
    assert c.post("/v1/purchase", json={"device_id": "dev_test_1", "product_id": "nope"}).status_code == 400
    assert c.get("/v1/account", params={"device_id": "../etc"}).status_code == 400
    monkeypatch.setenv("ALLOW_TEST_PURCHASES", "0")
    assert c.post("/v1/purchase", json={"device_id": "dev_test_1", "product_id": "pack_25"}).status_code == 403


def test_legacy_endpoint_disabled_by_default(env):
    c, _, _ = env
    r = c.post("/enhance", files={"photo": ("a.jpg", jpeg(), "image/jpeg")})
    assert r.status_code == 410


def test_exif_orientation_baked_no_stretch():
    im = Image.new("RGB", (400, 300), (1, 2, 3))
    exif = im.getexif()
    exif[0x0112] = 6  # rotate 90
    b = io.BytesIO()
    im.save(b, "JPEG", exif=exif)
    out, w, h = main.prepare(b.getvalue(), 2048)
    assert (w, h) == (300, 400)
    assert main.aspect_for(w, h) == "3:4"


# -- rules parity with the Flutter app ------------------------------------
APP = os.path.join(os.path.dirname(__file__), "..", "..", "ai_camera")


def _dart_string_const(src: str, name: str) -> str:
    m = re.search(rf"const String {name} =\s*((?:'(?:[^'\\]|\\.)*'\s*)+);", src)
    assert m, name
    return "".join(re.findall(r"'((?:[^'\\]|\\.)*)'", m.group(1))).replace("\\'", "'")


def test_locked_prompt_matches_app():
    path = os.path.join(APP, "lib", "services", "prompt_builder.dart")
    if not os.path.exists(path):
        pytest.skip("app source not present")
    src = open(path, encoding="utf-8").read()
    assert _dart_string_const(src, "kLockedEnhancePrompt") == P.LOCKED_ENHANCE_PROMPT
    assert _dart_string_const(src, "kContextImageSentence") == P.CONTEXT_IMAGE_SENTENCE


def test_night_and_look_prompts_match_app():
    path = os.path.join(APP, "lib", "services", "prompt_builder.dart")
    if not os.path.exists(path):
        pytest.skip("app source not present")
    src = open(path, encoding="utf-8").read()
    assert _dart_string_const(src, "kNightPrompt") == P.NIGHT_PROMPT
    assert _dart_string_const(src, "kLookIdentityPrompt") == P.LOOK_IDENTITY_PROMPT
    assert _dart_string_const(src, "kLookReferenceSentence") == P.LOOK_REFERENCE_SENTENCE
    assert _dart_string_const(src, "kLookTailSentence") == P.LOOK_TAIL_SENTENCE


def test_seed_styles_match_app_bundle():
    """App bundle: same ids/costs, but NO prompts. Test-only key builds carry
    the seed prompts in local_style_prompts.dart (must equal the server's)."""
    here = os.path.join(os.path.dirname(__file__), "..")
    server = json.load(open(os.path.join(here, "seed_styles.json"), encoding="utf-8"))["styles"]
    path = os.path.join(APP, "assets", "styles", "seed_styles.json")
    if not os.path.exists(path):
        pytest.skip("app source not present")
    app_raw = open(path, encoding="utf-8").read()
    bundle = json.loads(app_raw)["styles"]
    assert [s["id"] for s in bundle] == [s["id"] for s in server]
    assert [s["credit_cost"] for s in bundle] == [s["credit_cost"] for s in server]
    assert all("prompt" not in s for s in bundle)
    for s in server:
        assert s["prompt"][:40] not in app_raw
    dart = open(os.path.join(APP, "lib", "services", "local_style_prompts.dart"), encoding="utf-8").read()
    pairs = dict(re.findall(r"'([a-z0-9_]+)':\s*\n?\s*'((?:[^'\\]|\\.)*)'", dart))
    assert {k: v.replace("\\'", "'") for k, v in pairs.items()} == {s["id"]: s["prompt"] for s in server}


def test_ist_date_and_rules_unit():
    assert L.ist_date(dt.datetime(2026, 10, 7, 18, 29, 59, tzinfo=UTC)) == "2026-10-07"
    assert L.ist_date(dt.datetime(2026, 10, 7, 18, 30, tzinfo=UTC)) == "2026-10-08"
    s = L.State.initial(T0)
    d = L.decide(s, L.Spec(tier="hd", zoom=5, optical_limit=5), T0)
    assert d.allowed and d.trials == () and d.from_free == 1  # at optical: no trial
    s2 = L.apply_purchase(L.apply_purchase(s, "pro_monthly", T0), "pro_monthly", T0 + dt.timedelta(days=10))
    assert s2.sub_credits == 100 and s2.pro_until == T0 + dt.timedelta(days=60)


def test_v11_mode_prompts_match_app_test_copy():
    """Test-key builds carry a copy of the hidden v11 prompts (mode_prompts.dart)."""
    path = os.path.join(APP, "lib", "services", "mode_prompts.dart")
    if not os.path.exists(path):
        pytest.skip("app source not present")
    src = open(path, encoding="utf-8").read()
    assert _dart_string_const(src, "kPortraitPrompt") == P.PORTRAIT_PROMPT
    assert _dart_string_const(src, "kMacroPrompt") == P.MACRO_PROMPT
    assert _dart_string_const(src, "kMacroHintLine") == P.MACRO_HINT_LINE
    assert _dart_string_const(src, "kMacroHintParentOnly") == P.MACRO_HINT_PARENT_ONLY
    assert _dart_string_const(src, "kDetectModel") == P.DETECT_MODEL
    assert _dart_string_const(src, "kDetectSubjectPrompt") == P.DETECT_SUBJECT_PROMPT
    assert _dart_string_const(src, "kDetectPartPrompt") == P.DETECT_PART_PROMPT
    assert _dart_string_const(src, "kDetectSpotPrompt") == P.DETECT_SPOT_PROMPT
    assert _dart_string_const(src, "kMacroClosePrompt") == P.MACRO_CLOSE_PROMPT
    assert _dart_string_const(src, "kMacroExtremePrompt") == P.MACRO_EXTREME_PROMPT
    assert _dart_string_const(src, "kMacroUltraPrompt") == P.MACRO_ULTRA_PROMPT
    assert _dart_string_const(src, "kMacroMicroscopePrompt") == P.MACRO_MICROSCOPE_PROMPT  # v11.47
    assert _dart_string_const(src, "kDetectSubjectPrompt") == P.DETECT_SUBJECT_PROMPT
    assert _dart_string_const(src, "kMacroMicroscopePhotoPrompt") == P.MACRO_MICROSCOPE_PHOTO_PROMPT
    assert _dart_string_const(src, "kColorFilterTail") == P.COLOR_FILTER_TAIL
    assert _dart_string_const(src, "kDetectDeviceRule") == P.DETECT_DEVICE_RULE  # v11.22
    pb = open(os.path.join(APP, "lib", "services", "prompt_builder.dart"), encoding="utf-8").read()
    assert _dart_string_const(pb, "kContextBoxedSentence") == P.CONTEXT_BOXED_SENTENCE
    assert _dart_string_const(pb, "kHighZoomClarity") == P.HIGH_ZOOM_CLARITY
    for k, v in P.COLOR_FILTER_PROMPTS.items():
        assert _dart_string_const(src, f"kColorPrompt_{k}") == v
