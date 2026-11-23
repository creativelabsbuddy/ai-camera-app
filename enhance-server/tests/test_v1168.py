"""v11.68: restore enhance prompt; no-invent line on zoom Beyond clear range
and Pro AI Night. App/server string parity."""
import os

import prompts as P
from test_server import APP, _dart_string_const
from test_v11 import enc, env, scene  # noqa: F401


RESTORE = (
    "Restore this photo: remove blur, noise, pixelation and compression artifacts, "
    "and recover natural fine detail with realistic textures, without oversharpening "
    "or plastic-looking skin. Keep the exact same scene, framing, people, objects, "
    "colours and identity; do not add, remove or redesign anything, and do not invent "
    "facial details. Where details are irrecoverable, preserve natural softness rather "
    "than inventing information."
)
NO_INVENT = (
    "Where details are irrecoverable, preserve natural softness rather than inventing "
    "information; never replace unreadable text with blank shapes."
)


def _dart(name_file):
    path = os.path.join(APP, "lib", "services", name_file)
    if not os.path.exists(path):
        import pytest
        pytest.skip("app source not present")
    return open(path, encoding="utf-8").read()


def test_universal_restore_prompt_exact_and_parity():
    assert P.UNIVERSAL_ENHANCE_PROMPT == RESTORE
    assert P.LOCKED_ENHANCE_PROMPT == RESTORE
    src = _dart("prompt_builder.dart")
    assert _dart_string_const(src, "kUniversalEnhancePrompt") == P.UNIVERSAL_ENHANCE_PROMPT
    assert _dart_string_const(src, "kNoInventLine") == P.NO_INVENT_LINE == NO_INVENT
    assert _dart_string_const(src, "kPhotoCleanupPrompt") == P.PHOTO_CLEANUP_PROMPT
    assert P.build_prompt() == RESTORE
    assert P.build_prompt(tier="hd") == RESTORE
    p = P.build_prompt(tier="full_hd")
    assert p.startswith(RESTORE)
    assert "Full HD" in p
    ctx = P.build_prompt(has_context=True)
    assert ctx.startswith(RESTORE) and P.CONTEXT_IMAGE_SENTENCE in ctx
    boxed = P.build_prompt(has_context=True, context_boxed=True)
    assert boxed.startswith(RESTORE) and P.CONTEXT_BOXED_SENTENCE in boxed


def test_portrait_macro_extreme_ultra_untouched():
    assert P.PORTRAIT_ENHANCE_PROMPT.startswith("Clean up and sharpen this image")
    assert "natural bokeh" in P.PORTRAIT_ENHANCE_PROMPT
    assert RESTORE not in P.PORTRAIT_ENHANCE_PROMPT
    assert NO_INVENT not in P.PORTRAIT_ENHANCE_PROMPT
    assert "light microscope at 100x" in P.MACRO_MICROSCOPE_PROMPT
    for t in (P.MACRO_PROMPT, P.MACRO_CLOSE_PROMPT, P.MACRO_MICROSCOPE_PROMPT,
              P.MACRO_EXTREME_PROMPT, P.MACRO_ULTRA_PROMPT):
        assert RESTORE not in t
        assert NO_INVENT not in t


