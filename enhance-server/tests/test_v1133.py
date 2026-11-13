"""v11.33: Macro level chips, box check, credits by quality (2K locked)."""
import main
import prompts as P
from fastapi.testclient import TestClient
from tests.test_v11 import env, enhance, photo_jpeg  # noqa: F401


def test_version():
    assert main.app.version == "11.1.59"  # v11.59


def test_credit_table_and_merge():
    assert P.macro_credits_for("macro", "hd") == 4 and P.macro_credits_for("microscope", "hd") == 5
    assert P.macro_credits_for("extreme", "full_hd") == 3 and P.macro_credits_for("close", "full_hd") == 5
    assert [P.DEFAULT_MACRO_CREDITS["2k"][l] for l in P.MACRO_LEVELS] == [13, 13, 14, 10, 10]
    assert P.MACRO_LOCKED_QUALITIES == ("2k",)
    t = P.merge_macro_credits({"hd": {"macro": 7, "ultra": "x", "bogus": 3}, "zz": {"macro": 1}})
    assert t["hd"]["macro"] == 7 and t["hd"]["ultra"] == 2 and "zz" not in t


def test_box_prompt_and_parse():
    assert "common name" in P.DETECT_BOX_PROMPT and '"clear"' in P.DETECT_BOX_PROMPT
    assert P.parse_box_reply('{"part": "brown eye, iris and eyelashes", "clear": true}') == (
        "brown eye, iris and eyelashes", True)
    assert P.parse_box_reply('{"part": "something", "clear": false}')[1] is False
    assert P.parse_box_reply("")[1] is False


def test_microscope_one_hint():
    assert P.macro_input_plan("microscope") == (1, 1536)


def test_credits_endpoint():
    c = TestClient(main.app)
    j = c.get("/v1/macro/credits").json()
    assert j["locked"] == ["2k"] and j["credits"]["full_hd"]["microscope"] == 6


def test_macro_2k_is_coming_soon(env):
    c, _, _, up = env
    c.post("/v1/purchase", json={"device_id": "dev_v11", "product_id": "pack_25"})
    n0 = len(up.calls)
    r = enhance(c, photo_jpeg(), mode="macro", subject="eye", zoom="3", optical_limit="3",
                quality="2k", macro_level="macro")
    assert r.status_code == 400 and "coming_soon" in r.text
    assert len(up.calls) == n0  # no AI call
    r = enhance(c, photo_jpeg(), mode="macro", subject="eye", zoom="3", optical_limit="3",
                quality="hd", macro_level="close")
    assert r.status_code == 200 and r.headers["x-credits-charged"] == "4"
