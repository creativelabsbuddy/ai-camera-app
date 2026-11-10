import main
import prompts as P
from test_v11 import env, scene, enc  # noqa: F401  (fixture + helpers)


def _post_spot(c):
    return c.post("/v1/macro/spot", data={"device_id": "dev_v1129", "subject": "brown human eye"},
                  files={"overview": ("a.jpg", enc(scene()), "image/jpeg"),
                         "closer": ("b.jpg", enc(scene()), "image/jpeg")})


def test_spot_payload_thinking_off_200_tokens(env, monkeypatch):
    c, *_ = env
    seen = []

    async def fake(payload):
        seen.append(payload)
        main._LAST_FINISH["v"] = "stop"
        return '{"object": "brown human eye", "part": "brown iris", "in_scene": true}'

    monkeypatch.setattr(main, "call_vision", fake)
    r = _post_spot(c).json()
    assert r["part"] == "brown iris" and r["model"] == "flash"
    assert len(seen) == 1
    assert seen[0]["model"] == "google/gemini-2.5-flash"
    assert seen[0]["reasoning"] == {"max_tokens": 0}
    assert seen[0]["max_tokens"] == 200


def test_spot_empty_retries_once_on_lite(env, monkeypatch):
    c, *_ = env
    seen = []

    async def fake(payload):
        seen.append(payload)
        if payload["model"] == "google/gemini-2.5-flash":
            main._LAST_FINISH["v"] = "length"
            return ""
        return '{"object": "brown human eye", "part": "brown iris", "in_scene": true}'

    monkeypatch.setattr(main, "call_vision", fake)
    r = _post_spot(c).json()
    assert [p["model"] for p in seen] == ["google/gemini-2.5-flash", "google/gemini-2.5-flash-lite"]
    assert "reasoning" not in seen[1]
    assert r["part"] == "brown iris" and r["model"] == "lite"


def test_spot_cut_off_reply_retries(env, monkeypatch):
    c, *_ = env
    seen = []

    async def fake(payload):
        seen.append(payload)
        if payload["model"] == "google/gemini-2.5-flash":
            main._LAST_FINISH["v"] = "length"
            return '{"object": "brown hu'
        main._LAST_FINISH["v"] = "stop"
        return '{"object": "brown human eye", "part": "black pupil", "in_scene": true}'

    monkeypatch.setattr(main, "call_vision", fake)
    assert _post_spot(c).json()["part"] == "black pupil"
    assert len(seen) == 2


def test_part_and_subject_stay_lite_without_reasoning():
    p = main.detect_payload("x", [], P.DETECT_MAX_TOKENS)
    assert p["model"] == P.DETECT_MODEL and "reasoning" not in p


def test_prompts_and_version():
    assert P.MACRO_ULTRA_PROMPT.startswith("Close-up of {spot} under a scanning electron microscope at 2000x")
    assert P.MACRO_EXTREME_PROMPT.startswith("A tiny area of {spot} under a light microscope at 1000x")
    assert P.DEFAULT_MODE_PROMPTS["macro_extreme"] == P.MACRO_EXTREME_PROMPT
    assert P.DEFAULT_MODE_PROMPTS["macro_ultra"] == P.MACRO_ULTRA_PROMPT
    assert tuple(map(int, main.app.version.split("."))) >= (11, 1, 24)
    assert main.SPOT_TIMEOUT + main.SPOT_RETRY_TIMEOUT < 10
