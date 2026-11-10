"""v11: admin-editable hidden prompts for Pro AI modes (portrait, night,
macro) and the premium color filters ("filter:<id>"). Defaults live in
prompts.DEFAULT_MODE_PROMPTS; an admin override is stored here. Never sent
to the app (the app only sends mode / filter ids)."""
from __future__ import annotations

import sqlite3
import threading
import time
from typing import Optional

import prompts as P

MAX_PROMPT_CHARS = 2000


class ModePromptStore:
    def __init__(self, db_path: str):
        self._db = sqlite3.connect(db_path, check_same_thread=False, isolation_level=None)
        self._db.execute("PRAGMA journal_mode=WAL")
        self._lock = threading.RLock()
        self._db.execute(
            "CREATE TABLE IF NOT EXISTS mode_prompts(key TEXT PRIMARY KEY, prompt TEXT NOT NULL, "
            "updated_at REAL NOT NULL)")

    @staticmethod
    def keys() -> list[str]:
        return list(P.DEFAULT_MODE_PROMPTS)

    def overridden(self, key: str) -> Optional[str]:
        r = self._db.execute("SELECT prompt FROM mode_prompts WHERE key=?", (key,)).fetchone()
        return r[0] if r else None

    def get(self, key: str) -> str:
        """Override if set, else the default ("" for unknown keys)."""
        o = self.overridden(key)
        return o if o is not None else P.DEFAULT_MODE_PROMPTS.get(key, "")

    def set(self, key: str, prompt: str) -> None:
        if key not in P.DEFAULT_MODE_PROMPTS:
            raise ValueError("unknown prompt key")
        text = " ".join((prompt or "").split())
        if not text:
            raise ValueError("prompt must not be empty (use Reset for the default)")
        if len(text) > MAX_PROMPT_CHARS:
            raise ValueError(f"prompt too long (max {MAX_PROMPT_CHARS} characters)")
        with self._lock:
            self._db.execute(
                "INSERT INTO mode_prompts(key, prompt, updated_at) VALUES(?,?,?) ON CONFLICT(key) "
                "DO UPDATE SET prompt=excluded.prompt, updated_at=excluded.updated_at",
                (key, text, time.time()))

    # v11.33: small JSON settings (e.g. Macro credits) in the same table.
    def get_config(self, key: str) -> Optional[str]:
        return self.overridden(f"config:{key}")

    def set_config(self, key: str, value: str) -> None:
        with self._lock:
            self._db.execute(
                "INSERT INTO mode_prompts(key, prompt, updated_at) VALUES(?,?,?) ON CONFLICT(key) "
                "DO UPDATE SET prompt=excluded.prompt, updated_at=excluded.updated_at",
                (f"config:{key}", value, time.time()))

    def reset_config(self, key: str) -> None:
        with self._lock:
            self._db.execute("DELETE FROM mode_prompts WHERE key=?", (f"config:{key}",))

    def reset(self, key: str) -> None:
        with self._lock:
            self._db.execute("DELETE FROM mode_prompts WHERE key=?", (key,))
