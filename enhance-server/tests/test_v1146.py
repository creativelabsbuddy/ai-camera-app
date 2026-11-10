import prompts as P


def test_macro_prompt_lighter_and_general():
    t = P.MACRO_PROMPT
    assert "less intense than a microscope" in t
    assert "do not add any new objects" in t
    assert "strongly" not in t and "{subject}" not in t
    assert P.MACRO_MICROSCOPE_PHOTO_PROMPT.startswith("Based on the last photo")


def test_context_line_order():
    assert "last image is the final frame" in P.MACRO_CONTEXT_LINE
