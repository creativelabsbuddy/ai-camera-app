"""v11.58: per-style model routing (Klein / Runware FLUX.2 Klein 4B / Custom),
universal DSLR prompt, no upscale / q90 re-encode."""
import base64
import io

from PIL import Image

import main
import prompts as P
import styles as S
from test_server import png_b64
from test_v9 import PW, apply, env, login  # noqa: F401
from test_v11 import account


def _set_model(store, sid, model):
    s = store.get(sid)
    s.model = model
    store.upsert(s)
    return s


def test_style_model_normalize_and_default():
    assert S.normalize_style_model("klein") == "klein"
    assert S.normalize_style_model("RUNWARE_KLEIN4B") == "runware_klein4b"
    assert S.normalize_style_model("") == "custom"  # fallback to Custom
    assert S.normalize_style_model("whatever") == "custom"
    assert S.Style(id="x", name="x", category="x", prompt="x").model == "klein"


def test_klein_style_sends_photo_only(env):
    c, store, up = env
    c.post("/v1/purchase", json={"device_id": "dev_v1158", "product_id": "pack_25"})
    r = apply(c, dev="dev_v1158", style_id="santorini")
    assert r.status_code == 200, r.text
    p = up.calls[-1]
    assert p["model"] == main.KLEIN_MODEL and len(p["input_references"]) == 1
    assert "quality" not in p and "resolution" not in p
    assert r.json()["model"] == main.KLEIN_MODEL


def test_runware_style_routes_to_runware(env, monkeypatch):
    c, store, up = env
    monkeypatch.setenv("RUNWARE_API_KEY", "test-not-a-real-key")
    _set_model(store, "santorini", "runware_klein4b")
    sent = []

    async def fake_runware(tasks):
        sent.append(tasks)
        return 200, {"data": [{"imageBase64Data": png_b64(512, 768), "cost": 0.002}]}

    monkeypatch.setattr(main, "call_runware", fake_runware)
    c.post("/v1/purchase", json={"device_id": "dev_v1158b", "product_id": "pack_25"})
    before = account(c, "dev_v1158b")["total"]
    r = apply(c, dev="dev_v1158b", style_id="santorini")
    assert r.status_code == 200, r.text
    assert up.calls == []  # OpenRouter not called
    t = sent[0][0]
    assert t["taskType"] == "imageInference" and t["model"] == main.RUNWARE_KLEIN4B_MODEL
    assert t["width"] % 16 == 0 and t["height"] % 16 == 0 and max(t["width"], t["height"]) == 1024
    assert len(t["inputs"]["referenceImages"]) == 1 and t["positivePrompt"]
    assert r.json()["model"] == main.RUNWARE_KLEIN4B_MODEL
    # Charged the style's own credit cost (unchanged).
    assert before - account(c, "dev_v1158b")["total"] == store.get("santorini").credit_cost
    out = Image.open(io.BytesIO(base64.b64decode(r.json()["images"][0])))
    assert out.size == (512, 768)


def test_runware_failure_falls_back_to_custom(env, monkeypatch):
    c, store, up = env
    monkeypatch.setenv("RUNWARE_API_KEY", "test-not-a-real-key")
    _set_model(store, "santorini", "runware_klein4b")

    async def down(tasks):
        return 500, {"errors": [{"message": "down"}]}

    monkeypatch.setattr(main, "call_runware", down)
    c.post("/v1/purchase", json={"device_id": "dev_v1158c", "product_id": "pack_25"})
    r = apply(c, dev="dev_v1158c", style_id="santorini")
    assert r.status_code == 200, r.text
    assert up.calls[-1]["model"] == main.MODEL  # Custom (Flare)
    assert r.json()["model"] == main.MODEL


def test_runware_without_key_uses_custom(env, monkeypatch):
    c, store, up = env
    monkeypatch.delenv("RUNWARE_API_KEY", raising=False)
    monkeypatch.delenv("ENHANCE_MOCK", raising=False)
    _set_model(store, "santorini", "runware_klein4b")
    called = []

    async def never(tasks):
        called.append(1)
        return 500, {}

    monkeypatch.setattr(main, "call_runware", never)
    c.post("/v1/purchase", json={"device_id": "dev_v1158d", "product_id": "pack_25"})
    assert apply(c, dev="dev_v1158d", style_id="santorini").status_code == 200
    assert called == [] and up.calls[-1]["model"] == main.MODEL


