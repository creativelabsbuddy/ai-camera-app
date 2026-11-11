import main
import prompts as P
from test_v11 import env, scene, enc  # noqa: F401  (fixture + helpers)


def test_part_prompt_describes_box_not_single_part():
    for p in (P.DETECT_PART_PROMPT, P.DETECT_SPOT_PROMPT):
        assert "the whole object if all of it is visible (e.g. eye)" in p
        assert "eye, iris and eyelashes" in p
        assert "one part only if that part alone fills the box" in p
    assert '"fill"' in P.DETECT_PART_PROMPT and '"whole"' in P.DETECT_PART_PROMPT
    assert '"fill"' in P.DETECT_SUBJECT_PROMPT


def test_parse_fill():
    assert P.parse_fill('{"part": "x", "fill": 0.6, "whole": true}') == (0.6, True)
    assert P.parse_fill('{"fill": 1.4, "whole": false}') == (1.0, False)
    assert P.parse_fill('{"fill": "a"}') == (None, None)
    assert P.parse_fill("plain") == (None, None)


def test_part_endpoint_returns_fill(env, monkeypatch):
    c, *_ = env

    async def fake(payload):
        return ('{"object": "brown human eye", "part": "brown eye, iris and eyelashes", '
                '"fill": 0.7, "whole": true, "in_scene": true}')

    monkeypatch.setattr(main, "call_vision", fake)
    r = c.post("/v1/macro/part", data={"device_id": "dev_v1132", "parent": "brown human eye"},
               files={"one_x": ("a.jpg", enc(scene()), "image/jpeg"),
                      "step": ("b.jpg", enc(scene()), "image/jpeg")}).json()
    assert r["part"] == "brown eye, iris and eyelashes"
    assert r["fill"] == 0.7 and r["whole"] is True


def test_version():
    assert main.app.version == "11.1.59"  # v11.59
