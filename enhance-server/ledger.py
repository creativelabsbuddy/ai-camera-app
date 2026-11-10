"""Credits / Pro / starter-trial rules + SQLite ledger.

Rules mirror ai_camera/lib/services/entitlements.dart 1:1 (both unit tested):
* Free: 2 HD credits/day, reset at IST midnight, SET (no rollover/stacking),
  only pay for HD.
* Pro ₹99: 100 credits per 30-day period (reset, no rollover) + Pro features.
* Packs: never expire. Cost = tier only (1/2/4/8).
* Starter trials (once per device): high_zoom, ai_filter, library_style,
  uhd_4k. A shot using a trial is free. Pro never burns trials.
* Nothing is charged until the AI result succeeded (commit after success).
* Looks (v9 AI styles + "Describe a change"): available to everyone; cost =
  style credit cost (or quality-tier credits for a custom change) × number of
  images. Paid from free daily → Pro → pack credits. v11.57: no free-first
  style trial — every style is charged. Pro-only styles need Pro.
"""
from __future__ import annotations

import datetime as dt
import json
import sqlite3
import threading
from dataclasses import dataclass, field, replace
from typing import Optional

FREE_DAILY = 2
PRO_PERIOD = dt.timedelta(days=30)
IST = dt.timezone(dt.timedelta(hours=5, minutes=30))

TIERS = {
    # id: (label, credits, flare quality, flare resolution, min long side)
    "hd": ("HD", 1, "low", "1K", 1024),
    "full_hd": ("Full HD", 2, "medium", "1.5K", 1920),
    "ultra_hd": ("Ultra HD", 4, "high", "2K", 2560),
    "4k": ("4K", 8, "high", "4K", 3840),
}
PREMIUM_TIERS = {"ultra_hd", "4k"}

TRIALS = ("high_zoom", "ai_filter", "library_style", "uhd_4k")

PRODUCTS = {
    "pro_monthly": {"title": "Pro · 100 credits / month", "price_inr": 99, "credits": 100, "kind": "subscription"},
    "pack_25": {"title": "25 credits", "price_inr": 49, "credits": 25, "kind": "pack"},
    "pack_60": {"title": "60 credits", "price_inr": 99, "credits": 60, "kind": "pack"},
    "pack_140": {"title": "140 credits", "price_inr": 199, "credits": 140, "kind": "pack"},
    "shot_1": {"title": "1 shot (1 credit)", "price_inr": 5, "credits": 1, "kind": "pack"},
}


def ist_date(t: dt.datetime) -> str:
    return t.astimezone(IST).strftime("%Y-%m-%d")


def _iso(t: Optional[dt.datetime]) -> Optional[str]:
    if t is None:
        return None
    return t.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def _parse(s: Optional[str]) -> Optional[dt.datetime]:
    if not s:
        return None
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(dt.timezone.utc)


@dataclass(frozen=True)
class State:
    free_daily: int
    free_daily_date: str
    sub_credits: int = 0
    pro_until: Optional[dt.datetime] = None
    pack_credits: int = 0
    trials_used: frozenset = field(default_factory=frozenset)

    @staticmethod
    def initial(now: dt.datetime) -> "State":
        return State(free_daily=FREE_DAILY, free_daily_date=ist_date(now))

    def is_pro(self, now: dt.datetime) -> bool:
        return self.pro_until is not None and now < self.pro_until

    def total(self, now: dt.datetime) -> int:
        return self.free_daily + (self.sub_credits if self.is_pro(now) else 0) + self.pack_credits

    def to_json(self) -> dict:
        return {
            "free_daily": self.free_daily,
            "free_daily_date": self.free_daily_date,
            "sub_credits": self.sub_credits,
            "pro_until": _iso(self.pro_until),
            "pack_credits": self.pack_credits,
            "trials_used": sorted(self.trials_used),
        }


def refresh(s: State, now: dt.datetime) -> State:
    today = ist_date(now)
    if s.free_daily_date != today:
        s = replace(s, free_daily=FREE_DAILY, free_daily_date=today)
    if s.pro_until is not None and not s.is_pro(now) and s.sub_credits != 0:
        s = replace(s, sub_credits=0)
    return s


@dataclass(frozen=True)
class Spec:
    tier: str = "hd"
    zoom: float = 1.0
    optical_limit: float = 1.0
    ai_filter: bool = False
    library_style: bool = False
    custom_style: bool = False
    custom_prompt: bool = False
    # v11.26 Macro: credits by level (overrides the tier's credits).
    credits: Optional[int] = None

    @property
    def high_zoom(self) -> bool:
        return self.zoom == self.zoom and self.zoom > max(1.0, self.optical_limit) * 1.02


@dataclass(frozen=True)
class Decision:
    allowed: bool
    reason: Optional[str] = None
    trials: tuple = ()
    from_free: int = 0
    from_sub: int = 0
    from_pack: int = 0

    @property
    def credits(self) -> int:
        return self.from_free + self.from_sub + self.from_pack


