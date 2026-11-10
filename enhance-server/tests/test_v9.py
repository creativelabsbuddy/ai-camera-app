"""v9: AI style library, looks apply, admin panel, night flag (all mocked)."""
import base64
import io

import pytest
from fastapi.testclient import TestClient
from PIL import Image

import admin
import ledger as L
import main
import prompts as P
from test_server import T0, Upstream, account, enhance, jpeg, png_b64  # noqa: F401

PW = "s3cret-test-pass"


@pytest.fixture()
def env(tmp_path, monkeypatch):
    main.reset_ledger(str(tmp_path / "ledger.sqlite3"))
    store = main.reset_styles(str(tmp_path / "styles.sqlite3"), str(tmp_path / "media" / "styles"))
    clock = {"now": T0}
    monkeypatch.setattr(main, "now_utc", lambda: clock["now"])
    up = Upstream()
    monkeypatch.setattr(main, "call_openrouter", up)
    monkeypatch.setenv("ALLOW_TEST_PURCHASES", "1")
    monkeypatch.setenv("ADMIN_PASSWORD", PW)
    admin._fails.clear()
    return TestClient(main.app), store, up


def apply(c, dev="dev_look_1", style_id=None, custom=None, variations=1, quality=None):
    data = {"device_id": dev, "variations": str(variations)}
    if style_id:
        data["style_id"] = style_id
    if custom:
        data["custom_prompt"] = custom
    if quality:
        data["quality"] = quality
    return c.post("/v1/looks/apply", data=data, files={"image": ("me.jpg", jpeg(), "image/jpeg")})


def login(c, pw=PW):
    return c.post("/admin/login", data={"password": pw}, follow_redirects=False)


# -- public catalogue -------------------------------------------------------
def test_styles_endpoint_hides_prompts_and_refs(env):
    c, store, _ = env
    r = c.get("/v1/styles")
    assert r.status_code == 200
    js = r.json()
    assert len(js["styles"]) == 12 and js["version"]
    raw = r.text
    for s in store.list(include_disabled=True):
        assert s.prompt[:30] not in raw
    assert "prompt" not in raw and "ref_images" not in raw
    first = js["styles"][0]
    assert set(first) == {"id", "name", "category", "credit_cost", "pro_only", "sort_order",
                          "image_url", "has_reference", "needs_person", "kind", "ui_category",
                          "sample_before_url", "sample_after_url"}
    img = c.get(first["image_url"])
    assert img.status_code == 200 and img.headers["content-type"] == "image/jpeg"


def test_disabled_styles_hidden_and_not_applicable(env):
    c, store, up = env
    s = store.get("santorini")
    s.enabled = False
    store.upsert(s)
    ids = [x["id"] for x in c.get("/v1/styles").json()["styles"]]
    assert "santorini" not in ids and len(ids) == 11
    assert apply(c, style_id="santorini").status_code == 404
    assert up.calls == []


def test_media_route_rejects_traversal(env):
    c, _, _ = env
    assert c.get("/media/styles/..%2Fstyles.sqlite3").status_code == 404
    assert c.get("/media/styles/nope.jpg").status_code == 404


# -- apply + credits --------------------------------------------------------
def test_apply_style_cost_only_on_success(env):
    c, store, up = env
    # v11.57: 1st apply on a free device charges style cost (no free trial).
    r = apply(c, style_id="paris_eiffel")
    assert r.status_code == 200, r.text
    js = r.json()
    assert js["credits_charged"] == 2 and js["trials_used"] == []
    assert len(js["images"]) == 1
    out = Image.open(io.BytesIO(base64.b64decode(js["images"][0])))
    assert max(out.size) == 800  # v9.1: looks are NOT upscaled (model native size)
    # Hidden prompt composed server-side with the identity wrapper.
    sent = up.calls[-1]["prompt"]
    assert sent.startswith(P.LOOK_IDENTITY_PROMPT) and store.get("paris_eiffel").prompt in sent
    assert P.LOCKED_ENHANCE_PROMPT not in sent
    assert up.calls[-1]["quality"] == "medium" and up.calls[-1]["resolution"] == "1.5K"
    assert account(c, "dev_look_1")["state"]["free_daily"] == 0
    # Out of credits → 402, no upstream call.
    n = len(up.calls)
    r = apply(c, style_id="paris_eiffel")
    assert r.status_code == 402 and r.json()["detail"]["reason"] == "no_credits"
    assert len(up.calls) == n
    # Pack credits → success; failure charges nothing.
    c.post("/v1/purchase", json={"device_id": "dev_look_1", "product_id": "pack_25"})
    up.mode = "fail"
    assert apply(c, style_id="paris_eiffel").status_code == 502
    assert account(c, "dev_look_1")["state"]["pack_credits"] == 25
    up.mode = "ok"
    r = apply(c, style_id="paris_eiffel")
    assert r.json()["credits_charged"] == 2 and r.json()["trials_used"] == []
    assert account(c, "dev_look_1")["state"]["pack_credits"] == 23


