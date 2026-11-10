"""v11.54 app browse categories (styles.ui_category)."""
import pytest
from fastapi.testclient import TestClient

import admin
import main
import supabase_styles
from styles import Style, normalize_ui_category


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("ADMIN_PASSWORD", "pw")
    main.reset_styles(str(tmp_path / "styles.sqlite3"), str(tmp_path / "media" / "styles"))
    main.reset_ledger(str(tmp_path / "ledger.sqlite3"))
    admin._fails.clear()
    return TestClient(main.app)


def test_normalize():
    assert normalize_ui_category("Cities") == "cities"
    assert normalize_ui_category(None) == "new"
    assert normalize_ui_category("zoom") == "new"  # not a photo category
    assert normalize_ui_category("zoom", "video") == "zoom"
    assert normalize_ui_category("cities", "video") == "new"


def test_public_list_exposes_category_not_prompt(client):
    styles = client.get("/v1/styles").json()["styles"]
    assert styles and all("ui_category" in s for s in styles)
    assert all("prompt" not in s for s in styles)
    by = {s["id"]: s["ui_category"] for s in styles}
    assert by["paris_eiffel"] == "cities"  # seeded


def test_admin_category_selector_photo_and_video(client):
    client.post("/admin/login", data={"password": "pw"}, follow_redirects=False)
    html = client.get("/admin/styles/new").text
    assert 'name="ui_category"' in html and "Black &amp; White" in html
    vhtml = client.get("/admin/styles/new?media=video").text
    assert 'value="motion"' in vhtml and 'value="cities"' not in vhtml
    r = client.post("/admin/styles", data={"name": "BW test", "category": "Mood", "prompt": "p",
                                            "credit_cost": "2", "enabled": "1", "ui_category": "bw"},
                    follow_redirects=False)
    assert r.status_code == 303
    s = main.get_styles().get("bw_test")
    assert s.ui_category == "bw" and s.credit_cost == 2
    r = client.post(f"/admin/styles/{s.id}", data={"name": "BW test", "category": "Mood", "prompt": "p",
                                                   "credit_cost": "2", "enabled": "1", "ui_category": "nope"},
                    follow_redirects=False)
    assert main.get_styles().get("bw_test").ui_category == "new"


def test_supabase_row_mapping():
    s = supabase_styles.SupabaseStyleStore._from_row({
        "id": "a", "name": "A", "category": "c", "prompt": "p", "credit_cost": 2, "pro_only": False,
        "enabled": True, "sort_order": 0, "ui_category": "trending"})
    assert s.ui_category == "trending"
    s2 = supabase_styles.SupabaseStyleStore._from_row({
        "id": "a", "name": "A", "category": "c", "prompt": "p", "credit_cost": 2, "pro_only": False,
        "enabled": True, "sort_order": 0})
    assert s2.ui_category == "new"
    assert "ui_category" in supabase_styles._FIELDS
