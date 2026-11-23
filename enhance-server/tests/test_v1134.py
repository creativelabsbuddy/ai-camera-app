"""v11.34 zoom clean-up prompt (all phones, 2x+)."""
import prompts as P
from tests.test_v1130 import _post  # noqa: F401
from tests.test_v11 import env  # noqa: F401


def test_prompt_text():
    assert P.ZOOM_CLEAN_PROMPT != P.UNIVERSAL_ENHANCE_PROMPT
    assert P.ZOOM_CLEAN_PROMPT == P.PHOTO_CLEANUP_PROMPT + " " + P.NO_INVENT_LINE
    assert P.PHOTO_CLEANUP_PROMPT == "Clean up and sharpen this image, with a natural tone. Keep every face exactly the same person: same face shape, eyes, nose, lips, skin tone and expression. Do not change, add or remove anything; keep all shapes, text and details as they are."
    assert P.zoom_ladder_prompt(None, None, refs=False) == P.ZOOM_CLEAN_PROMPT
    assert P.ZOOM_LADDER_PROMPT.startswith(P.PHOTO_CLEANUP_PROMPT)
    assert P.ZOOM_LADDER_PROMPT.endswith(P.NO_INVENT_LINE)


def test_flagship_zoom_clean_flag(env):
    c, _, _, up = env
    from tests.test_v11 import enc, scene
    up.reply = enc(scene(1200, 900), "PNG")  # v11.59: a result that keeps the photo
    r = _post(c, "dev_v1134", {"zoom": "20", "optical_limit": "3", "zoom_clean": "true"}, 0)
    assert r.status_code == 200
    assert up.calls[-1]["prompt"] == P.ZOOM_CLEAN_PROMPT
    assert len(up.calls[-1].get("input_references", [])) <= 1


def test_app_prompt_matches_server():
    import os
    import re
    path = os.path.join(os.path.dirname(__file__), "..", "..", "ai_camera", "lib", "services",
                        "prompt_builder.dart")
    src = open(path, encoding="utf-8").read()
    # v11.68: zoom clean keeps the v11.63 cleanup line and appends NO_INVENT_LINE.
    from test_server import _dart_string_const
    assert _dart_string_const(src, "kZoomCleanPrompt") == P.ZOOM_CLEAN_PROMPT
    assert _dart_string_const(src, "kPhotoCleanupPrompt") == P.PHOTO_CLEANUP_PROMPT
    assert _dart_string_const(src, "kNoInventLine") == P.NO_INVENT_LINE
