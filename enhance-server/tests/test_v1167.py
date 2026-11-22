"""v11.67 tests: one group per agreed change."""
import json
import os

import pytest

import main
import prompts as P
from test_server import APP, _dart_string_const
from test_v11 import enc, env, scene  # noqa: F401


def _dart(name_file):
    path = os.path.join(APP, "lib", "services", name_file)
    if not os.path.exists(path):
        pytest.skip("app source not present")
    return open(path, encoding="utf-8").read()


# --- 2: 5x / 10x gate detection, every macro level -------------------------

def test_gate_detect_5x_then_10x_connected(env, monkeypatch):  # noqa: F811
    c, _, _, _ = env
    seen = []
    replies = [
        '```json\n{"object": "Coin", "context": "wooden table, a pen at the edge", '
        '"visible": "silver disc with a raised rupee symbol and number 10, gold ring with ray lines, light scratches"}\n```',
        '{"object": "coin", "part": "raised rupee symbol stroke", '
        '"visible": "worn silver metal, fine scratches, raised edge", "same_object": true}',
    ]

    async def fake_vision(payload):
        seen.append(payload)
        return replies[len(seen) - 1]

    monkeypatch.setattr(main, "call_vision", fake_vision)
    before = c.get("/v1/account", params={"device_id": "dev_v1167"}).json()
    r = c.post("/v1/macro/gate-detect", data={"device_id": "dev_v1167", "gate": "5.0"},
               files={"image": ("a.jpg", enc(scene()), "image/jpeg")})
    assert r.status_code == 200, r.text
    five = r.json()
    assert five["object"] == "coin"
    assert five["context"].startswith("wooden table")
    assert "raised rupee symbol" in five["visible"]
    assert seen[0]["model"] == P.DETECT_MODEL == "google/gemini-2.5-flash-lite"
    assert seen[0]["max_tokens"] == 300
    content = seen[0]["messages"][0]["content"]
    assert content[0]["text"] == P.GATE_DETECT_5_PROMPT
    assert len([x for x in content if x["type"] == "image_url"]) == 1

    r = c.post("/v1/macro/gate-detect",
               data={"device_id": "dev_v1167", "gate": "10.0", "earlier": json.dumps(five)},
               files={"image": ("b.jpg", enc(scene()), "image/jpeg")})
    ten = r.json()
    assert ten["part"] == "raised rupee symbol stroke"
    assert ten["same_object"] is True
    t = seen[1]["messages"][0]["content"][0]["text"]
    assert t.startswith('Earlier (5x) this was seen: {"object":"coin"')
    assert "raised rupee symbol and number 10" in t  # the 5x answer goes along
    assert "If it is a different object now, say so." in t
    assert c.get("/v1/account", params={"device_id": "dev_v1167"}).json() == before  # free


def test_gate_detect_garbage_and_bad_earlier(env, monkeypatch):  # noqa: F811
    c, _, _, _ = env
    seen = []

    async def fake_vision(payload):
        seen.append(payload)
        return "sorry"

    monkeypatch.setattr(main, "call_vision", fake_vision)
    r = c.post("/v1/macro/gate-detect",
               data={"device_id": "dev_v1167b", "gate": "10.0", "earlier": "{not json"},
               files={"image": ("b.jpg", enc(scene()), "image/jpeg")})
    assert r.status_code == 200
    assert r.json()["object"] == "" and r.json()["same_object"] is None
    # bad earlier → the first-look (5x) prompt
    assert seen[0]["messages"][0]["content"][0]["text"] == P.GATE_DETECT_5_PROMPT


def test_gate_prompts_general_and_parse():
    for p in (P.GATE_DETECT_5_PROMPT, P.GATE_DETECT_10_PROMPT):
        low = p.lower()
        for w in ("coin", "leaf", "fabric", "napkin", "paper"):
            assert w not in low  # general: no object-specific words
        assert "under 40 words" in p
    assert P.parse_gate_reply("nothing") == {"object": "", "context": "", "part": "",
                                            "visible": "", "same_object": None}
    d = P.parse_gate_reply('{"object": "red ceramic mug", "part": "rim", '
                           '"visible": "glossy red glaze, small chip", "same_object": false}')
    assert d["object"] == "red ceramic mug" and d["same_object"] is False
    assert P.gate_object_name("shiny textured") == ""  # look words only → vague
    long = " ".join(["word"] * 80)
    assert len(P.sanitize_visible(long).split()) == 45
    assert P.gate_earlier_json({"object": "", "visible": ""}) == ""


def test_gate_prompts_match_app():
    src = _dart("gate_detect.dart")
    assert _dart_string_const(src, "kGateDetect5Prompt") == P.GATE_DETECT_5_PROMPT
    assert _dart_string_const(src, "kGateDetect10Prompt") == P.GATE_DETECT_10_PROMPT
    assert "const int kDetectGateMaxTokens = 300;" in src


# --- 3: simple Macro / Close / Microscope prompts --------------------------

