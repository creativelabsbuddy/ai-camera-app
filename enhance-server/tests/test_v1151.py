"""v11.51 camera filters = styles with kind='filter'."""
import io

import pytest
from fastapi.testclient import TestClient
from PIL import Image

import admin
import main
import supabase_styles
from styles import Style


def jpg():
    b = io.BytesIO()
    Image.new("RGB", (64, 64), (90, 120, 200)).save(b, "JPEG")
    return b.getvalue()


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("ADMIN_PASSWORD", "pw")
    main.reset_styles(str(tmp_path / "styles.sqlite3"), str(tmp_path / "media" / "styles"))
    main.reset_ledger(str(tmp_path / "ledger.sqlite3"))
    admin._fails.clear()
    return TestClient(main.app)


def test_kind_defaults_to_style_and_existing_unaffected(client):
    for s in main.get_styles().list(include_disabled=True):
        assert s.kind == "style"
    assert all(x.get("kind") == "style" for x in client.get("/v1/styles").json()["styles"])


def test_admin_creates_and_edits_filter(client):
    client.post("/admin/login", data={"password": "pw"}, follow_redirects=False)
    assert 'name="as_filter"' in client.get("/admin/styles/new").text
    r = client.post("/admin/styles", data={"name": "Vivid test", "category": "Filter", "prompt": "p",
                                            "credit_cost": "2", "enabled": "1", "as_filter": "1"},
                    files=[("display_image", ("a.jpg", jpg(), "image/jpeg"))], follow_redirects=False)
    assert r.status_code == 303
    s = main.get_styles().get("vivid_test")
    assert s.kind == "filter" and s.credit_cost == 2 and s.display_image
    pub = {x["id"]: x for x in client.get("/v1/styles").json()["styles"]}
    assert pub["vivid_test"]["kind"] == "filter"
    assert "prompt" not in pub["vivid_test"]
    assert "camera filter" in client.get("/admin").text
    r = client.post("/admin/styles/vivid_test", data={"name": "Vivid test", "category": "Filter",
                                                       "prompt": "p", "credit_cost": "2", "enabled": "1"},
                    follow_redirects=False)
    assert main.get_styles().get("vivid_test").kind == "style"


def test_supabase_fields_include_kind():
    assert "kind" in supabase_styles._FIELDS
    s = supabase_styles.SupabaseStyleStore._from_row({
        "id": "v", "name": "V", "category": "Filter", "prompt": "p", "credit_cost": 2, "pro_only": False,
        "enabled": True, "sort_order": 100, "kind": "filter"})
    assert s.kind == "filter"
    assert Style(id="a", name="a", category="c", prompt="p").kind == "style"
