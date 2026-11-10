import prompts as P


def test_night_prompt_general():
    t = P.NIGHT_PROMPT
    assert t.startswith("A natural night photograph")
    for w in ("sky", "city", "street", "lamp"):
        assert w not in t.lower()
