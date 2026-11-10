import datetime as dt
import ledger as L
import prompts as P


def test_macro_credit_mapping():
    assert P.MACRO_LEVEL_CREDITS == {"macro": 4, "close": 4, "microscope": 5, "extreme": 2, "ultra": 2}  # v11.33 HD


def test_input_plan_per_level():
    assert P.macro_input_plan("macro") == (2, 1536)  # v11.40
    assert P.macro_input_plan("close") == (2, 1536)  # v11.40
    assert P.macro_input_plan("microscope") == (1, 1536)
    assert P.macro_input_plan("extreme") == (2, None)  # v11.40
    assert P.macro_input_plan("ultra") == (2, None)  # v11.40


def test_spec_credits_override_used():
    now = dt.datetime(2026, 10, 14, tzinfo=dt.timezone.utc)
    s = L.State(free_daily=0, free_daily_date="2026-10-14", pack_credits=10)
    d = L.decide(s, L.Spec(tier="full_hd", credits=5), now)
    assert d.allowed and d.credits == 5
    d = L.decide(s, L.Spec(tier="full_hd"), now)
    assert d.credits == L.TIERS["full_hd"][1]
