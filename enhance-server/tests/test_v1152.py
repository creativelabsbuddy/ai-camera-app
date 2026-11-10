"""v11.52: a request the phone abandoned (Cancel) is never charged."""
from fastapi import Request

from tests.test_server import account, enhance, env  # noqa: F401


def test_client_disconnect_before_result_is_not_charged(env, monkeypatch):  # noqa: F811
    c, _, up = env
    async def gone(self):
        return True
    monkeypatch.setattr(Request, "is_disconnected", gone)
    r = enhance(c)
    assert r.status_code == 499
    assert len(up.calls) >= 1  # the AI ran, but…
    assert account(c)["state"]["free_daily"] == 2  # …nothing was charged
