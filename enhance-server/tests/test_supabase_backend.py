"""STYLES_BACKEND=supabase with a mocked Supabase (no network)."""
import io

import httpx
import pytest
from fastapi.testclient import TestClient
from PIL import Image

import admin
import main
import supabase_styles as SB
from fake_supabase import FakeSupabase
from styles import Style

H = {"Authorization": "Bearer tok"}


def jpg():
    b = io.BytesIO(); Image.new("RGB", (40, 50), (10, 120, 30)).save(b, "JPEG"); return b.getvalue()


@pytest.fixture
def fake(monkeypatch, tmp_path):
    f = FakeSupabase()
    monkeypatch.setenv("ADMIN_API_TOKEN", "tok")
    monkeypatch.setenv("ADMIN_PASSWORD", "pw")
    main._styles = SB.SupabaseStyleStore("https://x.supabase.co", "svc", transport=httpx.MockTransport(f))
    main.reset_ledger(str(tmp_path / "l.sqlite3"))
    admin._fails.clear()
    yield f
    main._styles = None


def test_requires_config():
    with pytest.raises(RuntimeError):
        SB.SupabaseStyleStore("", "")


def test_selected_by_env(monkeypatch):
    monkeypatch.setenv("STYLES_BACKEND", "supabase")
    monkeypatch.setenv("SUPABASE_URL", "https://x.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "svc")
    main._styles = None
    try:
        assert isinstance(main.get_styles(), SB.SupabaseStyleStore)
    finally:
        main._styles = None


def test_store_roundtrip(fake):
    st = main.get_styles()
    st.upsert(Style(id="a", name="A", category="Travel", prompt="P-A", sort_order=0))
    st.upsert(Style(id="b", name="B", category="Mood", prompt="P-B", sort_order=1, enabled=False, free_trial=False))
    assert [s.id for s in st.list()] == ["a"]
    assert [s.id for s in st.list(include_disabled=True)] == ["a", "b"]
    assert st.get("b").free_trial is False and st.next_sort_order() == 2
    v1 = st.version(); st.move("b", -1)
    assert [s.id for s in st.list(include_disabled=True)] == ["b", "a"] and st.version() != v1
    name = st.save_image(jpg(), private=True)
    assert f"style-refs/{name}" in fake.objects and st.read_file(name, private=True)
    assert st.read_file(name) is None  # not in the public bucket
    assert st.read_file("../etc/passwd") is None
    st.get("a"); s = st.get("a"); s.ref_images = [name]; st.upsert(s)
    st.delete("a")
    assert st.get("a") is None and f"style-refs/{name}" not in fake.objects


def test_api_and_public_endpoints(fake):
    c = TestClient(main.app)
    r = c.post("/admin/api/styles", headers=H, json={"name": "Cloud", "category": "Mood", "prompt": "SECRET-CLOUD"})
    assert r.status_code == 201
    r = c.post("/admin/api/styles/cloud/images", headers=H, files=[
        ("display_image", ("t.jpg", jpg(), "image/jpeg")), ("ref_images", ("r.jpg", jpg(), "image/jpeg"))])
    js = r.json()
    assert js["display_image"] in [k.split("/")[1] for k in fake.objects if k.startswith("style-thumbs/")]
    assert js["ref_images"][0] in [k.split("/")[1] for k in fake.objects if k.startswith("style-refs/")]
    pub = c.get("/v1/styles")
    assert "SECRET-CLOUD" not in pub.text and "prompt" not in pub.text and "ref_images" not in pub.text
    assert c.get(pub.json()["styles"][0]["image_url"]).status_code == 200
    assert c.get(f"/media/styles/{js['ref_images'][0]}").status_code == 404
    assert c.delete("/admin/api/styles/cloud", headers=H).status_code == 200
    assert fake.objects == {} and fake.rows == {}
