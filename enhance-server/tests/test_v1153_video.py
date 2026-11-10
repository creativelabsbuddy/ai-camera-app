"""v11.53 video: Wan 2.2 (8scale) ≤5 s, MiniMax H3 (Phosor) >5 s. Mocked."""
import io
import json

import httpx
import pytest
from fastapi.testclient import TestClient
from PIL import Image

import main
import video_providers as VP

DEV = "dev-video-1153"


def jpg():
    b = io.BytesIO()
    Image.new("RGB", (64, 96), (40, 120, 200)).save(b, "JPEG")
    return b.getvalue()


class Fake:
    def __init__(self):
        self.reqs = []
        self.state = "IN_QUEUE"

    def __call__(self, req: httpx.Request):
        self.reqs.append(req)
        u = str(req.url)
        if "8scale.run" in u:
            assert req.headers["authorization"] == "Bearer k-wan"
            if "/image-to-video" in u or "/text-to-video" in u:
                return httpx.Response(200, json={"requestId": "wanreq123", "status": "IN_QUEUE"})
            if "/status/wanreq123" in u:
                js = {"status": self.state}
                if self.state == "COMPLETED":
                    js["output"] = "https://cdn.8scale/x.mp4"
                return httpx.Response(200, json=js)
            if "/cancel/" in u:
                return httpx.Response(200, json={"ok": True})
        if "phosor.ai" in u:
            assert req.headers["x-api-key"] == "k-ph"
            if u.endswith("/storage/image/upload"):
                return httpx.Response(200, json={"s3_url": "https://s3/in.jpg"})
            if u.endswith("/inference/submit"):
                return httpx.Response(200, json={"request_id": "phreq-456", "status": "queued"})
            if "/inference/status/phreq-456" in u:
                return httpx.Response(200, json={"status": "completed" if self.state == "COMPLETED" else "processing"})
            if "/inference/result/phreq-456" in u:
                return httpx.Response(200, json={"data": {"video": {"url": "https://ph/x.mp4"}}})
        return httpx.Response(404)


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("VIDEO_API_KEY", "k-wan")
    monkeypatch.setenv("PHOSOR_API_KEY", "k-ph")
    monkeypatch.setenv("ALLOW_TEST_PURCHASES", "1")
    monkeypatch.delenv("VIDEO_CREDITS_JSON", raising=False)
    monkeypatch.delenv("MINIMAX_ENABLED", raising=False)
    main.reset_ledger(str(tmp_path / "ledger.sqlite3"))
    main._video_hits.clear()
    f = Fake()
    monkeypatch.setattr(main, "_video_transport", httpx.MockTransport(f))
    c = TestClient(main.app)
    c.post("/v1/purchase", json={"device_id": DEV, "product_id": "pack_60"})
    return c, f


def bal(c):
    return c.get("/v1/account", params={"device_id": DEV}).json()["total"]


def gen(c, **kw):
    data = {"device_id": DEV, "prompt": "gentle camera push-in", "kind": "i2v", "seconds": "5",
            "resolution": "480p", "aspect_ratio": "9:16"}
    data.update({k: str(v) for k, v in kw.items()})
    files = {"image": ("a.jpg", jpg(), "image/jpeg")} if data["kind"] == "i2v" else None
    return c.post("/v1/video/generate", data=data, files=files)


def test_provisional_credit_table():
    t = VP.credit_table()
    assert (t["wan_5_480p"], t["wan_5_580p"], t["wan_5_720p"]) == (3, 4, 7)
    assert (t["minimax_8_480p"], t["minimax_10_480p"], t["minimax_15_480p"]) == (7, 9, 13)
    assert (t["minimax_8_768p"], t["minimax_10_768p"], t["minimax_15_768p"]) == (11, 13, 20)


def test_routing():
    assert VP.route("i2v", "p", 5, "720p", "9:16").provider == VP.WAN
    assert VP.route("t2v", "p", 10, "768p", "16:9").provider == VP.MINIMAX
    for bad in [("i2v", "p", 5, "768p", "9:16"), ("i2v", "p", 10, "720p", "9:16"),
                ("i2v", "p", 7, "480p", "9:16"), ("x", "p", 5, "480p", "9:16"), ("t2v", " ", 5, "480p", "9:16")]:
        with pytest.raises(VP.VideoError):
            VP.route(*bad)


def test_wan_i2v_charged_once_on_success(env):
    c, f = env
    b0 = bal(c)
    r = gen(c)
    assert r.status_code == 200, r.text
    js = r.json()
    assert js["provider"] == "wan" and js["credits"] == 3 and js["model_label"] == "Wan 2.2"
    body = json.loads(f.reqs[0].content)
    assert body["seconds"] == 5 and body["resolution"] == "480p" and body["image"].startswith("data:image/jpeg;base64,")
    assert bal(c) == b0  # nothing charged at submit
    st = c.get(f"/v1/video/status/{js['job_id']}", params={"device_id": DEV}).json()
    assert st["status"] == "queued" and bal(c) == b0
    f.state = "COMPLETED"
    st = c.get(f"/v1/video/status/{js['job_id']}", params={"device_id": DEV}).json()
    assert st["status"] == "done" and st["video_url"].endswith(".mp4") and st["credits_charged"] == 3
    assert bal(c) == b0 - 3
    st = c.get(f"/v1/video/status/{js['job_id']}", params={"device_id": DEV}).json()
    assert st["credits_charged"] == 0 and bal(c) == b0 - 3  # no double charge


