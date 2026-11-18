import prompts as P
import main as M

# v11.58 material-aware texts
EXT = P.MACRO_EXTREME_PROMPT
ULT = P.MACRO_ULTRA_PROMPT


def test_prompts_and_admin_defaults():
    assert P.MACRO_EXTREME_PROMPT == EXT
    assert P.MACRO_ULTRA_PROMPT == ULT
    assert P.DEFAULT_MODE_PROMPTS["macro_extreme"] == EXT
    assert P.DEFAULT_MODE_PROMPTS["macro_ultra"] == ULT


def test_spot_filled_and_case():
    assert P.deep_prompt(ULT, "eye", "brown iris").startswith(
        "Close-up of brown iris on the eye under a scanning electron microscope")
    assert P.deep_prompt(EXT, "eye", "brown iris").startswith(
        "A tiny area of brown iris on the eye under a light microscope at 1000x")
    # the part already names the object → no " on the …"
    assert P.deep_prompt(EXT, "eye", "brown eye iris").startswith(
        "A tiny area of brown eye iris under a light microscope")
    assert P.deep_prompt("{spot} x", "eye", "brown iris") == "Brown iris x"


def test_inputs_unchanged_and_version():
    assert P.macro_input_plan("extreme") == (2, None)  # v11.40
    assert P.macro_input_plan("ultra") == (2, None)  # v11.40
    assert M.app.version >= "11.1.23"
