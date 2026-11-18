"""v11.64: Microscope / Extreme / Ultra common-name detection on flash-lite
(name + part step), look-word stripping, shape-ban line, Dart parity."""
import os
import re

import pytest

import main
import prompts as P
from test_server import APP, _dart_string_const
from test_v11 import enc, env, scene  # noqa: F401


def _dart():
    path = os.path.join(APP, "lib", "services", "mode_prompts.dart")
    if not os.path.exists(path):
        pytest.skip("app source not present")
    return open(path, encoding="utf-8").read()


def test_napkin_old_reply_never_the_spot():
    name, part = P.parse_micro_name_reply("white paper, with texture, oval shape")
    spot = P.micro_spot_text(name, part)
    assert spot == "white paper"
    assert not any(w in spot for w in ("oval", "shape", "texture"))


def test_napkin_name_part_spot():
    assert P.parse_micro_name_reply("white paper napkin, surface") == ("white paper napkin", "surface")
    assert P.micro_spot_text("white paper napkin", "surface") == "surface of a white paper napkin"
    assert P.micro_spot_text("human hand", "back of hand") == "skin on the back of a human hand"
    assert P.micro_spot_text("red soda can", "side") == "side of a red soda can"
    assert P.parse_micro_name_reply("white, oval shape")[0] == ""


def test_part_never_overwrites_name():
    for part in ("white paper, with texture, oval shape", "oval shape", "", "surface"):
        assert "white paper napkin" in P.micro_spot_text("white paper napkin", part)
    assert P.micro_part_only("textured oval surface") == "surface"


def test_look_words_vague_and_stripped():
    for w in ("oval", "round", "square", "rectangular", "shape", "textured", "embossed", "pattern"):
        assert w in P.VAGUE_DETECT_WORDS and P.is_vague_detect(f"white {w}")
    assert P.strip_look_words("embossed white paper napkin") == "white paper napkin"
    assert not P.is_vague_detect("white paper napkin")


def test_shape_ban_line_in_deep_prompts():
    for t in (P.MACRO_MICROSCOPE_PROMPT, P.MACRO_EXTREME_PROMPT, P.MACRO_ULTRA_PROMPT):
        assert ("Do not draw the whole object, its outline or its shape; fill the frame with "
                "the inner structure of its own material") in t
        assert "a paper napkin shows pressed paper fibres" in t and "cells" not in t


def test_text_only_only_with_clear_name():
    spot = P.micro_spot_text("white paper napkin", "surface")
    assert P.macro_text_only("microscope", "white paper napkin", spot)
    assert not P.macro_text_only("microscope", "close-up", "")
    assert P.macro_prompt(P.MACRO_MICROSCOPE_PROMPT, "close-up", "microscope", part="") == \
        P.MACRO_MICROSCOPE_PHOTO_PROMPT
    assert P.deep_prompt(P.MACRO_EXTREME_PROMPT, "close-up", "").startswith("A tiny area of this under")


def test_dart_parity():
    src = _dart()
    assert _dart_string_const(src, "kDetectMicroNamePrompt") == P.DETECT_MICRO_NAME_PROMPT
    assert _dart_string_const(src, "kDetectMicroPartPrompt") == P.DETECT_MICRO_PART_PROMPT
    look = set(re.findall(r"'([a-z-]+)'", src.split("kLookStripWords = {")[1].split("};")[0]))
    assert look == P.LOOK_STRIP_WORDS


def test_micro_endpoints_flash_lite_free(env, monkeypatch):  # noqa: F811
    c, _, _, up = env
    seen = []

    async def fake_vision(payload):
        seen.append(payload)
        if len(seen) == 1:
            return "White paper napkin, oval shape"
        return '{"part": "textured surface", "in_scene": true}'

    monkeypatch.setattr(main, "call_vision", fake_vision)
    before = c.get("/v1/account", params={"device_id": "dev_v1164"}).json()
    r = c.post("/v1/macro/micro-name", data={"device_id": "dev_v1164"},
               files={"wide": ("a.jpg", enc(scene()), "image/jpeg"),
                      "zoom": ("b.jpg", enc(scene()), "image/jpeg")})
    assert r.status_code == 200, r.text
    assert r.json()["name"] == "white paper napkin" and r.json()["part"] == ""
    assert seen[0]["model"] == "google/gemini-2.5-flash-lite"
    content = seen[0]["messages"][0]["content"]
    assert content[0]["text"] == P.DETECT_MICRO_NAME_PROMPT
    assert len([x for x in content if x["type"] == "image_url"]) == 2
    r = c.post("/v1/macro/micro-part", data={"device_id": "dev_v1164", "parent": "white paper napkin"},
               files={"one_x": ("a.jpg", enc(scene()), "image/jpeg"),
                      "step": ("b.jpg", enc(scene()), "image/jpeg")})
    assert r.json() == {"part": "surface", "in_scene": True}
    assert seen[1]["model"] == "google/gemini-2.5-flash-lite"
    assert "Which part or side of the white paper napkin" in seen[1]["messages"][0]["content"][0]["text"]
    assert c.get("/v1/account", params={"device_id": "dev_v1164"}).json() == before  # free
    assert not up.calls