def test_minimax_t2v_with_result_endpoint_and_label(env):
    c, f = env
    js = gen(c, kind="t2v", seconds=10, resolution="768p", aspect_ratio="16:9").json()
    assert js["provider"] == "minimax" and js["model_label"] == "MiniMax H3" and js["credits"] == 13
    body = json.loads([r for r in f.reqs if r.url.path.endswith("/submit")][0].content)
    assert body == {"prompt": "gentle camera push-in", "resolution_tier": "768p", "aspect_ratio": "16:9",
                    "duration": 10, "model": "minimax/h3/text-to-video/turbo"}
    f.state = "COMPLETED"
    st = c.get(f"/v1/video/status/{js['job_id']}", params={"device_id": DEV}).json()
    assert st["video_url"] == "https://ph/x.mp4" and st["model_label"] == "MiniMax H3"


def test_minimax_i2v_uploads_image(env):
    c, f = env
    gen(c, seconds=8, resolution="480p")
    sub = [r for r in f.reqs if r.url.path.endswith("/submit")][0]
    assert json.loads(sub.content)["image_url"] == "https://s3/in.jpg"


def test_tampered_or_foreign_job_id(env):
    c, f = env
    jid = gen(c).json()["job_id"]
    forged = jid.replace("~3.", "~0.")
    assert c.get(f"/v1/video/status/{forged}", params={"device_id": DEV}).status_code == 404
    assert c.get(f"/v1/video/status/{jid}", params={"device_id": "someone-else"}).status_code == 404


def test_cancel_and_failure_never_charge(env):
    c, f = env
    b0 = bal(c)
    jid = gen(c).json()["job_id"]
    assert c.post(f"/v1/video/cancel/{jid}", data={"device_id": DEV}).json()["credits_charged"] == 0
    f.state = "FAILED"
    st = c.get(f"/v1/video/status/{jid}", params={"device_id": DEV}).json()
    assert st["status"] == "failed" and bal(c) == b0


def test_blocklist_minimax_switch_and_no_credits(env, monkeypatch):
    c, f = env
    monkeypatch.setattr(main.P, "blocked_custom_prompt", lambda s: True)
    assert gen(c).status_code == 400
    monkeypatch.setattr(main.P, "blocked_custom_prompt", lambda s: False)
    monkeypatch.setenv("MINIMAX_ENABLED", "0")
    assert gen(c, seconds=10, resolution="768p").status_code == 403
    assert c.get("/v1/video/options").json()["minimax_enabled"] is False
    r = gen(c, device_id="poor-device-1", seconds=5, resolution="720p")
    assert r.status_code == 402  # 2 free credits < 7
    assert not [x for x in f.reqs if "poor" in str(x.content)]


def test_override_credits(env, monkeypatch):
    monkeypatch.setenv("VIDEO_CREDITS_JSON", '{"wan_5_480p": 5}')
    assert VP.credit_table()["wan_5_480p"] == 5


def test_error_text_redacts_keys(monkeypatch):
    monkeypatch.setenv("VIDEO_API_KEY", "secret-wan-key")
    r = httpx.Response(402, json={"error": "insufficient balance for secret-wan-key"})
    assert "secret-wan-key" not in VP.error_text(r) and "<redacted>" in VP.error_text(r)


def test_admin_video_styles_credits_history(env, monkeypatch):
    import admin
    c, f = env
    monkeypatch.setenv("ADMIN_PASSWORD", "pw")
    admin._fails.clear()
    c.post("/admin/login", data={"password": "pw"}, follow_redirects=False)
    assert 'value="video"' in c.get("/admin/styles/new?media=video").text
    r = c.post("/admin/styles", data={"name": "Slow zoom", "category": "Video", "prompt": "slow cinematic push-in",
                                       "credit_cost": "2", "enabled": "1", "media_type": "video"},
               follow_redirects=False)
    assert r.status_code == 303
    assert main.get_styles().get("slow_zoom").media_type == "video"
    assert [s["id"] for s in c.get("/v1/video/styles").json()["styles"]] == ["slow_zoom"]
    assert "slow_zoom" not in c.get("/v1/styles").text  # image list unchanged
    # editable credits (provisional)
    assert "PROVISIONAL" in c.get("/admin/video/credits").text
    c.post("/admin/video/credits/save", data={"wan_5_480p": "4"}, follow_redirects=False)
    assert c.get("/v1/video/options").json()["credits"]["wan_5_480p"] == 4
    # preset uses the style prompt, forced I2V 9:16 5 s, logged
    js = gen(c, style_id="slow_zoom", prompt="ignored", seconds=10, resolution="580p").json()
    assert js["provider"] == "wan" and js["seconds"] == 5 and js["credits"] == 4
    f.state = "COMPLETED"
    c.get(f"/v1/video/status/{js['job_id']}", params={"device_id": DEV})
    h = c.get("/admin/video/history").text
    assert "wan" in h and "slow_zoom" in h and "done" in h
    c.post("/admin/video/credits/reset", follow_redirects=False)
