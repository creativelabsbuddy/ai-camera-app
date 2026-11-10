"""v11.53 video generation history (admin "Video history").

SQLite next to the ledger by default; when SUPABASE_URL +
SUPABASE_SERVICE_ROLE_KEY are set (STYLES_BACKEND=supabase) rows go to
public.video_jobs in Supabase. Logging never breaks a request.
"""
from __future__ import annotations

import datetime as dt
import logging
import sqlite3
import threading
from typing import Optional

import httpx

log = logging.getLogger("enhance.videolog")
_COLS = ("job_key", "device_id", "provider", "kind", "seconds", "resolution", "aspect_ratio",
         "style_id", "credits", "cost_inr", "status", "charged", "error", "created", "updated")


def _now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


class SqliteVideoLog:
    def __init__(self, path: str):
        self._db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self._lock = threading.RLock()
        self._db.execute("""CREATE TABLE IF NOT EXISTS video_jobs(
            job_key TEXT PRIMARY KEY, device_id TEXT, provider TEXT, kind TEXT, seconds INTEGER,
            resolution TEXT, aspect_ratio TEXT, style_id TEXT, credits INTEGER, cost_inr REAL,
            status TEXT, charged INTEGER DEFAULT 0, error TEXT, created TEXT, updated TEXT)""")

    def add(self, row: dict) -> None:
        r = {**{c: None for c in _COLS}, **row, "created": _now(), "updated": _now()}
        with self._lock:
            self._db.execute(f"INSERT OR REPLACE INTO video_jobs({','.join(_COLS)}) VALUES({','.join('?' * len(_COLS))})",
                             [r[c] for c in _COLS])

    def update(self, job_key: str, **fields) -> None:
        fields["updated"] = _now()
        sets = ", ".join(f"{k}=?" for k in fields)
        with self._lock:
            self._db.execute(f"UPDATE video_jobs SET {sets} WHERE job_key=?", [*fields.values(), job_key])

    def recent(self, n: int = 200) -> list:
        cur = self._db.execute(f"SELECT {','.join(_COLS)} FROM video_jobs ORDER BY created DESC LIMIT ?", (n,))
        return [dict(zip(_COLS, x)) for x in cur.fetchall()]


class SupabaseVideoLog:
    def __init__(self, url: str, key: str, transport=None):
        self._c = httpx.Client(base_url=url.rstrip("/"), timeout=10, transport=transport,
                               headers={"apikey": key, "Authorization": f"Bearer {key}"})

    def add(self, row: dict) -> None:
        self._c.post("/rest/v1/video_jobs", json={**row, "created": _now(), "updated": _now()},
                     headers={"Prefer": "resolution=merge-duplicates,return=minimal"})

    def update(self, job_key: str, **fields) -> None:
        fields["updated"] = _now()
        self._c.patch("/rest/v1/video_jobs", params={"job_key": f"eq.{job_key}"}, json=fields)

    def recent(self, n: int = 200) -> list:
        r = self._c.get("/rest/v1/video_jobs", params={"select": "*", "order": "created.desc", "limit": str(n)})
        return r.json() if r.status_code == 200 else []


class SafeLog:
    """Wraps a backend so logging errors never fail a video request."""

    def __init__(self, inner):
        self.inner = inner

    def add(self, row: dict) -> None:
        try:
            self.inner.add(row)
        except Exception as e:  # noqa: BLE001
            log.warning("video log add failed: %s", type(e).__name__)

    def update(self, job_key: str, **fields) -> None:
        try:
            self.inner.update(job_key, **fields)
        except Exception as e:  # noqa: BLE001
            log.warning("video log update failed: %s", type(e).__name__)

    def recent(self, n: int = 200) -> list:
        try:
            return self.inner.recent(n)
        except Exception:  # noqa: BLE001
            return []
