import main as M
import prompts as P


def test_prompt_and_vague():
    assert "common name of the object or material" in P.DETECT_BOX_PROMPT
    assert "at most 6 words" in P.DETECT_BOX_PROMPT
    assert "first image is a wider view" in P.DETECT_BOX_WIDE_LINE
    assert P.is_vague_detect("white textured surface with many small circles")
    assert not P.is_vague_detect("sugar crystals")
    assert not P.macro_text_only("microscope", "close-up", "gray dots")
    assert not P.macro_text_only("extreme", None, "pattern")
    assert P.macro_text_only("ultra", None, "tree bark")
    assert M.DETECT_LONG == 768


def test_mirrors_app():
    import os
    import re
    src = open(os.path.join(os.path.dirname(__file__), "..", "..", "ai_camera", "lib",
                            "services", "mode_prompts.dart"), encoding="utf-8").read()
    words = set(re.findall(r"'([a-z-]+)'", src.split("kVagueDetectWords")[1].split("};")[0]))
    assert words == P.VAGUE_DETECT_WORDS
