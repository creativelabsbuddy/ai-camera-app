import prompts as P
import main as M

# v11.29 texts
EXT = ("A tiny area of {spot} under a light microscope at 1000x magnification, microscopic "
       "cells and structure filling the frame. One single full-frame image, no text or "
       "labels. Photorealistic.")
ULT = ("Close-up of {spot} under a scanning electron microscope at 2000x magnification. "
       "Show how it looks. One single full-frame image, no text or labels. Photorealistic.")


def test_prompts_and_admin_defaults():
    assert P.MACRO_EXTREME_PROMPT == EXT
    assert P.MACRO_ULTRA_PROMPT == ULT
    assert P.DEFAULT_MODE_PROMPTS["macro_extreme"] == EXT
    assert P.DEFAULT_MODE_PROMPTS["macro_ultra"] == ULT


def test_spot_filled_and_case():
    assert P.deep_prompt(ULT, "eye", "brown iris").startswith(
        "Close-up of brown iris under a scanning electron microscope")
    assert P.deep_prompt(EXT, "eye", "brown iris").startswith(
        "A tiny area of brown iris under a light microscope at 1000x")
    assert P.deep_prompt("{spot} x", "eye", "brown iris") == "Brown iris x"


def test_inputs_unchanged_and_version():
    assert P.macro_input_plan("extreme") == (2, None)  # v11.40
    assert P.macro_input_plan("ultra") == (2, None)  # v11.40
    assert M.app.version >= "11.1.23"
