import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


@pytest.fixture(autouse=True)
def _isolated_v11_stores(tmp_path):
    """Every test gets fresh prompt / pose stores in tmp (never ./*.sqlite3)."""
    import main
    main.reset_mode_prompts(str(tmp_path / "mode_prompts.sqlite3"))
    main.reset_poses(str(tmp_path / "poses_auto.sqlite3"), str(tmp_path / "media" / "poses_auto"), seed=False)
    yield


@pytest.fixture(autouse=True)
def _no_network(monkeypatch):
    """Tests never reach OpenRouter (or any network): no key, and every
    real httpx request raises."""
    import httpx
    import main

    def _blocked(*a, **k):
        raise RuntimeError("network blocked in tests")

    monkeypatch.setattr(main, "_api_key", lambda: _blocked(), raising=False)
    monkeypatch.setattr(httpx.AsyncHTTPTransport, "handle_async_request", _blocked)
    monkeypatch.setattr(httpx.HTTPTransport, "handle_request", _blocked)
    yield