def decide(s: State, spec: Spec, now: dt.datetime) -> Decision:
    pro = s.is_pro(now)
    trials = []
    if not pro:
        if spec.custom_prompt or spec.custom_style:
            return Decision(False, "prompt_needs_pro")
        if spec.high_zoom:
            if "high_zoom" in s.trials_used:
                return Decision(False, "zoom_needs_pro")
            trials.append("high_zoom")
        if spec.library_style:
            if "library_style" in s.trials_used:
                return Decision(False, "style_needs_pro")
            trials.append("library_style")
        if spec.ai_filter:
            if "ai_filter" in s.trials_used:
                return Decision(False, "filter_needs_pro")
            trials.append("ai_filter")
        if spec.tier in PREMIUM_TIERS and "uhd_4k" not in s.trials_used:
            trials.append("uhd_4k")
    if trials:
        return Decision(True, trials=tuple(trials))
    remaining = spec.credits if spec.credits is not None else TIERS[spec.tier][1]
    from_free = min(s.free_daily, remaining) if spec.tier == "hd" else 0
    remaining -= from_free
    from_sub = min(s.sub_credits, remaining) if pro else 0
    remaining -= from_sub
    from_pack = min(s.pack_credits, remaining)
    remaining -= from_pack
    if remaining > 0:
        return Decision(False, "no_credits")
    return Decision(True, from_free=from_free, from_sub=from_sub, from_pack=from_pack)


MAX_VARIATIONS = 4


@dataclass(frozen=True)
class LookSpec:
    """One AI look generation (style apply or custom change)."""
    credit_cost: int          # per image
    variations: int = 1       # images requested (1 or 4)
    pro_only: bool = False    # style flagged Pro-only by the admin
    is_style: bool = True     # False → "Describe a change…" custom prompt
    allow_trial: bool = True  # False when committing a partial variations batch

    @property
    def total_cost(self) -> int:
        return max(0, self.credit_cost) * max(1, self.variations)


def decide_look(s: State, spec: LookSpec, now: dt.datetime) -> Decision:
    pro = s.is_pro(now)
    if not 1 <= spec.variations <= MAX_VARIATIONS:
        return Decision(False, "bad_request")
    if spec.pro_only and not pro:
        return Decision(False, "style_needs_pro")
    # v11.57: no free-first-style trial — every style costs its credit_cost.
    remaining = spec.total_cost
    from_free = min(s.free_daily, remaining)
    remaining -= from_free
    from_sub = min(s.sub_credits, remaining) if pro else 0
    remaining -= from_sub
    from_pack = min(s.pack_credits, remaining)
    remaining -= from_pack
    if remaining > 0:
        return Decision(False, "no_credits")
    return Decision(True, from_free=from_free, from_sub=from_sub, from_pack=from_pack)


def decide_any(s: State, spec, now: dt.datetime) -> Decision:
    return decide_look(s, spec, now) if isinstance(spec, LookSpec) else decide(s, spec, now)


def apply_decision(s: State, d: Decision) -> State:
    if not d.allowed:
        return s
    return replace(
        s,
        free_daily=max(0, s.free_daily - d.from_free),
        sub_credits=max(0, s.sub_credits - d.from_sub),
        pack_credits=max(0, s.pack_credits - d.from_pack),
        trials_used=frozenset(s.trials_used | set(d.trials)),
    )


def apply_purchase(s: State, product_id: str, now: dt.datetime) -> State:
    p = PRODUCTS[product_id]
    if p["kind"] == "subscription":
        base = s.pro_until if (s.pro_until is not None and s.is_pro(now)) else now
        return replace(s, pro_until=base + PRO_PERIOD, sub_credits=p["credits"])
    return replace(s, pack_credits=s.pack_credits + p["credits"])


