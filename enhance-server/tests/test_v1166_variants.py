"""v11.66: style variants (several looks inside one style card)."""
import io
import os

import httpx
from PIL import Image
from fastapi.testclient import TestClient

import main
import supabase_styles as SB
from fake_supabase import FakeSupabase
from styles import StyleVariant
from test_v9 import PW, apply, env, login  # noqa: F401

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def jpg():
    b = io.BytesIO()
    Image.new("RGB", (90, 160), (200, 80, 40)).save(b, "JPEG")
    return b.getvalue()


def _two(store, sid="paris_eiffel"):
    a = store.upsert_variant(StyleVariant("v_a", sid, "Sunset", "SECRET-VARIANT-A", sample_url="/media/styles/a.jpg",
                                          sort_order=0))
    b = store.upsert_variant(StyleVariant("v_b", sid, "Night", "SECRET-VARIANT-B", sort_order=1))
    return a, b


def test_styles_list_has_public_variants_without_prompts(env):
    c, store, _ = env
    v0 = c.get("/v1/styles").json()
    assert all("variants" not in s for s in v0["styles"])  # no variants → old shape
    _two(store)
    store.upsert_variant(StyleVariant("v_off", "paris_eiffel", "Hidden", "SECRET-OFF", sort_order=2, enabled=False))
    r = c.get("/v1/styles")
    js = r.json()
    assert js["version"] != v0["version"]
    pe = {s["id"]: s for s in js["styles"]}["paris_eiffel"]
    assert [v["id"] for v in pe["variants"]] == ["v_a", "v_b"]
    assert set(pe["variants"][0]) == {"id", "name", "sample_url", "sort_order"}
    assert "SECRET-" not in r.text and "prompt" not in r.text
    one = c.get("/v1/styles/paris_eiffel/variants").json()
    assert one["style_id"] == "paris_eiffel" and [v["name"] for v in one["variants"]] == ["Sunset", "Night"]
    assert c.get("/v1/styles/nope/variants").status_code == 404


def test_apply_uses_server_variant_prompt_and_parent_credits(env):
    c, store, up = env
    _two(store)
    c.post("/v1/purchase", json={"device_id": "dev_var", "product_id": "pack_25"})
    r = c.post("/v1/looks/apply", data={"device_id": "dev_var", "style_id": "paris_eiffel", "variant_id": "v_b",
                                         "custom_prompt": "IGNORED CLIENT PROMPT"},
               files={"image": ("me.jpg", jpg(), "image/jpeg")})
    assert r.status_code == 200, r.text
    sent = up.calls[-1]["prompt"]
    assert "SECRET-VARIANT-B" in sent and "IGNORED CLIENT PROMPT" not in sent
    assert store.get("paris_eiffel").prompt not in sent
    assert r.json()["credits_charged"] == store.get("paris_eiffel").credit_cost
    assert up.calls[-1]["model"] == main.KLEIN_MODEL  # parent's model


def test_apply_rejects_foreign_or_disabled_variant(env):
    c, store, up = env
    _two(store, sid="santorini")
    store.upsert_variant(StyleVariant("v_off", "paris_eiffel", "Off", "X", enabled=False))
    c.post("/v1/purchase", json={"device_id": "dev_var2", "product_id": "pack_25"})
    for vid in ("v_a", "v_off", "v_missing"):
        r = c.post("/v1/looks/apply", data={"device_id": "dev_var2", "style_id": "paris_eiffel", "variant_id": vid},
                   files={"image": ("me.jpg", jpg(), "image/jpeg")})
        assert r.status_code == 404 and r.json()["detail"] == "variant not found"
    assert up.calls == []


def test_apply_without_variant_unchanged(env):
    c, store, up = env
    _two(store)
    assert apply(c, style_id="paris_eiffel").status_code == 200
    assert store.get("paris_eiffel").prompt in up.calls[-1]["prompt"]


