"""v10: enhance-only custom prompts (no charge). The v10 outline pose library
was replaced by the v11 photo library (tests in test_v11.py)."""
import pytest
from fastapi.testclient import TestClient

import main
import prompts as P
from test_server import T0, Upstream, account, jpeg  # noqa: F401


@pytest.fixture()
def env(tmp_path, monkeypatch):
    main.reset_ledger(str(tmp_path / "ledger.sqlite3"))
    main.reset_styles(str(tmp_path / "styles.sqlite3"), str(tmp_path / "media" / "styles"))
    clock = {"now": T0}
    monkeypatch.setattr(main, "now_utc", lambda: clock["now"])
    up = Upstream()
    monkeypatch.setattr(main, "call_openrouter", up)
    return TestClient(main.app), None, up


# -- enhance-only custom prompts ------------------------------------------------
@pytest.mark.parametrize("text,expected", [
    ("enhance", True), ("Make it HD please", True), ("full hd 4k sharper", True),
    ("high resolution, clear photo", True), ("improve quality", True), ("fix blurry photo", True), ("blur the background", False),
    ("make it sharp and add sunglasses", False), ("brighter", False),
    ("convert to anime", False), ("HD Paris background", False), ("", False),
])
def test_enhance_only_rule(text, expected):
    assert P.enhance_only_custom_prompt(text) is expected


def test_enhance_only_custom_is_rejected_without_charge(env):
    c, _, up = env
    before = account(c, "dev_v10_e")["total"]
    r = c.post("/v1/looks/apply", data={"device_id": "dev_v10_e", "custom_prompt": "make it HD and sharper",
                                        "variations": "1"},
               files={"image": ("me.jpg", jpeg(), "image/jpeg")})
    assert r.status_code == 400 and r.json()["detail"]["reason"] == "enhance_only"
    assert up.calls == []
    assert account(c, "dev_v10_e")["total"] == before


def test_creative_custom_still_runs(env):
    c, _, up = env
    r = c.post("/v1/looks/apply", data={"device_id": "dev_v10_c", "custom_prompt": "add sunglasses, HD",
                                        "variations": "1"},
               files={"image": ("me.jpg", jpeg(), "image/jpeg")})
    assert r.status_code == 200, r.text
    assert len(up.calls) == 1