def test_zoom_beyond_clear_appends_no_invent():
    assert P.ZOOM_CLEAN_PROMPT == P.PHOTO_CLEANUP_PROMPT + " " + P.NO_INVENT_LINE
    assert P.ZOOM_CLEAN_PROMPT != P.UNIVERSAL_ENHANCE_PROMPT
    assert P.ZOOM_SOURCE_PROMPT.endswith(P.NO_INVENT_LINE)
    assert P.ZOOM_SOURCE_PROMPT.startswith("The first image is a sharp photo")
    assert "only to match the framing" in P.ZOOM_SOURCE_PROMPT
    assert P.ZOOM_LADDER_PROMPT.startswith(P.PHOTO_CLEANUP_PROMPT)
    assert P.ZOOM_LADDER_PROMPT.endswith(P.NO_INVENT_LINE)
    src = _dart("prompt_builder.dart")
    assert _dart_string_const(src, "kZoomCleanPrompt") == P.ZOOM_CLEAN_PROMPT
    assert _dart_string_const(src, "kZoomSourcePrompt") == P.ZOOM_SOURCE_PROMPT
    assert _dart_string_const(src, "kZoomLadderPrompt") == P.ZOOM_LADDER_PROMPT
    # clear-ref is still a dynamic addition after the zoom source prompt
    assert P.CLEAR_REF_LINE not in P.ZOOM_SOURCE_PROMPT
    with_ref = P.ZOOM_SOURCE_PROMPT + " " + P.CLEAR_REF_LINE
    assert with_ref.endswith(P.CLEAR_REF_LINE)
    assert P.NO_INVENT_LINE in with_ref


def test_zoom_clean_and_source_requests(env):  # noqa: F811
    from tests.test_v1130 import _post
    c, _, _, up = env
    up.reply = enc(scene(1200, 900), "PNG")
    r = _post(c, "dev_v1168a", {"zoom": "20", "optical_limit": "3", "zoom_clean": "true"}, 0)
    assert r.status_code == 200, r.text
    assert up.calls[-1]["prompt"] == P.ZOOM_CLEAN_PROMPT
    assert up.calls[-1]["prompt"].endswith(P.NO_INVENT_LINE)

    source, final = scene(600, 450, seed=4), scene(1200, 900, seed=4)
    up.reply = enc(source, "PNG")
    r = c.post(
        "/v1/enhance",
        data={"device_id": "dev_v1168b", "quality": "hd", "zoom": "22",
              "optical_limit": "10", "zoom_source": "true", "clear_ref": "true"},
        files=[("image", ("s.jpg", enc(source), "image/jpeg")),
               ("steps", ("f.jpg", enc(final), "image/jpeg"))],
    )
    # purchase first
    if r.status_code == 402:
        c.post("/v1/purchase", json={"device_id": "dev_v1168b", "product_id": "pack_25"})
        r = c.post(
            "/v1/enhance",
            data={"device_id": "dev_v1168b", "quality": "hd", "zoom": "22",
                  "optical_limit": "10", "zoom_source": "true", "clear_ref": "true"},
            files=[("image", ("s.jpg", enc(source), "image/jpeg")),
                   ("steps", ("f.jpg", enc(final), "image/jpeg"))],
        )
    assert r.status_code == 200, r.text
    assert up.calls[-1]["prompt"] == P.ZOOM_SOURCE_PROMPT + " " + P.CLEAR_REF_LINE
    assert P.NO_INVENT_LINE in up.calls[-1]["prompt"]


def test_night_prompt_appends_no_invent(env):  # noqa: F811
    assert P.NIGHT_PROMPT.startswith("A natural night photograph")
    assert P.NIGHT_PROMPT.endswith(P.NO_INVENT_LINE)
    src = _dart("prompt_builder.dart")
    assert _dart_string_const(src, "kNightPrompt") == P.NIGHT_PROMPT
    night_p = P.build_prompt(night=True)
    assert night_p == RESTORE + " " + NO_INVENT
    assert "A natural night photograph" not in night_p

    c, _, _, up = env
    r = c.post("/v1/purchase", json={"device_id": "dev_v1168n", "product_id": "pack_25"})
    assert r.status_code == 200
    up.reply = enc(scene().point(lambda v: min(255, int(v * 1.3 + 8))), "PNG")
    r = c.post(
        "/v1/enhance",
        data={"device_id": "dev_v1168n", "quality": "hd", "mode": "night"},
        files={"image": ("n.jpg", enc(scene()), "image/jpeg")},
    )
    assert r.status_code == 200, r.text
    p = up.calls[-1]["prompt"]
    assert p.startswith(P.UNIVERSAL_ENHANCE_PROMPT)
    assert P.NO_INVENT_LINE in p
    assert P.NIGHT_PROMPT not in p  # the night paragraph is still not injected