def test_style_cost_uses_admin_value(env):
    c, store, _ = env
    c.post("/v1/purchase", json={"device_id": "dev_look_1", "product_id": "pack_25"})
    s = store.get("silk_saree")
    s.credit_cost = 5
    store.upsert(s)
    r = apply(c, style_id="silk_saree")
    assert r.json()["credits_charged"] == 5
    st = account(c, "dev_look_1")["state"]
    assert st["free_daily"] + st["pack_credits"] == 2 + 25 - 5  # no free trial


def test_pro_only_style_needs_pro(env):
    c, _, up = env
    r = apply(c, style_id="royal_sherwani")
    assert r.status_code == 402 and r.json()["detail"]["reason"] == "style_needs_pro"
    assert up.calls == []
    c.post("/v1/purchase", json={"device_id": "dev_look_1", "product_id": "pro_monthly"})
    r = apply(c, style_id="royal_sherwani")
    assert r.status_code == 200 and r.json()["credits_charged"] == 3
    assert r.json()["trials_used"] == []  # Pro never burns trials


def test_variations_cost_4x_and_partial_results_charged_per_image(env):
    c, _, up = env
    c.post("/v1/purchase", json={"device_id": "dev_look_1", "product_id": "pack_25"})
    # Fake upstream returns 1 image per call → server tops up with single calls.
    r = apply(c, style_id="black_suit", variations=4)
    js = r.json()
    assert len(js["images"]) == 4 and js["credits_charged"] == 8 and js["trials_used"] == []
    assert up.calls[0]["n"] == 4 and len(up.calls) == 4
    # Only 2 of 4 came back → charged for 2 images only, trial untouched.
    calls = {"n": 0}

    async def flaky(payload):
        calls["n"] += 1
        if calls["n"] <= 2:
            return 200, {"data": [{"b64_json": png_b64(600, 800)}], "usage": {"cost": 0.02}}
        return 500, {"error": "down"}

    main.call_openrouter = flaky  # restored by monkeypatch fixture teardown
    r = apply(c, dev="dev_look_2", style_id="diwali_lights", variations=4)
    assert r.status_code == 402  # free device: 2 credits < 8 needed up front
    c.post("/v1/purchase", json={"device_id": "dev_look_2", "product_id": "pack_25"})
    r = apply(c, dev="dev_look_2", style_id="diwali_lights", variations=4)
    js = r.json()
    assert len(js["images"]) == 2 and js["credits_charged"] == 4 and js["trials_used"] == []
    assert "library_style" in account(c, "dev_look_2")["trials_available"]


def test_custom_change_free_users_pay_tier_credits(env):
    c, _, up = env
    r = apply(c, custom="make my shirt red", quality="hd")
    assert r.status_code == 200
    js = r.json()
    assert js["credits_charged"] == 1 and js["trials_used"] == []  # custom never uses the style trial
    sent = up.calls[-1]["prompt"]
    assert "Requested change: make my shirt red" in sent and sent.startswith(P.LOOK_IDENTITY_PROMPT)
    r = apply(c, custom="x", quality="full_hd")
    assert r.status_code == 402  # 1 credit left < 2
    assert apply(c).status_code == 400  # neither style nor prompt


def test_reference_images_sent_after_user_photo(env):
    c, store, up = env
    s = store.get("dubai_skyline")
    s.ref_images = [store.save_image(jpeg(500, 500, (0, 0, 255)), private=True)]
    store.upsert(s)
    r = apply(c, style_id="dubai_skyline")
    assert r.json()["references_used"] == 1
    refs = up.calls[-1]["input_references"]
    assert len(refs) == 2
    assert P.LOOK_REFERENCE_SENTENCE in up.calls[-1]["prompt"]
    # The user photo is first.
    first = Image.open(io.BytesIO(base64.b64decode(refs[0]["image_url"]["url"].split(",", 1)[1])))
    assert first.size == (300, 400)
    # Reference files are never public.
    assert c.get(f"/media/styles/{s.ref_images[0]}").status_code == 404


# -- night ------------------------------------------------------------------
def test_night_flag_appends_exact_prompt_after_locked(env):
    c, _, up = env
    r = enhance(c, night="true")
    assert r.status_code == 200 and r.headers["x-night"] == "1"
    p = up.calls[-1]["prompt"]
    assert p.startswith(P.LOCKED_ENHANCE_PROMPT + " " + P.NIGHT_PROMPT)
    assert r.headers["x-credits-charged"] == "1"  # night costs nothing extra
    enhance(c)
    assert P.NIGHT_PROMPT not in up.calls[-1]["prompt"]
    assert P.NIGHT_PROMPT.startswith("A natural night photograph")