def test_admin_add_edit_order_delete_variant(env):
    c, store, _ = env
    login(c)
    assert "Variants (0)" in c.get("/admin").text
    assert "+ Add variant" in c.get("/admin/styles/paris_eiffel/variants").text
    assert 'name="sample"' in c.get("/admin/styles/paris_eiffel/variants/new").text
    for name in ("Golden", "Blue hour"):
        r = c.post("/admin/styles/paris_eiffel/variants", data={"name": name, "prompt": f"P-{name}", "enabled": "1"},
                   files=[("sample", ("s.jpg", jpg(), "image/jpeg"))], follow_redirects=False)
        assert r.status_code == 303
    vs = store.list_variants("paris_eiffel", include_disabled=True)
    assert [v.name for v in vs] == ["Golden", "Blue hour"] and all(v.sample_url for v in vs)
    assert c.get(vs[0].sample_url).status_code == 200
    c.post(f"/admin/variants/{vs[1].id}/move", data={"direction": "-1"}, follow_redirects=False)
    assert [v.name for v in store.list_variants("paris_eiffel")] == ["Blue hour", "Golden"]
    r = c.post(f"/admin/variants/{vs[0].id}", data={"name": "Golden 2", "prompt": "P2", "sort_order": "5",
                                                     "remove_sample": "1"}, follow_redirects=False)
    v = store.get_variant(vs[0].id)
    assert r.status_code == 303 and v.name == "Golden 2" and v.prompt == "P2" and not v.enabled and not v.sample_url
    c.post(f"/admin/variants/{vs[0].id}/toggle", follow_redirects=False)
    assert store.get_variant(vs[0].id).enabled
    c.post(f"/admin/variants/{vs[0].id}/delete", follow_redirects=False)
    assert store.get_variant(vs[0].id) is None
    assert "Variants (1)" in c.get("/admin").text
    # Deleting the style removes its variants.
    c.post("/admin/styles/paris_eiffel/delete", follow_redirects=False)
    assert store.list_variants(include_disabled=True) == []


def test_admin_variant_pages_need_login(env):
    c, _, _ = env
    r = c.get("/admin/styles/paris_eiffel/variants", follow_redirects=False)
    assert r.status_code == 303
    r = c.post("/admin/styles/paris_eiffel/variants", data={"name": "x", "prompt": "y"}, follow_redirects=False)
    assert r.status_code == 303


def _sb(f):
    return SB.SupabaseStyleStore("https://x.supabase.co", "svc", transport=httpx.MockTransport(f))


def test_supabase_missing_table_falls_back_to_no_variants():
    f = FakeSupabase()
    st = _sb(f)
    from styles import Style
    st.upsert(Style(id="a", name="A", category="Travel", prompt="P"))
    assert st.list_variants() == [] and st.get_variant("v_x") is None and st.version()


def test_supabase_variants_roundtrip():
    f = FakeSupabase()
    f.vrows = {}
    st = _sb(f)
    from styles import Style
    st.upsert(Style(id="a", name="A", category="Travel", prompt="P"))
    v0 = st.version()
    st.upsert_variant(StyleVariant("v1", "a", "One", "S1", sort_order=0))
    st.upsert_variant(StyleVariant("v2", "a", "Two", "S2", sort_order=1))
    assert st.version() != v0
    assert [v.id for v in st.list_variants("a")] == ["v1", "v2"]
    st.move_variant("v2", -1)
    assert [v.id for v in st.list_variants("a")] == ["v2", "v1"]
    assert st.get_variant("v1").prompt == "S1"
    st.delete_variant("v1")
    assert [v.id for v in st.list_variants(include_disabled=True)] == ["v2"]
    main._styles = st
    try:
        js = TestClient(main.app).get("/v1/styles").json()
        assert js["styles"][0]["variants"][0]["id"] == "v2" and "S2" not in str(js)
    finally:
        main._styles = None


def test_migration_is_additive_with_rls():
    sql = open(os.path.join(HERE, "migrations", "20261122_style_variants.sql")).read().lower()
    assert "create table if not exists public.style_variants" in sql
    assert "references public.styles(id) on delete cascade" in sql
    assert "enable row level security" in sql
    assert "create policy" not in sql  # service role only, like photo styles
    for bad in ("drop ", "alter table public.styles", "truncate", "delete from"):
        assert bad not in sql
