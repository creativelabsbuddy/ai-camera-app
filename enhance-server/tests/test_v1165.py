"""v11.65: face/detail-preserving prompts, Real-ESRGAN tier upscale with a
Lanczos fallback, macro frame-fill prompts, Fast ⚡ video on fal. Mocked —
no real API calls."""
import base64
import io
import json

import httpx
import pytest
from fastapi.testclient import TestClient
from PIL import Image

import main
import prompts as P
import video_providers as VP
from test_server import enhance, env  # noqa: F401

DEV = "dev-v1165"


def _jpg(w, h):
    b = io.BytesIO()
    Image.new("RGB", (w, h), (90, 140, 60)).save(b, "JPEG")
    return b.getvalue()


# -- prompts -------------------------------------------------------------------
def test_face_preserving_prompts():
    face = ("Keep every face exactly the same person: same face shape, eyes, nose, lips, "
            "skin tone and expression.")
    assert P.UNIVERSAL_ENHANCE_PROMPT == ("Clean up and sharpen this image, with a natural tone. " + face +
                                          " Do not change, add or remove anything; keep all shapes, text "
                                          "and details as they are.")
    assert P.PORTRAIT_ENHANCE_PROMPT == ("Clean up and sharpen this image, with a natural tone. " + face +
                                         " Blur only the background with a natural bokeh, and keep the "
                                         "subject sharp. Do not change, add or remove anything else.")
    assert P.ZOOM_CLEAN_PROMPT == P.UNIVERSAL_ENHANCE_PROMPT


def test_macro_frame_fill_prompts():
    assert "three or four threads and their weave filling the whole frame" in P.MACRO_MICROSCOPE_PROMPT
    assert "one single thread filling the whole frame, with no weave visible" in P.MACRO_EXTREME_PROMPT
    assert "two or three fibres with their fine SEM-style surface scales" in P.MACRO_ULTRA_PROMPT
    for t in (P.MACRO_EXTREME_PROMPT, P.MACRO_ULTRA_PROMPT):
        assert "woven" not in t
        assert "{spot}{on_object}" in t
    assert "{spot}{on_object}" in P.MACRO_MICROSCOPE_PROMPT


# -- tier upscale ----------------------------------------------------------------
def _fake_esrgan(sent):
    async def f(tasks):
        sent.append(tasks)
        t = tasks[0]
        src = base64.b64decode(t["inputs"]["image"].split(",", 1)[1])
        im = Image.open(io.BytesIO(src))
        b = io.BytesIO()
        im.resize((im.width * 2, im.height * 2)).save(b, "JPEG")
        return 200, {"data": [{"taskType": "imageUpscale",
                               "imageBase64Data": base64.b64encode(b.getvalue()).decode(), "cost": 0.0006}]}
    return f


@pytest.mark.parametrize("tier,long_side", [("full_hd", 1920), ("ultra_hd", 2560)])
def test_tier_upscale_esrgan_then_lanczos(env, monkeypatch, tier, long_side):  # noqa: F811
    c, _, _ = env
    sent = []
    monkeypatch.setattr(main, "call_runware", _fake_esrgan(sent))
    c.post("/v1/purchase", json={"device_id": "dev_test_1", "product_id": "pack_25"})
    r = enhance(c, quality=tier)
    assert r.status_code == 200, r.text
    assert max(Image.open(io.BytesIO(r.content)).size) == long_side
    assert r.headers["X-Upscale"] == "esrgan"
    t = sent[0][0]
    assert t["taskType"] == "upscale" and t["model"] == "runware:504@1" and t["upscaleFactor"] == 2
    assert t["inputs"]["image"].startswith("data:image/")


def test_hd_never_upscaled(env, monkeypatch):  # noqa: F811
    c, _, _ = env
    sent = []
    monkeypatch.setattr(main, "call_runware", _fake_esrgan(sent))
    r = enhance(c, quality="hd")
    assert r.status_code == 200 and sent == [] and r.headers["X-Upscale"] == "none"


