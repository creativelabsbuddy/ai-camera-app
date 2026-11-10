"""v11: pose photo library, hidden Pro AI prompts (admin), mode / color filter
params, Pro Night darkness gate + structure guard (all mocked, no real AI)."""
import base64
import io
import os
import random

import pytest
from fastapi.testclient import TestClient
from PIL import Image, ImageDraw

import admin
import image_guard as G
import main
import mode_prompts as MP
import poses as PO
import prompts as P
from test_server import T0, Upstream, account  # noqa: F401

PW = "s3cret-test-pass"
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def scene(w=480, h=360, dark=False, extra=False, seed=1) -> Image.Image:
    """A synthetic street: sky, buildings with lit windows, a road."""
    rnd = random.Random(seed)
    im = Image.new("RGB", (w, h), (10, 14, 40))
    d = ImageDraw.Draw(im)
    for i in range(6):
        x = 20 + i * 75
        top = 80 + rnd.randint(0, 90)
        d.rectangle([x, top, x + 60, h - 90], fill=(50, 45, 60))
        for wy in range(top + 10, h - 100, 22):
            for wx in range(x + 8, x + 55, 16):
                if rnd.random() < 0.5:
                    d.rectangle([wx, wy, wx + 7, wy + 10], fill=(255, 210, 120))
    d.rectangle([0, h - 90, w, h], fill=(35, 35, 38))
    d.line([0, h - 45, w, h - 45], fill=(200, 200, 160), width=3)
    if extra:  # invented pillars + ground pattern
        for x in range(0, w, 40):
            d.rectangle([x, 40, x + 14, h], fill=(220, 220, 220))
        for y in range(0, h, 30):
            d.line([0, y, w, y + 60], fill=(255, 255, 255), width=4)
    if dark:
        im = im.point(lambda v: v // 40)
    return im


def enc(im: Image.Image, fmt="JPEG") -> bytes:
    b = io.BytesIO()
    im.save(b, fmt, quality=92) if fmt == "JPEG" else im.save(b, fmt)
    return b.getvalue()


def noise_black(w=400, h=300, seed=3) -> bytes:
    rnd = random.Random(seed)
    im = Image.new("L", (w, h))
    im.putdata([max(0, min(255, int(rnd.gauss(3, 2)))) for _ in range(w * h)])
    return enc(im.convert("RGB"))


class SceneUpstream(Upstream):
    """Returns a configurable image (default: brightened version of the input)."""

    def __init__(self):
        super().__init__()
        self.reply = None

    async def __call__(self, payload):
        self.calls.append(payload)
        if self.mode == "fail":
            return 500, {"error": "upstream down"}
        img = self.reply if self.reply is not None else enc(scene(), "PNG")
        return 200, {"data": [{"b64_json": base64.b64encode(img).decode()}], "usage": {"cost": 0.02}}


@pytest.fixture()
def env(tmp_path, monkeypatch):
    main.reset_ledger(str(tmp_path / "ledger.sqlite3"))
    main.reset_styles(str(tmp_path / "styles.sqlite3"), str(tmp_path / "media" / "styles"))
    store = main.reset_poses(str(tmp_path / "poses.sqlite3"), str(tmp_path / "media" / "poses"), seed=False)
    prompts = main.reset_mode_prompts(str(tmp_path / "mp.sqlite3"))
    clock = {"now": T0}
    monkeypatch.setattr(main, "now_utc", lambda: clock["now"])
    up = SceneUpstream()
    monkeypatch.setattr(main, "call_openrouter", up)
    monkeypatch.setenv("ADMIN_PASSWORD", PW)
    monkeypatch.setenv("ALLOW_TEST_PURCHASES", "1")
    admin._fails.clear()
    return TestClient(main.app), store, prompts, up


def login(c):
    r = c.post("/admin/login", data={"password": PW}, follow_redirects=False)
    assert r.status_code == 303


def enhance(c, img: bytes, dev="dev_v11", **fields):
    data = {"device_id": dev, "quality": "hd", "zoom": "1", **fields}
    return c.post("/v1/enhance", data=data, files={"image": ("x.jpg", img, "image/jpeg")})


def photo_jpeg(w=600, h=800) -> bytes:
    return enc(scene(w, h))


# == poses ==================================================================
def test_seed_json_and_files_are_consistent():
    import json
    js = json.load(open(os.path.join(HERE, "seed_poses.json")))
    poses = js["poses"]
    assert 20 <= len(poses) <= 30
    cats = {p["category"] for p in poses}
    assert cats == set(PO.CATEGORIES)
    for p in poses:
        path = os.path.join(HERE, "seed_poses", p["file"])
        assert os.path.exists(path), p["file"]
        im = Image.open(path)
        assert im.format == "JPEG" and max(im.size) <= 1080
        assert p["credit"] and p["source_url"].startswith("https://www.pexels.com/")


def test_seeded_store_lists_photos(tmp_path):
    store = main.reset_poses(str(tmp_path / "p.sqlite3"), str(tmp_path / "m"))
    c = TestClient(main.app)
    js = c.get("/v1/poses").json()
    assert len(js["poses"]) == store.count() >= 20
    first = js["poses"][0]
    assert set(first) == {"id", "name", "category", "photo_url", "credit", "sort_order"}
    img = c.get(first["photo_url"])
    assert img.status_code == 200 and img.headers["content-type"] == "image/jpeg"
    # Seeding again is a no-op.
    assert store.seed_if_empty(os.path.join(HERE, "seed_poses.json"), os.path.join(HERE, "seed_poses")) == 0


def test_store_validation():
    with pytest.raises(ValueError):
        PO.clean_source_url("javascript:alert(1)")
    assert PO.clean_source_url(" https://x.org/a ") == "https://x.org/a"
    assert PO.clean_source_url("") == ""


def test_unknown_category_rejected(env):
    _, store, _, _ = env
    with pytest.raises(ValueError):
        store.upsert(PO.Pose(id="x", name="X", category="Dance", photo="a" * 32 + ".jpg"))


def test_pose_admin_requires_login(env):
    c, _, _, _ = env
    for path in ["/admin/poses", "/admin/poses/new", "/admin/prompts"]:
        r = c.get(path, follow_redirects=False)
        assert r.status_code == 303 and r.headers["location"] == "/admin/login"
    r = c.post("/admin/poses", data={"name": "x", "category": "Standing"}, follow_redirects=False)
    assert r.status_code == 303 and r.headers["location"] == "/admin/login"
    r = c.post("/admin/prompts/save", data={"key": "night", "prompt": "x"}, follow_redirects=False)
    assert r.status_code == 303 and r.headers["location"] == "/admin/login"


def test_pose_admin_add_edit_move_delete(env):
    c, store, _, up = env
    login(c)
    page = c.get("/admin/poses")
    assert page.status_code == 200 and "Add pose photo" in page.text and "/admin/prompts" in page.text
    form = c.get("/admin/poses/new").text
    for cat in PO.CATEGORIES:
        assert f'value="{cat}"' in form
    # Photo is required for a new pose.
    r = c.post("/admin/poses", data={"name": "Empty", "category": "Standing"})
    assert r.status_code == 200 and "Add a photo" in r.text
    r = c.post("/admin/poses", data={"name": "Junk", "category": "Sitting"},
               files={"photo": ("p.jpg", b"not an image", "image/jpeg")})
    assert r.status_code == 200 and "Bad photo" in r.text
    r = c.post("/admin/poses", data={"name": "Bad", "category": "Dance"},
               files={"photo": ("p.jpg", photo_jpeg(), "image/jpeg")})
    assert r.status_code == 400
    r = c.post("/admin/poses", data={"name": "X", "category": "Travel", "source_url": "ftp://x"},
               files={"photo": ("p.jpg", photo_jpeg(), "image/jpeg")})
    assert r.status_code == 200 and store.count() == 0
    assert store.list(include_disabled=True) == []
    # Add two (an RGBA PNG gets flattened to JPEG and downscaled).
    big = Image.new("RGBA", (2400, 3200), (0, 0, 0, 0))
    r = c.post("/admin/poses", data={"name": "Lean on wall", "category": "Standing", "enabled": "1",
                                     "credit": "Photo: A / Pexels", "source_url": "https://www.pexels.com/photo/1/",
                                     "sort_order": "1"},
               files={"photo": ("p.png", enc(big, "PNG"), "image/png")}, follow_redirects=False)
    assert r.status_code == 303
    r = c.post("/admin/poses", data={"name": "Cafe chair", "category": "Sitting", "enabled": "1",
                                     "sort_order": "2"},
               files={"photo": ("p.jpg", photo_jpeg(), "image/jpeg")}, follow_redirects=False)
    assert r.status_code == 303
    a, b = store.list(include_disabled=True)
    assert a.id == "srv_lean_on_wall" and a.photo.endswith(".jpg")
    stored = Image.open(store.path_for(a.photo))
    assert stored.mode == "RGB" and max(stored.size) <= 1280
    pub = c.get("/v1/poses").json()["poses"]
    assert [p["id"] for p in pub] == [a.id, b.id]
    assert pub[0]["credit"] == "Photo: A / Pexels"
    # Move b up.
    c.post(f"/admin/poses/{b.id}/move", data={"direction": "-1"})
    assert [p.id for p in store.list(include_disabled=True)] == [b.id, a.id]
    # Edit: disable a and rename; keep photo.
    r = c.post(f"/admin/poses/{a.id}", data={"name": "Wall", "category": "Casual", "sort_order": "5"},
               follow_redirects=False)
    assert r.status_code == 303
    a2 = store.get(a.id)
    assert a2.name == "Wall" and a2.category == "Casual" and not a2.enabled and a2.photo == a.photo
    assert [p["id"] for p in c.get("/v1/poses").json()["poses"]] == [b.id]
    # Replace photo removes the old file.
    old = store.path_for(a.photo)
    c.post(f"/admin/poses/{a.id}", data={"name": "Wall", "category": "Casual", "enabled": "1"},
           files={"photo": ("p.jpg", photo_jpeg(), "image/jpeg")})
    assert store.get(a.id).photo != a.photo and not os.path.exists(old)
    # Delete removes the file too.
    path = store.path_for(store.get(b.id).photo)
    r = c.post(f"/admin/poses/{b.id}/delete", follow_redirects=False)
    assert r.status_code == 303 and store.get(b.id) is None and not os.path.exists(path)
    assert up.calls == []  # poses never touch the AI


def test_pose_media_rejects_traversal(env):
    c, _, _, _ = env
    for name in ["../poses.sqlite3", "x.jpg", "%2e%2e%2fsecret.jpg"]:
        assert c.get(f"/media/poses/{name}").status_code == 404


# == hidden prompts ==========================================================
def test_default_prompts_content():
    assert P.LOCKED_ENHANCE_PROMPT.startswith("Enhance this photo so it looks like it was shot on a professional DSLR")  # v11.58
    assert "cells" not in P.LOCKED_ENHANCE_PROMPT
    port = P.PORTRAIT_PROMPT.lower()
    for k in ["subject", "sharp", "hair", "finger", "bokeh", "do not add"]:
        assert k in port, k
    night = P.NIGHT_PROMPT.lower()
    for k in ["night", "noise", "shadow", "do not add"]:
        assert k in night, k
    assert set(P.COLOR_FILTER_PROMPTS) == {"vivid", "rich_contrast", "warm_gold", "cool_clean", "cinematic",
                                           "film", "moody_dark", "soft_pastel", "bright_airy", "pro_bw"}
    for bad in ["anime", "cartoon", "ghibli", "sketch", "oil painting"]:
        assert all(bad not in v.lower() for v in P.DEFAULT_MODE_PROMPTS.values())


def test_mode_prompt_store(tmp_path):
    st = MP.ModePromptStore(str(tmp_path / "x.sqlite3"))
    assert st.get("night") == P.NIGHT_PROMPT and st.overridden("night") is None
    st.set("night", "Custom night text.")
    assert st.get("night") == "Custom night text."
    st.set("macro", "no placeholder")  # v11.12: no placeholder required
    assert st.get("macro") == "no placeholder"
    st.reset("macro")
    with pytest.raises(ValueError):
        st.set("nope", "x")
    with pytest.raises(ValueError):
        st.set("portrait", "   ")
    with pytest.raises(ValueError):
        st.set("portrait", "x" * 2001)
    st.reset("night")
    assert st.get("night") == P.NIGHT_PROMPT


def test_prompt_admin_edit_and_reset(env):
    c, _, store, up = env
    login(c)
    page = c.get("/admin/prompts")
    assert page.status_code == 200 and "Pro Night" in page.text and "Color filter · Warm Gold" in page.text
    r = c.post("/admin/prompts/save", data={"key": "portrait", "prompt": "Blur only the background."},
               follow_redirects=False)
    assert r.status_code == 303
    assert store.get("portrait") == "Blur only the background."
    assert "custom" in c.get("/admin/prompts").text
    r = c.post("/admin/prompts/save", data={"key": "macro", "prompt": "no placeholder"})
    assert r.status_code in (200, 303) and store.get("macro") == "no placeholder"
    store.reset("macro")
    # The edited prompt is what the AI receives.
    r = enhance(c, photo_jpeg(), mode="portrait")
    assert r.status_code == 200, r.text
    # v11.58: the (edited) Portrait variant REPLACES the universal base.
    assert up.calls[-1]["prompt"].startswith("Blur only the background.")
    assert P.UNIVERSAL_ENHANCE_PROMPT not in up.calls[-1]["prompt"]
    c.post("/admin/prompts/reset", data={"key": "portrait"})
    assert store.get("portrait") == P.PORTRAIT_PROMPT
    assert c.post("/admin/prompts/reset", data={"key": "bad"}).status_code == 400


# == /v1/enhance modes ======================================================
def test_portrait_mode_charges_tier_credits(env):
    c, _, _, up = env
    c.post("/v1/purchase", json={"device_id": "dev_v11", "product_id": "pack_25"})
    before = account(c, "dev_v11")["total"]
    r = enhance(c, photo_jpeg(), mode="portrait", quality="full_hd")
    assert r.status_code == 200, r.text
    assert r.headers["x-mode"] == "portrait" and r.headers["x-night"] == "0"
    p = up.calls[-1]["prompt"]
    assert p.startswith(P.PORTRAIT_ENHANCE_PROMPT) and P.UNIVERSAL_ENHANCE_PROMPT not in p  # v11.58
    assert "x-structure" not in r.headers
    assert r.headers["x-credits-charged"] == "2"  # Pro AI tier credits (Full HD = 2)
    assert before - account(c, "dev_v11")["total"] == 2


def test_color_filter_prompt_and_validation(env):
    c, _, _, up = env
    r = enhance(c, photo_jpeg(), color_filter="cinematic")
    assert r.status_code == 200, r.text
    p = up.calls[-1]["prompt"]
    assert p.startswith(P.LOCKED_ENHANCE_PROMPT)
    assert P.COLOR_FILTER_PROMPTS["cinematic"] in p and P.COLOR_FILTER_TAIL in p
    n = len(up.calls)
    assert enhance(c, photo_jpeg(), color_filter="anime").status_code == 400
    assert enhance(c, photo_jpeg(), mode="dance").status_code == 400
    assert len(up.calls) == n


def test_plain_photo_has_no_mode_text(env):
    c, _, _, up = env
    r = enhance(c, photo_jpeg())
    assert r.status_code == 200 and r.headers["x-mode"] == "photo"
    p = up.calls[-1]["prompt"]
    for t in [P.NIGHT_PROMPT, P.PORTRAIT_PROMPT, "Color look:"]:
        assert t not in p


# == Pro Night guards ========================================================
def test_darkness_gate_signal_calibration():
    assert G.night_signal(noise_black()).too_dark
    assert G.night_signal(enc(Image.new("RGB", (200, 150), (0, 0, 0)))).too_dark
    assert not G.night_signal(enc(scene())).too_dark
    # A dark street that still has lit windows is NOT too dark (lights = signal).
    assert not G.night_signal(enc(scene(dark=False).point(lambda v: v // 6))).too_dark


def test_structure_guard_calibration():
    base = enc(scene())
    bright = enc(scene().point(lambda v: min(255, int(v * 1.6 + 10))))
    assert G.structure_ok(base, base)[0]
    assert G.structure_ok(base, bright)[0]
    ok, s = G.structure_ok(base, enc(scene(extra=True)))
    assert not ok and s < G.STRUCTURE_MIN
    ok, _ = G.structure_ok(noise_black(), enc(scene(extra=True)))
    assert not ok
    ok, _ = G.structure_ok(base, enc(scene(seed=99)))
    assert not ok


def test_pro_night_too_dark_no_ai_no_charge(env):
    c, _, _, up = env
    before = account(c, "dev_v11")
    r = enhance(c, noise_black(), mode="night")
    assert r.status_code == 400
    det = r.json()["detail"]
    assert det["reason"] == "too_dark"
    assert det["message"] == "Too dark for Pro Night. Use Normal Night or turn on flash."
    assert up.calls == []
    assert account(c, "dev_v11") == before
    # v10 clients using night=true get the same gate.
    assert enhance(c, noise_black(), night="true").json()["detail"]["reason"] == "too_dark"


def test_pro_night_structure_changed_rejected_no_charge(env):
    c, _, _, up = env
    up.reply = enc(scene(extra=True), "PNG")
    before = account(c, "dev_v11")
    r = enhance(c, enc(scene()), mode="night")
    assert r.status_code == 422
    det = r.json()["detail"]
    assert det["reason"] == "structure_changed" and det["similarity"] < G.STRUCTURE_MIN
    assert len(up.calls) == 1
    assert account(c, "dev_v11") == before


def test_pro_night_good_result_is_charged(env):
    c, _, _, up = env
    up.reply = enc(scene().point(lambda v: min(255, int(v * 1.3 + 8))), "PNG")
    r = enhance(c, enc(scene()), mode="night")
    assert r.status_code == 200, r.text
    assert r.headers["x-night"] == "1" and r.headers["x-mode"] == "night"
    assert float(r.headers["x-structure"]) >= G.STRUCTURE_MIN
    assert r.headers["x-credits-charged"] == "1" or r.headers["x-trials-used"]
    p = up.calls[-1]["prompt"]
    assert p.startswith(P.UNIVERSAL_ENHANCE_PROMPT) and P.NIGHT_PROMPT not in p  # v11.58


# == v11.1 Macro + AI Microscope ===========================================
@pytest.mark.parametrize("zoom,level", [(2, "macro"), (5, "macro"), (5.4, "macro"), (6, "close"),
                                        (8, "close"), (10, "microscope"), (12, "microscope"),
                                        (20, "extreme"), (21, "extreme"), (25, "extreme"),
                                        (26, "ultra"), (30, "ultra")])
def test_v111_level_from_zoom(zoom, level):
    assert P.macro_level_for_zoom(zoom) == level


def macro_enhance(c, img, ctx=None, **f):
    data = {"device_id": "dev_v11", "quality": "full_hd", "mode": "macro", **f}
    files = {"image": ("x.jpg", img, "image/jpeg")}
    if ctx is not None:
        files["context"] = ("c.jpg", ctx, "image/jpeg")
    return c.post("/v1/enhance", data=data, files=files)


def test_v115_macro_colour_match(env):
    """Upstream returns a greener image → the server pulls it back to the
    source crop's yellow-green."""
    import color_match as CM
    c, _, _, up = env
    c.post("/v1/purchase", json={"device_id": "dev_v11", "product_id": "pack_25"})
    src = enc(Image.new("RGB", (400, 300), (190, 200, 60)))
    up.reply = enc(Image.new("RGB", (400, 300), (60, 170, 60)), "PNG")
    r = macro_enhance(c, src, subject="leaf", zoom="10", optical_limit="10")
    assert r.status_code == 200
    # v11.42: result colours far from the source → colour match skipped.
    assert CM.chroma_distance(r.content, src) > 15
    assert CM.chroma_distance(up.reply, src) > 15
    # Other modes are not colour matched.
    r = enhance(c, src, mode="portrait")
    assert CM.chroma_distance(r.content, src) > 15


def test_v115_colour_match_keeps_detail():
    import color_match as CM
    im = scene(); src = enc(im)
    tinted = enc(Image.merge("RGB", [ch.point(lambda v, k=k: min(255, int(v * k)))
                                    for ch, k in zip(im.split(), (0.7, 1.2, 0.7))]))
    out = CM.match_colors(tinted, src)
    assert CM.chroma_distance(out, src) < CM.chroma_distance(tinted, src) / 3
    assert G.structure_similarity(src, out) > 0.9


def test_v111_explicit_level_wins_and_bad_level_falls_back(env):
    c, _, _, up = env
    c.post("/v1/purchase", json={"device_id": "dev_v11", "product_id": "pack_25"})
    r = enhance(c, photo_jpeg(), mode="macro", subject="leaf", zoom="3", optical_limit="3", macro_level="microscope")
    assert r.headers["x-macro-level"] == "microscope"
    r = enhance(c, photo_jpeg(), mode="macro", subject="leaf", zoom="6", optical_limit="6", macro_level="weird")
    assert r.headers["x-macro-level"] == "close"
    r = enhance(c, photo_jpeg(), mode="portrait")
    assert "x-macro-level" not in r.headers


def test_v111_macro_technical_failure_is_free(env):
    c, _, _, up = env
    c.post("/v1/purchase", json={"device_id": "dev_v11", "product_id": "pack_25"})
    before = account(c, "dev_v11")["total"]
    up.mode = "fail"
    r = enhance(c, photo_jpeg(), mode="macro", subject="eye", zoom="9", optical_limit="9", quality="full_hd")
    assert r.status_code >= 500
    assert account(c, "dev_v11")["total"] == before  # technical failure → free
    up.mode = "ok"
    r = enhance(c, photo_jpeg(), mode="macro", subject="eye", zoom="9", optical_limit="9", quality="full_hd")
    assert r.status_code == 200 and r.headers["x-credits-charged"] == "6"  # v11.33 Full HD Microscope = 6
    assert account(c, "dev_v11")["total"] == before - 6


# == v11.7 Extreme level + regional colour match ===========================
def test_v117_regional_colour_match_removes_golden_top():
    import color_match as CM
    from PIL import ImageDraw
    src_im = Image.new("RGB", (400, 400), (170, 172, 175))  # uniform silver
    d = ImageDraw.Draw(src_im)
    for x in range(0, 400, 9):
        d.line([x, 0, x + 40, 400], fill=(120, 122, 125))
    src = enc(src_im)
    out_im = src_im.copy()
    top = Image.new("RGB", (400, 160), (205, 175, 95))  # golden top band
    out_im.paste(Image.blend(out_im.crop((0, 0, 400, 160)), top, 0.6), (0, 0))
    out = enc(out_im)
    assert CM.regional_chroma_spread(out) > 12
    fixed = CM.match_colors(out, src)
    assert CM.regional_chroma_spread(fixed) < 4
    assert CM.chroma_distance(fixed, src) < 2
    from PIL import ImageChops, ImageStat
    la = Image.open(io.BytesIO(out)).convert("L")
    lb = Image.open(io.BytesIO(fixed)).convert("L")
    assert ImageStat.Stat(ImageChops.difference(la, lb)).mean[0] < 4  # luma detail kept



# == v11.9 snapshot context, trusted labels, per-subject micro, clarity =====
def test_v119_clarity_and_boxed_context():
    p = P.build_prompt(has_context=True, zoom=30, optical_limit=3, tier="full_hd",
                       context_boxed=True)
    assert p.startswith(P.LOCKED_ENHANCE_PROMPT)
    # v11.58: one universal prompt — no zoom clarity / emphasis sentences.
    assert P.CONTEXT_BOXED_SENTENCE in p and P.HIGH_ZOOM_CLARITY not in p
    low = P.build_prompt(has_context=True, zoom=2, optical_limit=2)
    assert P.HIGH_ZOOM_CLARITY not in low and P.CONTEXT_IMAGE_SENTENCE in low
    assert P.build_prompt(zoom=30, optical_limit=3) == P.build_prompt(zoom=1, optical_limit=3)



# == v11.12 step photos + one image call, new level prompts ==================
def test_v1113_level_prompts_exact():
    # v11.39: short general prompts, no {subject}, no magnification numbers.
    for t in (P.MACRO_PROMPT, P.MACRO_CLOSE_PROMPT, P.MACRO_MICROSCOPE_PHOTO_PROMPT):
        assert "{subject}" not in t and "subpixel" not in t.lower()
    assert "brightfield microscope" in P.MACRO_MICROSCOPE_PHOTO_PROMPT
    assert P.macro_prompt(P.MACRO_PROMPT, "Eye", "macro") == P.MACRO_PROMPT



def test_v1112_one_call_steps_first_crop_last(env):
    c, _, _, up = env
    c.post("/v1/purchase", json={"device_id": "dev_v1112", "product_id": "pack_25"})
    n0 = len(up.calls)
    for zoom, level, key in (("3", "macro", "macro"), ("8", "close", "macro_close"),
                             ("15", "microscope", "macro_microscope"),
                             ("25", "extreme", "macro_extreme"), ("30", "ultra", "macro_ultra")):
        steps = [("steps", (f"s{i}.jpg", enc(scene()), "image/jpeg")) for i in range(4)]
        r = c.post("/v1/enhance", data={"device_id": "dev_v1112", "quality": "hd", "zoom": zoom,
                                        "optical_limit": zoom, "mode": "macro",
                                        "macro_level": level, "subject": "skin",
                                        "part": "pores and hairs"},
                   files=[("image", ("i.jpg", enc(scene()), "image/jpeg"))] + steps)
        assert r.status_code == 200, r.text
        assert r.headers["x-macro-level"] == level
        pl = up.calls[-1]
        if level == "extreme":
            assert pl["prompt"] == _fill(T1129_EXT, "pores and hairs", "skin")
        elif level == "ultra":
            assert pl["prompt"] == _fill(T1129_ULT, "pores and hairs", "skin")
        elif level == "microscope":  # v11.47: spot → 100x text-only (v11.58 + object)
            assert pl["prompt"] == _fill(P.MACRO_MICROSCOPE_PROMPT, "pores and hairs", "skin")
        else:
            base = P.DEFAULT_MODE_PROMPTS[key].replace("{subject}", "skin")
            if level != "microscope":  # v11.40 context line with the extra photos
                base = f"{base} {P.MACRO_CONTEXT_LINE}"
            assert pl["prompt"] == base
        assert P.LOCKED_ENHANCE_PROMPT not in pl["prompt"]
        # 1.5x 2x 3x 4x boxed, then the crop; Extreme (v11.19): crop only.
        n_refs = {"microscope": 0, "extreme": 0, "ultra": 0}.get(level, 3)  # v11.40: ≤2 ctx  # v11.30: deep text-only
        assert len(pl.get("input_references", [])) == n_refs
    assert len(up.calls) - n0 == 5  # one image call per shot, no describe step


def test_v1115_detected_hint_line():
    # v11.33: templates with {subject} take the description; others get the hint line.
    assert P.MACRO_HINT_LINE == "Detected: main subject {parent}; zoomed spot {part}."
    # v11.39: Macro/Close/Microscope no longer depend on detection.
    assert P.macro_prompt(P.MACRO_PROMPT, "Mobile phone back side with camera", level="macro",
                          part="camera lens ring with dust") == P.MACRO_PROMPT
    assert P.macro_prompt("Show it.", "wooden table top", level="macro") == "Show it."


def test_v1115_clean_and_parse():
    assert P.clean_detected('"Wooden table top."\nextra') == "wooden table top"
    assert P.clean_detected("one two three four five six seven eight nine ten eleven") == (
        "one two three four five six seven eight nine ten")
    assert P.parse_part_reply('```json\n{"same_subject": false, "part": "Denim weave"}\n```') == (
        False, "denim weave")
    assert P.parse_part_reply("nonsense") == (None, "")


def test_v1115_detect_endpoints_mocked_free(env, monkeypatch):
    c, _, _, up = env
    seen = []

    async def fake_vision(payload):
        seen.append(payload)
        n = len([x for x in payload["messages"][0]["content"] if x["type"] == "image_url"])
        return "Mobile phone back side" if n == 1 else '{"same_subject": true, "part": "camera lens"}'

    monkeypatch.setattr(main, "call_vision", fake_vision)
    before = c.get("/v1/account", params={"device_id": "dev_v1115"}).json()
    r = c.post("/v1/macro/subject", data={"device_id": "dev_v1115"},
               files={"image": ("a.jpg", enc(scene()), "image/jpeg")})
    assert {k: r.json()[k] for k in ("name", "others")} == {"name": "mobile phone back side", "others": []}
    assert seen[0]["model"] == "google/gemini-2.5-flash-lite"
    assert seen[0]["messages"][0]["content"][0]["text"] == P.DETECT_SUBJECT_PROMPT
    r = c.post("/v1/macro/part", data={"device_id": "dev_v1115", "parent": "mobile phone"},
               files={"one_x": ("a.jpg", enc(scene()), "image/jpeg"),
                      "step": ("b.jpg", enc(scene()), "image/jpeg")})
    assert r.json()["same_subject"] is True and r.json()["part"] == "camera lens"
    assert "main object: mobile phone; objects in it: mobile phone." in seen[1]["messages"][0]["content"][0]["text"]
    after = c.get("/v1/account", params={"device_id": "dev_v1115"}).json()
    assert before == after  # free
    assert not up.calls  # no image call


def test_v1115_detect_failure_is_empty(env, monkeypatch):
    c, *_ = env

    async def boom(payload):
        raise RuntimeError("down")

    monkeypatch.setattr(main, "call_vision", boom)
    r = c.post("/v1/macro/subject", data={"device_id": "dev_v1115b"},
               files={"image": ("a.jpg", enc(scene()), "image/jpeg")})
    assert r.status_code == 200 and {k: r.json()[k] for k in ("name", "others")} == {"name": "", "others": []}


def test_v1120_extreme_ultra_prompts():
    E, U = P.MACRO_EXTREME_PROMPT, P.MACRO_ULTRA_PROMPT
    for t in (E, U, P.MACRO_MICROSCOPE_PROMPT):  # v11.58: material-aware, no "cells"
        assert "cells" not in t and "{spot}" in t and "{on_object}" in t and "material" in t
    assert "painted metal" in P.MACRO_MICROSCOPE_PROMPT and "printing dots" in P.MACRO_MICROSCOPE_PROMPT
    # v11.58: part first, then the object locked at 1.5x
    assert P.macro_prompt(E, "human face", "extreme", 21, part="brown iris near pupil") == (
        _fill(T1129_EXT, "brown iris near pupil", "human face"))
    assert P.macro_prompt(U, "white styrofoam", "ultra", 30) == (
        _fill(T1129_ULT, "white styrofoam"))
    assert P.macro_prompt(E, None, "extreme", 21) == _fill(T1129_EXT, "this")
    assert "Detected" not in P.macro_prompt(U, "a", "ultra", part="b")
    assert P.DEFAULT_MODE_PROMPTS["macro_ultra"] == U
    assert P.MACRO_LEVELS["ultra"][0] == "macro_ultra"


def test_v1120_detect_prompts_ask_colour():
    assert "colour + object" in P.DETECT_SUBJECT_PROMPT
    assert "brown human eye, white styrofoam" in P.DETECT_SUBJECT_PROMPT
    assert "colour + what is in the box" in P.DETECT_PART_PROMPT
    assert "Include its colour" in P.DETECT_SPOT_PROMPT  # v11.32


def test_v1119_spot_endpoint_and_extreme_crop_only(env, monkeypatch):
    c, _, _, up = env
    seen = []

    async def fake_vision(payload):
        seen.append(payload)
        return "Phone screen center pixels."

    monkeypatch.setattr(main, "call_vision", fake_vision)
    r = c.post("/v1/macro/spot", data={"device_id": "dev_v1119", "subject": "mobile phone front"},
               files={"overview": ("a.jpg", enc(scene()), "image/jpeg"),
                      "closer": ("b.jpg", enc(scene()), "image/jpeg")})
    assert r.json()["spot"] == "phone screen center pixels"
    txt = seen[0]["messages"][0]["content"][0]["text"]
    assert txt.startswith("Photo 1 is the overview; main object: mobile phone front; objects in it: mobile phone front. Photo 2 is a closer view;")
    assert seen[0]["model"] == "google/gemini-2.5-flash"  # v11.27 spot model
    assert not up.calls

    async def boom(payload):
        raise RuntimeError("x")

    monkeypatch.setattr(main, "call_vision", boom)
    r = c.post("/v1/macro/spot", data={"device_id": "dev_v1119"},
               files={"overview": ("a.jpg", enc(scene()), "image/jpeg"),
                      "closer": ("b.jpg", enc(scene()), "image/jpeg")})
    assert r.json()["spot"] == ""


def test_v1121_detect_robust(env, monkeypatch):
    assert P.DETECT_MAX_TOKENS >= 60
    assert P.clean_detected('\n\n**"Brown human eye, iris visible."**') == (
        "brown human eye, iris visible")
    assert P.clean_detected("Answer: White styrofoam") == "white styrofoam"
    c, *_ = env
    seen = []

    async def fake(payload):
        seen.append(payload)
        return "Brown iris near pupil"  # plain text, not JSON

    monkeypatch.setattr(main, "call_vision", fake)
    r = c.post("/v1/macro/subject", data={"device_id": "dev_v1121"},
               files={"image": ("a.jpg", enc(scene()), "image/jpeg")})
    assert r.json()["name"] == "brown iris near pupil"
    assert seen[-1]["max_tokens"] >= 60
    r = c.post("/v1/macro/part", data={"device_id": "dev_v1121", "parent": "eye"},
               files={"one_x": ("a.jpg", enc(scene()), "image/jpeg"),
                      "step": ("b.jpg", enc(scene()), "image/jpeg")})
    assert r.json()["same_subject"] is None and r.json()["part"] == "brown iris near pupil"


def test_v1122_objects_and_device_rule(env, monkeypatch):
    rule = ("If the object is a phone, tablet, laptop, monitor or TV, name the device itself "
            "(e.g. black mobile phone screen), never what is shown on its screen (people, "
            "clothes, images, text).")
    assert P.DETECT_DEVICE_RULE == rule
    for p in (P.DETECT_SUBJECT_PROMPT, P.DETECT_PART_PROMPT, P.DETECT_SPOT_PROMPT):
        assert rule in p
    assert "CENTER" in P.DETECT_SUBJECT_PROMPT and '"others"' in P.DETECT_SUBJECT_PROMPT
    assert '"in_scene"' in P.DETECT_PART_PROMPT and '"object"' in P.DETECT_SPOT_PROMPT
    # tolerant parsing
    assert P.parse_subject_reply('```json\n{"main": "Red mug", "others": ["Blue pen", "red mug", 3]}\n```') == (
        "red mug", ["blue pen"])
    assert P.parse_subject_reply("White styrofoam") == ("white styrofoam", [])
    assert P.parse_subject_reply('{"main": "black mobile phone scr') == ("black mobile phone scr", [])
    assert P.parse_object_part_reply('{"object": "blue pen", "part": "metal tip", "in_scene": true}') == (
        "blue pen", "metal tip", True)
    assert P.parse_object_part_reply('{"same_subject": false, "part": "x"}') == ("", "x", False)
    assert P.parse_object_part_reply("brown iris") == ("", "brown iris", None)
    assert P.match_known_object("blue pen", ["red mug", "blue ballpoint pen"]) is None
    assert P.match_known_object("the blue pen", ["red mug", "blue pen"]) == "blue pen"
    assert P.spot_text("blue pen", "metal tip") == "blue pen metal tip"
    assert P.spot_text("blue pen", "blue pen tip") == "blue pen tip"
    assert P.spot_text("", "tip") == "tip"
    c, _, _, up = env
    seen = []

    async def fake(payload):
        seen.append(payload)
        n = len([x for x in payload["messages"][0]["content"] if x["type"] == "image_url"])
        if n == 1:
            return '{"main": "red mug", "others": ["blue pen"]}'
        return '{"object": "blue pen", "part": "silver metal tip", "in_scene": true}'

    monkeypatch.setattr(main, "call_vision", fake)
    r = c.post("/v1/macro/subject", data={"device_id": "dev_v1122"},
               files={"image": ("a.jpg", enc(scene()), "image/jpeg")})
    assert {k: r.json()[k] for k in ("name", "others")} == {"name": "red mug", "others": ["blue pen"]}
    r = c.post("/v1/macro/part", data={"device_id": "dev_v1122", "parent": "red mug",
                                       "others": '["blue pen"]'},
               files={"one_x": ("a.jpg", enc(scene()), "image/jpeg"),
                      "step": ("b.jpg", enc(scene()), "image/jpeg")})
    assert r.json() == {"object": "blue pen", "part": "silver metal tip", "in_scene": True,
                        "same_subject": True, "fill": None, "whole": None}
    assert "objects in it: red mug; blue pen." in seen[-1]["messages"][0]["content"][0]["text"]
    r = c.post("/v1/macro/spot", data={"device_id": "dev_v1122", "subject": "red mug",
                                       "others": '["blue pen"]'},
               files={"overview": ("a.jpg", enc(scene()), "image/jpeg"),
                      "closer": ("b.jpg", enc(scene()), "image/jpeg")})
    assert r.json()["spot"] == "blue pen silver metal tip"
    assert all(p["max_tokens"] in (P.DETECT_MAX_TOKENS, P.DETECT_SPOT_MAX_TOKENS) for p in seen)
    assert not up.calls


# v11.58: material-aware texts ({spot} = part, {on_object} = locked object).
T1129_EXT = P.MACRO_EXTREME_PROMPT
T1129_ULT = P.MACRO_ULTRA_PROMPT


def _fill(t, spot, obj=""):
    return t.replace("{on_object}", f" on the {obj}" if obj else "").replace("{spot}", spot)
