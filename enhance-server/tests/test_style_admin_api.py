"""v11.1.29 Photo Styles admin: tabs, toggle, free-trial flag, token JSON API, CLI."""
import io
import json
import os
import subprocess
import sys
import threading
import time

import pytest
from fastapi.testclient import TestClient
from PIL import Image

import admin
import main

TOK = "test-api-token-123"


def jpg(color=(200, 50, 50)):
    b = io.BytesIO()
    Image.new("RGB", (64, 80), color).save(b, "JPEG")
    return b.getvalue()


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("ADMIN_PASSWORD", "pw")
    monkeypatch.setenv("ADMIN_API_TOKEN", TOK)
    main.reset_styles(str(tmp_path / "styles.sqlite3"), str(tmp_path / "media" / "styles"))
    main.reset_ledger(str(tmp_path / "ledger.sqlite3"))
    admin._fails.clear()
    return TestClient(main.app)


H = {"Authorization": f"Bearer {TOK}"}


def test_api_requires_token(client, monkeypatch):
    assert client.get("/admin/api/styles").status_code == 401
    assert client.get("/admin/api/styles", headers={"Authorization": "Bearer nope"}).status_code == 401
    # the admin password is NOT accepted as an API token
    assert client.get("/admin/api/styles", headers={"Authorization": "Bearer pw"}).status_code == 401
    assert client.post("/admin/api/styles", json={"name": "x"}).status_code == 401
    monkeypatch.delenv("ADMIN_API_TOKEN")
    assert client.get("/admin/api/styles", headers=H).status_code == 503


def test_api_crud_images_order(client):
    r = client.post("/admin/api/styles", headers=H, json={
        "name": "Kyoto temple", "category": "Travel", "prompt": "SECRET-KYOTO-PROMPT", "credit_cost": 3,
        "free_trial": False})
    assert r.status_code == 201, r.text
    s = r.json()
    assert s["id"] == "kyoto_temple" and s["prompt"] == "SECRET-KYOTO-PROMPT" and s["free_trial"] is False
    assert client.post("/admin/api/styles", headers=H, json={"id": "kyoto_temple", "name": "a", "category": "b",
                                                              "prompt": "c"}).status_code == 409
    assert client.post("/admin/api/styles", headers=H, json={"name": "no prompt"}).status_code == 422
    assert client.post("/admin/api/styles", headers=H, json={"name": "v", "category": "c", "prompt": "p",
                                                              "media_type": "video"}).status_code == 201  # v11.53: video styles allowed
    # images: thumbnail + 2 refs
    r = client.post("/admin/api/styles/kyoto_temple/images", headers=H, files=[
        ("display_image", ("t.jpg", jpg(), "image/jpeg")),
        ("ref_images", ("a.jpg", jpg((1, 2, 3)), "image/jpeg")),
        ("ref_images", ("b.jpg", jpg((4, 5, 6)), "image/jpeg"))])
    assert r.status_code == 200, r.text
    assert r.json()["display_image"] and len(r.json()["ref_images"]) == 2
    assert client.post("/admin/api/styles/kyoto_temple/images", headers=H, files=[
        ("ref_images", ("x.jpg", b"not an image", "image/jpeg"))]).status_code == 400
    too_many = [("ref_images", (f"{i}.jpg", jpg(), "image/jpeg")) for i in range(3)]
    assert client.post("/admin/api/styles/kyoto_temple/images", headers=H, files=too_many).status_code == 422
    r = client.post("/admin/api/styles/kyoto_temple/images", headers=H, data={"replace_refs": "1"},
                    files=[("ref_images", ("c.jpg", jpg(), "image/jpeg"))])
    assert len(r.json()["ref_images"]) == 1
    # update / disable
    r = client.put("/admin/api/styles/kyoto_temple", headers=H, json={"credit_cost": 5, "enabled": False})
    assert r.json()["credit_cost"] == 5 and r.json()["enabled"] is False
    pub = client.get("/v1/styles").json()["styles"]
    assert "kyoto_temple" not in [x["id"] for x in pub]
    client.put("/admin/api/styles/kyoto_temple", headers=H, json={"enabled": True})
    # reorder: put it first
    r = client.post("/admin/api/styles/order", headers=H, json={"ids": ["kyoto_temple"]})
    assert r.json()["ids"][0] == "kyoto_temple"
    pub = client.get("/v1/styles")
    assert pub.json()["styles"][0]["id"] == "kyoto_temple"
    assert pub.json()["styles"][0]["image_url"].startswith("/media/styles/")
    # hidden prompt / ref files never public
    assert "SECRET-KYOTO-PROMPT" not in pub.text and "ref_images" not in pub.text and "prompt" not in pub.text
    refname = client.get("/admin/api/styles/kyoto_temple", headers=H).json()["ref_images"][0]
    assert client.get(f"/media/styles/{refname}").status_code == 404
    assert client.get(f"/admin/ref/{refname}", follow_redirects=False).status_code == 303
    # delete
    assert client.delete("/admin/api/styles/kyoto_temple", headers=H).status_code == 200
    assert client.get("/admin/api/styles/kyoto_temple", headers=H).status_code == 404
    assert client.delete("/admin/api/styles/kyoto_temple", headers=H).status_code == 404