def test_klein_failure_falls_back_then_charges_nothing_when_all_fail(env):
    c, store, up = env
    c.post("/v1/purchase", json={"device_id": "dev_v1158e", "product_id": "pack_25"})
    up.mode = "fail"
    assert apply(c, dev="dev_v1158e", style_id="santorini").status_code == 502
    assert [p["model"] for p in up.calls] == [main.KLEIN_MODEL, main.MODEL]
    assert account(c, "dev_v1158e")["state"]["pack_credits"] == 25


def test_admin_model_select_saved(env):
    c, store, _ = env
    login(c)
    html = c.get("/admin/styles/santorini/edit").text
    assert 'name="model"' in html and "runware_klein4b" in html
    s = store.get("santorini")
    r = c.post("/admin/styles/santorini", data={
        "name": s.name, "category": s.category, "prompt": s.prompt, "credit_cost": str(s.credit_cost),
        "sort_order": str(s.sort_order), "enabled": "1", "model": "runware_klein4b"}, follow_redirects=False)
    assert r.status_code == 303
    got = store.get("santorini")
    assert got.model == "runware_klein4b" and got.credit_cost == s.credit_cost
    assert c.get("/v1/styles").json()["styles"][0]["model"] in ("klein", "runware_klein4b", "custom")


def test_runware_size():
    assert main.runware_size(3000, 4000) == (768, 1024)
    w, h = main.runware_size(1080, 1920)
    assert h == 1024 and w % 16 == 0


def test_universal_prompt_single_for_all():
    u = P.UNIVERSAL_ENHANCE_PROMPT
    assert u.startswith("Enhance this photo so it looks like it was shot on a professional DSLR")
    assert P.build_prompt(zoom=20, optical_limit=2, night=True).startswith(u)
    assert P.NIGHT_PROMPT not in P.build_prompt(night=True)
    port = P.build_prompt(portrait_prompt=P.PORTRAIT_ENHANCE_PROMPT)
    assert port.startswith(P.PORTRAIT_ENHANCE_PROMPT) and u not in port
    assert "bokeh" in P.PORTRAIT_ENHANCE_PROMPT and "100% sharp" in P.PORTRAIT_ENHANCE_PROMPT


def test_prepare_no_q90(tmp_path):
    im = Image.new("RGB", (3000, 2000), (120, 80, 40))
    b = io.BytesIO()
    im.save(b, "JPEG", quality=95)
    out, w, h = main.prepare(b.getvalue(), 2048)
    assert (w, h) == (2048, 1365)
    assert len(out) > 0


def test_phosor_result_202_is_still_running(tmp_path, monkeypatch):
    """v11.58: Phosor /inference/result answers 202 until the video is
    published → status stays running (not failed); nothing is charged."""
    import httpx
    from fastapi.testclient import TestClient

    import tests.test_v1153_video as T

    monkeypatch.setenv("VIDEO_API_KEY", "k-wan")
    monkeypatch.setenv("PHOSOR_API_KEY", "k-ph")
    monkeypatch.setenv("ALLOW_TEST_PURCHASES", "1")
    monkeypatch.delenv("VIDEO_CREDITS_JSON", raising=False)
    monkeypatch.delenv("MINIMAX_ENABLED", raising=False)
    main.reset_ledger(str(tmp_path / "ledger.sqlite3"))
    main._video_hits.clear()
    f = T.Fake()
    published = {"ok": False}

    def handler(req):
        if "/inference/result/" in str(req.url) and not published["ok"]:
            return httpx.Response(202, json={"status": "processing"})
        return f(req)

    monkeypatch.setattr(main, "_video_transport", httpx.MockTransport(handler))
    c = TestClient(main.app)
    c.post("/v1/purchase", json={"device_id": T.DEV, "product_id": "pack_60"})
    b0 = T.bal(c)
    js = T.gen(c, kind="t2v", seconds=10, resolution="768p", aspect_ratio="16:9").json()
    f.state = "COMPLETED"
    st = c.get(f"/v1/video/status/{js['job_id']}", params={"device_id": T.DEV}).json()
    assert st["status"] == "running" and T.bal(c) == b0
    published["ok"] = True
    st = c.get(f"/v1/video/status/{js['job_id']}", params={"device_id": T.DEV}).json()
    assert st["status"] == "done" and st["video_url"] == "https://ph/x.mp4"
    assert T.bal(c) == b0 - js["credits"]