def test_old_4k_maps_to_ultra_hd(env, monkeypatch):  # noqa: F811
    c, _, _ = env
    sent = []
    monkeypatch.setattr(main, "call_runware", _fake_esrgan(sent))
    c.post("/v1/purchase", json={"device_id": "dev_test_1", "product_id": "pack_25"})
    r = enhance(c, quality="4k")
    assert r.status_code == 200, r.text
    assert max(Image.open(io.BytesIO(r.content)).size) == 2560


def test_insufficient_credits_falls_back_charges_normally(env, monkeypatch):  # noqa: F811
    c, _, _ = env

    async def broke(tasks):
        return 400, {"errors": [{"code": "insufficientCredits", "message": "Insufficient credits"}]}

    monkeypatch.setattr(main, "call_runware", broke)
    c.post("/v1/purchase", json={"device_id": "dev_test_1", "product_id": "pack_25"})
    r = enhance(c, quality="ultra_hd")
    assert r.status_code == 200, r.text  # the shot is NOT failed / refunded
    assert r.headers["X-Upscale"] == "resize"
    assert max(Image.open(io.BytesIO(r.content)).size) == 2560
    # Charged as a normal Ultra HD shot (4 credits, or the one-time UHD trial).
    assert r.headers["X-Credits-Charged"] == "4" or "uhd_4k" in r.headers["X-Trials-Used"]


def test_tiers_and_credits_unchanged():
    import ledger as L
    assert L.TIERS["hd"][1] == 1 and L.TIERS["full_hd"][1] == 2 and L.TIERS["ultra_hd"][1] == 4
    assert main.UPSCALE_TIERS == {"full_hd": 1920, "ultra_hd": 2560}


# -- Fast ⚡ video (fal) ------------------------------------------------------------
class FakeFal:
    def __init__(self):
        self.reqs = []
        self.state = "IN_QUEUE"
        self.result_status = 200

    def __call__(self, req: httpx.Request):
        self.reqs.append(req)
        u = str(req.url)
        if "queue.fal.run" in u:
            assert req.headers["authorization"] == "Key k-fal"
            if req.method == "POST" and u.endswith("/minimax/h3-max-turbo/image-to-video") or \
                    u.endswith("/minimax/h3-max-turbo/text-to-video"):
                return httpx.Response(200, json={"request_id": "fal-req-789", "status": "IN_QUEUE"})
            if u.endswith("/minimax/h3-max-turbo/requests/fal-req-789/status"):
                return httpx.Response(200, json={"status": self.state, "request_id": "fal-req-789"})
            if u.endswith("/minimax/h3-max-turbo/requests/fal-req-789/cancel"):
                return httpx.Response(202, json={"status": "CANCELLATION_REQUESTED"})
            if u.endswith("/minimax/h3-max-turbo/requests/fal-req-789"):
                if self.result_status != 200:
                    return httpx.Response(self.result_status, json={"detail": "generation failed"})
                return httpx.Response(200, json={"video": {"url": "https://v3.fal.media/x.mp4"}})
        return httpx.Response(404)


@pytest.fixture
def venv(tmp_path, monkeypatch):
    monkeypatch.setenv("PHOSOR_API_KEY", "k-ph")
    monkeypatch.setenv("FAL_KEY", "k-fal")
    monkeypatch.setenv("ALLOW_TEST_PURCHASES", "1")
    monkeypatch.delenv("VIDEO_CREDITS_JSON", raising=False)
    monkeypatch.delenv("MINIMAX_ENABLED", raising=False)
    main.reset_ledger(str(tmp_path / "ledger.sqlite3"))
    main._video_hits.clear()
    f = FakeFal()
    monkeypatch.setattr(main, "_video_transport", httpx.MockTransport(f))
    c = TestClient(main.app)
    c.post("/v1/purchase", json={"device_id": DEV, "product_id": "pack_60"})
    return c, f


def _bal(c):
    return c.get("/v1/account", params={"device_id": DEV}).json()["total"]


def _gen(c, **kw):
    data = {"device_id": DEV, "prompt": "gentle camera push-in", "kind": "i2v", "seconds": "5",
            "resolution": "480p", "aspect_ratio": "9:16", "speed": "fast"}
    data.update({k: str(v) for k, v in kw.items()})
    files = {"image": ("a.jpg", _jpg(64, 96), "image/jpeg")} if data["kind"] == "i2v" else None
    return c.post("/v1/video/generate", data=data, files=files)