def _login(client):
    client.post("/admin/login", data={"password": "pw"}, follow_redirects=False)
    client.cookies.set(admin.COOKIE, admin.make_session(), path="/admin")


def test_panel_tabs_toggle_and_free_trial(client):
    _login(client)
    page = client.get("/admin")
    assert page.status_code == 200 and ">Photo<" in page.text and ">Video<" in page.text
    assert "Add photo style" in page.text
    vid = client.get("/admin?tab=video")
    assert "Video styles" in vid.text and "Add video style" in vid.text and "Add photo style" not in vid.text
    sid = main.get_styles().list()[0].id
    client.post(f"/admin/styles/{sid}/toggle", follow_redirects=False)
    assert main.get_styles().get(sid).enabled is False
    client.post(f"/admin/styles/{sid}/toggle", follow_redirects=False)
    assert main.get_styles().get(sid).enabled is True
    form = client.get("/admin/styles/new")
    assert 'name="free_trial"' in form.text
    r = client.post("/admin/styles", data={"name": "Panel style", "category": "Mood", "prompt": "p",
                                            "credit_cost": "4", "enabled": "1"},
                    files=[("ref_images", ("a.jpg", jpg(), "image/jpeg")),
                           ("ref_images", ("b.jpg", jpg(), "image/jpeg"))], follow_redirects=False)
    assert r.status_code == 303
    s = main.get_styles().get("panel_style")
    assert s.free_trial is False and len(s.ref_images) == 2 and s.credit_cost == 4


def test_migration_adds_columns(tmp_path):
    import sqlite3
    db = tmp_path / "old.sqlite3"
    c = sqlite3.connect(db)
    c.executescript("""CREATE TABLE styles(id TEXT PRIMARY KEY, name TEXT NOT NULL, category TEXT NOT NULL,
      prompt TEXT NOT NULL, credit_cost INTEGER NOT NULL DEFAULT 2, pro_only INTEGER NOT NULL DEFAULT 0,
      enabled INTEGER NOT NULL DEFAULT 1, sort_order INTEGER NOT NULL DEFAULT 0, display_image TEXT,
      ref_images TEXT NOT NULL DEFAULT '[]', updated_at REAL NOT NULL, needs_person INTEGER NOT NULL DEFAULT 1);
      INSERT INTO styles(id,name,category,prompt,updated_at) VALUES('a','A','Travel','p',0);""")
    c.commit(); c.close()
    import styles as S
    st = S.StyleStore(str(db), str(tmp_path / "m"))
    s = st.get("a")
    assert s.media_type == "photo" and s.free_trial is True


def test_cli_against_live_server(tmp_path):
    """Starts uvicorn on a free port (local only) and runs tools/add_style.py."""
    import socket
    sock = socket.socket(); sock.bind(("127.0.0.1", 0)); port = sock.getsockname()[1]; sock.close()
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    env = {**os.environ, "ADMIN_API_TOKEN": TOK, "STYLES_DB": str(tmp_path / "s.sqlite3"),
           "STYLE_MEDIA_DIR": str(tmp_path / "media" / "styles"), "LEDGER_DB": str(tmp_path / "l.sqlite3"),
           "POSES_DB": str(tmp_path / "p.sqlite3"), "MODE_PROMPTS_DB": str(tmp_path / "mp.sqlite3"),
           "OPENROUTER_API_KEY": ""}
    srv = subprocess.Popen([sys.executable, "-m", "uvicorn", "main:app", "--host", "127.0.0.1", "--port", str(port)],
                           cwd=here, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        import urllib.request
        for _ in range(100):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=1); break
            except Exception:
                time.sleep(0.1)
        Image.new("RGB", (50, 60), (9, 9, 9)).save(tmp_path / "thumb.jpg")
        Image.new("RGB", (50, 60), (90, 9, 9)).save(tmp_path / "ref1.jpg")
        (tmp_path / "s.json").write_text(json.dumps({"name": "CLI style", "category": "Mood",
                                                     "prompt": "CLI-SECRET", "credit_cost": 1,
                                                     "thumbnail": "thumb.jpg", "refs": ["ref1.jpg"]}))
        cli = [sys.executable, os.path.join(here, "tools", "add_style.py"), "--server", f"http://127.0.0.1:{port}"]
        out = subprocess.run(cli + [str(tmp_path / "s.json")], env=env, capture_output=True, text=True)
        assert out.returncode == 0, out.stderr
        res = json.loads(out.stdout)
        assert res["id"] == "cli_style" and res["display_image"] and res["ref_images"] == 1
        lst = subprocess.run(cli + ["--list"], env=env, capture_output=True, text=True)
        assert "cli_style" in lst.stdout
        bad = subprocess.run(cli + ["--token", "wrong", "--list"], env=env, capture_output=True, text=True)
        assert bad.returncode == 1 and "401" in bad.stderr
        pub = urllib.request.urlopen(f"http://127.0.0.1:{port}/v1/styles").read().decode()
        assert "cli_style" in pub and "CLI-SECRET" not in pub
        d = subprocess.run(cli + ["--delete", "cli_style"], env=env, capture_output=True, text=True)
        assert d.returncode == 0
    finally:
        srv.terminate(); srv.wait(5)