class Ledger:
    """SQLite-backed per-device state. All mutations are serialized."""

    def __init__(self, path: str):
        self._db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self._db.execute("PRAGMA journal_mode=WAL")
        self._lock = threading.RLock()
        self._db.executescript(
            """
            CREATE TABLE IF NOT EXISTS accounts(
              device_id TEXT PRIMARY KEY,
              free_daily INTEGER NOT NULL,
              free_daily_date TEXT NOT NULL,
              sub_credits INTEGER NOT NULL DEFAULT 0,
              pro_until TEXT,
              pack_credits INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS trials(
              device_id TEXT NOT NULL,
              trial TEXT NOT NULL,
              used_at TEXT NOT NULL,
              PRIMARY KEY(device_id, trial)
            );
            CREATE TABLE IF NOT EXISTS ledger(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              device_id TEXT NOT NULL,
              ts TEXT NOT NULL,
              kind TEXT NOT NULL,
              free_delta INTEGER NOT NULL DEFAULT 0,
              sub_delta INTEGER NOT NULL DEFAULT 0,
              pack_delta INTEGER NOT NULL DEFAULT 0,
              trials TEXT,
              note TEXT
            );
            CREATE TABLE IF NOT EXISTS purchases(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              device_id TEXT NOT NULL,
              product_id TEXT NOT NULL,
              price_inr INTEGER NOT NULL,
              ts TEXT NOT NULL,
              test_mode INTEGER NOT NULL
            );
            """
        )

    # -- storage ---------------------------------------------------------
    def _read(self, device_id: str) -> Optional[State]:
        row = self._db.execute(
            "SELECT free_daily, free_daily_date, sub_credits, pro_until, pack_credits "
            "FROM accounts WHERE device_id=?",
            (device_id,),
        ).fetchone()
        if row is None:
            return None
        trials = frozenset(
            r[0] for r in self._db.execute("SELECT trial FROM trials WHERE device_id=?", (device_id,))
        )
        return State(row[0], row[1], row[2], _parse(row[3]), row[4], trials)

    def _write(self, device_id: str, s: State, now: dt.datetime) -> None:
        self._db.execute(
            "INSERT INTO accounts(device_id, free_daily, free_daily_date, sub_credits, pro_until, pack_credits, created_at) "
            "VALUES(?,?,?,?,?,?,?) ON CONFLICT(device_id) DO UPDATE SET "
            "free_daily=excluded.free_daily, free_daily_date=excluded.free_daily_date, "
            "sub_credits=excluded.sub_credits, pro_until=excluded.pro_until, pack_credits=excluded.pack_credits",
            (device_id, s.free_daily, s.free_daily_date, s.sub_credits, _iso(s.pro_until), s.pack_credits, _iso(now)),
        )
        for t in s.trials_used:
            self._db.execute(
                "INSERT OR IGNORE INTO trials(device_id, trial, used_at) VALUES(?,?,?)", (device_id, t, _iso(now))
            )

    # -- API -------------------------------------------------------------
    def load(self, device_id: str, now: dt.datetime) -> State:
        with self._lock:
            s = self._read(device_id)
            fresh = refresh(s or State.initial(now), now)
            if s != fresh:
                self._write(device_id, fresh, now)
            return fresh

    def decide(self, device_id: str, spec, now: dt.datetime) -> Decision:
        return decide_any(self.load(device_id, now), spec, now)

    def commit(self, device_id: str, spec, now: dt.datetime, note: str = "") -> tuple[State, Decision]:
        """Charge a SUCCESSFUL enhance / look (re-decided atomically)."""
        kind = "look" if isinstance(spec, LookSpec) else "enhance"
        with self._lock:
            s = self.load(device_id, now)
            d = decide_any(s, spec, now)
            if not d.allowed:
                return s, d
            n = apply_decision(s, d)
            self._db.execute("BEGIN")
            try:
                self._write(device_id, n, now)
                self._db.execute(
                    "INSERT INTO ledger(device_id, ts, kind, free_delta, sub_delta, pack_delta, trials, note) "
                    "VALUES(?,?,?,?,?,?,?,?)",
                    (device_id, _iso(now), kind, -d.from_free, -d.from_sub, -d.from_pack,
                     ",".join(d.trials), note),
                )
                self._db.execute("COMMIT")
            except Exception:
                self._db.execute("ROLLBACK")
                raise
            return n, d

    def commit_once(self, device_id: str, key: str, spec, now: dt.datetime) -> tuple[State, Decision, bool]:
        """v11.53 video: charge a finished job exactly once (key in the note).
        → (state, decision, charged_now)."""
        note = f"once:{key}"
        with self._lock:
            row = self._db.execute(
                "SELECT 1 FROM ledger WHERE device_id=? AND note=? LIMIT 1", (device_id, note)).fetchone()
            if row is not None:
                return self.load(device_id, now), Decision(True), False
            s, d = self.commit(device_id, spec, now, note=note)
            return s, d, d.allowed

    def purchase(self, device_id: str, product_id: str, now: dt.datetime, test_mode: bool) -> State:
        with self._lock:
            s = self.load(device_id, now)
            n = apply_purchase(s, product_id, now)
            p = PRODUCTS[product_id]
            self._db.execute("BEGIN")
            try:
                self._write(device_id, n, now)
                self._db.execute(
                    "INSERT INTO purchases(device_id, product_id, price_inr, ts, test_mode) VALUES(?,?,?,?,?)",
                    (device_id, product_id, p["price_inr"], _iso(now), 1 if test_mode else 0),
                )
                self._db.execute(
                    "INSERT INTO ledger(device_id, ts, kind, sub_delta, pack_delta, note) VALUES(?,?,?,?,?,?)",
                    (device_id, _iso(now), "purchase", n.sub_credits - s.sub_credits,
                     n.pack_credits - s.pack_credits, product_id + (" (TEST)" if test_mode else "")),
                )
                self._db.execute("COMMIT")
            except Exception:
                self._db.execute("ROLLBACK")
                raise
            return n

    def history(self, device_id: str, limit: int = 50) -> list[dict]:
        rows = self._db.execute(
            "SELECT ts, kind, free_delta, sub_delta, pack_delta, trials, note FROM ledger "
            "WHERE device_id=? ORDER BY id DESC LIMIT ?",
            (device_id, limit),
        ).fetchall()
        keys = ("ts", "kind", "free_delta", "sub_delta", "pack_delta", "trials", "note")
        return [dict(zip(keys, r)) for r in rows]


def state_header(s: State) -> str:
    import base64

    raw = json.dumps(s.to_json(), separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")