def test_fast_credits_equal_standard_for_now():
    t = VP.credit_table()
    for r in VP.MM_RES:
        for s in VP.MM_SECONDS:
            assert t[f"fal_{s}_{r}"] == t[f"minimax_{s}_{r}"]
    assert VP.route("i2v", "p", 5, "480p", "9:16", fast=True).provider == VP.FAL
    assert VP.route("i2v", "p", 5, "480p", "9:16").provider == VP.MINIMAX


def test_fal_body_params():
    spec = VP.route("i2v", "p", 8, "768p", "9:16", fast=True)
    b = VP.fal_body(spec, "data:image/jpeg;base64,xx")
    assert b == {"prompt": "p", "duration": 8, "resolution": "768P", "prompt_expansion_mode": "disabled",
                 "enable_safety_checker": True, "image_url": "data:image/jpeg;base64,xx"}
    t = VP.fal_body(VP.route("t2v", "p", 5, "480p", "16:9", fast=True))
    assert t["aspect_ratio"] == "16:9" and "image_url" not in t and t["resolution"] == "480P"


def test_fast_i2v_charged_once_on_success(venv):
    c, f = venv
    b0 = _bal(c)
    r = _gen(c)
    assert r.status_code == 200, r.text
    js = r.json()
    assert js["provider"] == "fal" and js["credits"] == VP.credit_table()["minimax_5_480p"]
    sub = json.loads(f.reqs[0].content)
    assert sub["image_url"].startswith("data:image/jpeg;base64,") and sub["duration"] == 5
    assert sub["resolution"] == "480P"
    assert _bal(c) == b0  # nothing charged at submit
    jid = js["job_id"]
    st = c.get(f"/v1/video/status/{jid}", params={"device_id": DEV}).json()
    assert st["status"] == "queued"
    f.state = "IN_PROGRESS"
    assert c.get(f"/v1/video/status/{jid}", params={"device_id": DEV}).json()["status"] == "running"
    f.state = "COMPLETED"
    st = c.get(f"/v1/video/status/{jid}", params={"device_id": DEV}).json()
    assert st["status"] == "done" and st["video_url"] == "https://v3.fal.media/x.mp4"
    assert st["credits_charged"] == js["credits"]
    assert _bal(c) == b0 - js["credits"]
    st = c.get(f"/v1/video/status/{jid}", params={"device_id": DEV}).json()
    assert st["credits_charged"] == 0  # charged once
    assert st["model_label"] == "MiniMax H3 Max Turbo"


def test_fast_failure_never_charged(venv):
    c, f = venv
    b0 = _bal(c)
    jid = _gen(c, kind="t2v", aspect_ratio="16:9").json()["job_id"]
    assert json.loads(f.reqs[0].content)["aspect_ratio"] == "16:9"
    f.state, f.result_status = "COMPLETED", 422
    st = c.get(f"/v1/video/status/{jid}", params={"device_id": DEV}).json()
    assert st["status"] == "failed"
    assert _bal(c) == b0


def test_fast_cancel_and_not_configured(venv, monkeypatch):
    c, f = venv
    jid = _gen(c).json()["job_id"]
    r = c.post(f"/v1/video/cancel/{jid}", data={"device_id": DEV}).json()
    assert r["cancelled_at_provider"] is True and r["credits_charged"] == 0
    monkeypatch.delenv("FAL_KEY")
    assert _gen(c).status_code == 503
    assert _gen(c, speed="standard").status_code != 503  # Standard (Phosor) unaffected


def test_fal_key_redacted(monkeypatch):
    monkeypatch.setenv("FAL_KEY", "secret-fal-123")
    r = httpx.Response(401, json={"detail": "bad key secret-fal-123"})
    assert "secret-fal-123" not in VP.error_text(r)


def test_options_expose_fast(venv):
    c, _ = venv
    o = c.get("/v1/video/options").json()
    assert o["fast"]["enabled"] is True and "fal_5_480p" in o["credits"]
