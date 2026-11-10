"""v11.56 before/after style samples (sample_before_url / sample_after_url)."""
import io

import pytest
from fastapi.testclient import TestClient
from PIL import Image

import admin
import main


def _jpg(color=(200, 50, 50)):
    b = io.BytesIO()
    Image.new("RGB", (108, 192), color).save(b, "JPEG")
    return b.getvalue()


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("ADMIN_PASSWORD", "pw")
    monkeypatch.setenv("ADMIN_API_TOKEN", "tok")
    main.reset_styles(str(tmp_path / "styles.sqlite3"), str(tmp_path / "media" / "styles"))
    main.reset_ledger(str(tmp_path / "ledger.sqlite3"))
    admin._fails.clear()
    return TestClient(main.app)


H = {"Authorization": "Bearer tok"}


def test_public_list_has_null_samples_by_default(client):
    s = client.get("/v1/styles").json()["styles"][0]
    assert s["sample_before_url"] is None and s["sample_after_url"] is None
    assert "prompt" not in s


def test_api_upload_replace_remove_samples(client):
    r = client.post("/admin/api/styles/paris_eiffel/images", headers=H,
                    files={"sample_before": ("b.jpg", _jpg(), "image/jpeg"),
                           "sample_after": ("a.jpg", _jpg((0, 90, 200)), "image/jpeg")})
    assert r.status_code == 200, r.text
    js = r.json()
    assert js["sample_before_url"].startswith("/media/styles/")
    assert js["sample_after_url"].startswith("/media/styles/")
    pub = {s["id"]: s for s in client.get("/v1/styles").json()["styles"]}["paris_eiffel"]
    assert pub["sample_after_url"] == js["sample_after_url"]
    assert client.get(pub["sample_after_url"]).status_code == 200
    old = js["sample_after_url"]
    js2 = client.post("/admin/api/styles/paris_eiffel/images", headers=H,
                      files={"sample_after": ("a.jpg", _jpg((1, 2, 3)), "image/jpeg")}).json()
    assert js2["sample_after_url"] != old and js2["sample_before_url"] == js["sample_before_url"]
    assert client.get(old).status_code == 404
    js3 = client.post("/admin/api/styles/paris_eiffel/images", headers=H,
                      data={"remove_samples": "sample_before"}).json()
    assert js3["sample_before_url"] is None and js3["sample_after_url"] == js2["sample_after_url"]


def test_admin_form_has_sample_fields(client):
    client.post("/admin/login", data={"password": "pw"}, follow_redirects=False)
    html = client.get("/admin/styles/paris_eiffel/edit").text
    assert 'name="sample_before"' in html and 'name="sample_after"' in html
    vhtml = client.get("/admin/styles/new?media=video").text
    assert 'name="sample_after"' in vhtml and 'name="sample_before"' not in vhtml


def test_admin_form_upload(client):
    client.post("/admin/login", data={"password": "pw"}, follow_redirects=False)
    s = main.get_styles().get("santorini")
    r = client.post("/admin/styles/santorini", follow_redirects=False, data={
        "name": s.name, "category": s.category, "prompt": s.prompt, "credit_cost": str(s.credit_cost),
        "sort_order": str(s.sort_order), "enabled": "1", "needs_person": "1", "ui_category": s.ui_category},
        files={"sample_after": ("a.jpg", _jpg(), "image/jpeg")})
    assert r.status_code == 303
    s2 = main.get_styles().get("santorini")
    assert s2.sample_after_url and s2.credit_cost == s.credit_cost and s2.prompt == s.prompt