# -- admin --------------------------------------------------------------------
def test_admin_requires_auth(env):
    c, _, _ = env
    for path in ["/admin", "/admin/styles/new", "/admin/styles/santorini/edit"]:
        r = c.get(path, follow_redirects=False)
        assert r.status_code == 303 and r.headers["location"] == "/admin/login", path
    r = c.post("/admin/styles/santorini/delete", follow_redirects=False)
    assert r.status_code == 303
    assert c.get("/v1/styles").json()["styles"][0]  # nothing deleted
    assert any(s["id"] == "santorini" for s in c.get("/v1/styles").json()["styles"])
    # Wrong password → no cookie; forged cookie rejected.
    r = login(c, "wrong")
    assert "admin_session" not in r.cookies
    c.cookies.set("admin_session", "9999999999.deadbeef", path="/admin")
    assert c.get("/admin", follow_redirects=False).status_code == 303


def test_admin_disabled_without_password(env, monkeypatch):
    c, _, _ = env
    monkeypatch.delenv("ADMIN_PASSWORD")
    assert c.get("/admin", follow_redirects=False).status_code == 503
    assert login(c, "").status_code == 503


def test_admin_login_throttled(env):
    c, _, _ = env
    for _ in range(admin.MAX_FAILS):
        login(c, "bad")
    assert login(c, PW).status_code == 429


def test_admin_crud_flow(env):
    c, store, _ = env
    r = login(c)
    assert r.status_code == 303 and r.headers["location"] == "/admin"
    page = c.get("/admin")
    assert page.status_code == 200 and "Santorini" in page.text and "no-store" in page.headers["cache-control"]
    # Create with display + 2 reference images.
    r = c.post("/admin/styles", data={
        "name": "Goa Beach", "category": "Travel", "prompt": "Place the person on a sunny Goa beach.",
        "credit_cost": "3", "sort_order": "0", "enabled": "1",
    }, files=[("display_image", ("d.jpg", jpeg(600, 800), "image/jpeg")),
              ("ref_images", ("r1.jpg", jpeg(300, 300, (1, 2, 3)), "image/jpeg")),
              ("ref_images", ("r2.jpg", jpeg(300, 300, (3, 2, 1)), "image/jpeg"))],
        follow_redirects=False)
    assert r.status_code == 303, r.text
    s = store.get("goa_beach")
    assert s and s.credit_cost == 3 and len(s.ref_images) == 2 and s.display_image
    pub = {x["id"]: x for x in c.get("/v1/styles").json()["styles"]}
    assert pub["goa_beach"]["has_reference"] and "Goa beach" not in c.get("/v1/styles").text
    assert c.get(f"/admin/ref/{s.ref_images[0]}").status_code == 200  # admin can preview refs
    # Edit: remove one ref, Pro only, disable.
    r = c.post("/admin/styles/goa_beach", data={
        "name": "Goa Beach", "category": "Travel", "prompt": "Sunny Goa beach.", "credit_cost": "4",
        "sort_order": "0", "pro_only": "1", "remove_refs": s.ref_images[0],
    }, follow_redirects=False)
    assert r.status_code == 303
    s2 = store.get("goa_beach")
    assert s2.pro_only and not s2.enabled and s2.credit_cost == 4 and s2.ref_images == s.ref_images[1:]
    assert "goa_beach" not in [x["id"] for x in c.get("/v1/styles").json()["styles"]]
    # Move up / down.
    order = [x.id for x in store.list(include_disabled=True)]
    c.post(f"/admin/styles/{order[1]}/move", data={"direction": "-1"})
    assert [x.id for x in store.list(include_disabled=True)][0] == order[1]
    # Delete removes row + files.
    disp = store.path_for(s2.display_image)
    c.post("/admin/styles/goa_beach/delete")
    assert store.get("goa_beach") is None and store.path_for(s2.display_image) is None and disp
    # Logout.
    c.post("/admin/logout")
    c.cookies.clear()
    assert c.get("/admin", follow_redirects=False).status_code == 303


def test_admin_rejects_non_image_upload(env):
    c, _, _ = env
    login(c)
    r = c.post("/admin/styles", data={"name": "Bad", "category": "Mood", "prompt": "x", "enabled": "1"},
               files=[("display_image", ("x.jpg", b"not an image", "image/jpeg"))], follow_redirects=False)
    assert r.status_code == 400


def test_look_rules_unit():
    s = L.State.initial(T0)
    d = L.decide_look(s, L.LookSpec(credit_cost=2), T0)
    assert d.allowed and d.trials == () and d.from_free == 2 and d.credits == 2
    d = L.decide_look(s, L.LookSpec(credit_cost=2, variations=4), T0)
    assert not d.allowed and d.reason == "no_credits"  # 8 > 2 free
    d = L.decide_look(s, L.LookSpec(credit_cost=1, is_style=False), T0)
    assert d.allowed and d.from_free == 1 and d.trials == ()
    assert L.decide_look(s, L.LookSpec(credit_cost=2, variations=5), T0).reason == "bad_request"
    assert L.decide_look(s, L.LookSpec(credit_cost=2, pro_only=True), T0).reason == "style_needs_pro"
