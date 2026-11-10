import prompts as P
import main as M


def test_spot_model_and_part_models():
    assert P.DETECT_SPOT_MODEL == "google/gemini-2.5-flash"
    assert P.DETECT_MODEL == "google/gemini-2.5-flash-lite"
    assert M.detect_payload("x", [], 10)["model"] == P.DETECT_MODEL
    assert M.detect_payload("x", [], 10, P.DETECT_SPOT_MODEL)["model"] == "google/gemini-2.5-flash"


def test_detect_prompts_center_of_red_box():
    for p in (P.DETECT_PART_PROMPT, P.DETECT_SPOT_PROMPT):
        # v11.32: describe the box (whole object / several parts / one part).
        assert "Describe what is in the red box" in p
        assert "never just the object" not in p


def test_version():
    assert M.app.version >= "11.1.22"