SIMPLE_CASES = [
    ("macro", "coin", "", "", "This is a coin. Show it as a sharp macro-lens close-up."),
    ("macro", "", "", "", "Show this object as a sharp macro-lens close-up."),
    ("macro", "apple", "", "", "This is an apple. Show it as a sharp macro-lens close-up."),
    ("close", "coin", "rim", "", "This is a coin, rim. Show it as an extreme macro close-up with fine surface detail."),
    ("close", "coin", "", "", "This is a coin. Show it as an extreme macro close-up with fine surface detail."),
    ("close", "", "", "", "Show this object as an extreme macro close-up with fine surface detail."),
    ("microscope", "coin", "raised symbol", "worn silver metal, fine scratches.",
     "This is a coin, zoomed on raised symbol, showing worn silver metal, fine scratches. "
     "Show how it would look under a light microscope at 100x magnification."),
    ("microscope", "coin", "", "silver disc",
     "This is a coin, showing silver disc. Show how it would look under a light microscope at 100x magnification."),
    ("microscope", "close-up", "", "",
     "Show how this object would look under a light microscope at 100x magnification."),
    ("microscope", "", "rim", "",
     "This is this object, zoomed on rim. Show how it would look under a light microscope at 100x magnification."),
]


def test_simple_prompts_table():
    for level, o, p, v, want in SIMPLE_CASES:
        assert P.simple_macro_prompt(level, o, p, v) == want, (level, o, p, v)
    assert P.simple_macro_prompt("extreme", "coin", "rim", "x") is None
    assert P.simple_macro_prompt("ultra", "coin", "rim", "x") is None
    # the exact agreed templates
    assert P.SIMPLE_MACRO_PROMPT == "This is a {object}. Show it as a sharp macro-lens close-up."
    assert P.SIMPLE_CLOSE_PROMPT == ("This is a {object}, {part}. Show it as an extreme macro "
                                     "close-up with fine surface detail.")
    assert P.SIMPLE_MICROSCOPE_PROMPT == (
        "This is a {object}, zoomed on {part}, showing {visible}. Show how it would look under "
        "a light microscope at 100x magnification.")


def test_simple_prompts_match_app():
    src = _dart("mode_prompts.dart")
    assert _dart_string_const(src, "kSimpleMacroPrompt") == P.SIMPLE_MACRO_PROMPT
    assert _dart_string_const(src, "kSimpleClosePrompt") == P.SIMPLE_CLOSE_PROMPT
    assert _dart_string_const(src, "kSimpleMicroscopePrompt") == P.SIMPLE_MICROSCOPE_PROMPT


_N = [0]


def _macro_shot(c, dev, level, extra, n_steps=2):
    _N[0] += 1
    dev = f"{dev}_{_N[0]}"  # fresh credits per shot
    c.post("/v1/purchase", json={"device_id": dev, "product_id": "pack_25"})
    data = {"device_id": dev, "quality": "hd", "zoom": "12", "optical_limit": "4",
            "mode": "macro", "macro_level": level, "subject": "coin",
            "part": "raised symbol of a coin"}
    data.update(extra)
    steps = [("steps", (f"s{i}.jpg", enc(scene(seed=i + 2)), "image/jpeg"))
             for i in range(n_steps)]
    return c.post("/v1/enhance", data=data,
                  files=[("image", ("i.jpg", enc(scene()), "image/jpeg"))] + steps)


GATE = {"simple_macro": "true", "gate_object": "coin", "gate_part": "raised symbol",
        "gate_visible": "worn silver metal, fine scratches"}


def test_enhance_uses_simple_prompt_for_new_clients(env):  # noqa: F811
    c, _, _, up = env
    dev = "dev_v1167_simple"
    c.post("/v1/purchase", json={"device_id": dev, "product_id": "pack_25"})
    assert _macro_shot(c, dev, "microscope", dict(GATE, micro_steps="true")).status_code == 200
    pl = up.calls[-1]
    assert pl["prompt"] == (P.MICRO_STEPS_LINE + " This is a coin, zoomed on raised symbol, showing "
                            "worn silver metal, fine scratches. Show how it would look under a light "
                            "microscope at 100x magnification.")
    assert len(pl.get("input_references") or []) == 3  # 2 gate photos + final
    assert _macro_shot(c, dev, "macro", GATE).status_code == 200
    assert up.calls[-1]["prompt"].startswith("This is a coin. Show it as a sharp macro-lens close-up.")
    assert _macro_shot(c, dev, "close", GATE).status_code == 200
    assert up.calls[-1]["prompt"].startswith(
        "This is a coin, raised symbol. Show it as an extreme macro close-up")
    # Microscope with simple prompt never goes text-only (photo is sent)
    assert _macro_shot(c, dev, "microscope", GATE, n_steps=0).status_code == 200
    assert up.calls[-1].get("input_references")


def test_extreme_ultra_and_old_clients_untouched(env):  # noqa: F811
    c, _, _, up = env
    dev = "dev_v1167_old"
    c.post("/v1/purchase", json={"device_id": dev, "product_id": "pack_25"})
    for level in ("extreme", "ultra"):
        assert _macro_shot(c, dev, level, dict(GATE, micro_steps="true")).status_code == 200
        t = up.calls[-1]["prompt"]
        assert t.startswith(P.MICRO_STEPS_LINE)
        assert "This is a coin" not in t
        assert "raised symbol of a coin" in t
    # old client (no simple_macro) → the old level prompt
    assert _macro_shot(c, dev, "macro", {}).status_code == 200
    assert up.calls[-1]["prompt"].startswith("A natural close-up macro photograph")
