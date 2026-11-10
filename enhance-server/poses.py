"""Pose library (v11): REAL reference photos for the app's free Pose mode.

v10 drew an outline overlay on the viewfinder; users disliked it. v11 shows
a gallery of real pose photos instead — the user picks one and it floats as
a small reference thumbnail on the camera so the subject can copy it.

Each pose = name + category + one photo (JPEG, EXIF-upright, ≤1280 px,
metadata stripped) + an optional credit / source URL. Seeded on first run
from ``seed_poses.json`` (free Pexels-licensed photos, attribution kept);
admins add / edit / reorder / disable photos at /admin/poses.

Nothing here touches credits or the AI: poses are free.
"""
from __future__ import annotations

import io
import json
import os
import re
import shutil
import sqlite3
import threading
import time
import uuid
from dataclasses import dataclass
from typing import Optional

from PIL import Image, ImageOps

MEDIA_URL_PREFIX = "/media/poses/"
CATEGORIES = ["Standing", "Sitting", "Couple", "Group", "Selfie", "Travel", "Casual"]
MAX_PHOTO_LONG = 1280
_FILE_RE = re.compile(r"^[a-f0-9]{32}\.jpg$")
_URL_RE = re.compile(r"^https?://[^\s<>\"']{1,300}$")


def valid_media_name(name: str) -> bool:
    return bool(_FILE_RE.match(name or ""))


def slugify(name: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "_", (name or "").lower()).strip("_")
    return (s or "pose")[:40]


def clean_credit(raw: Optional[str]) -> str:
    return re.sub(r"\s+", " ", raw or "").strip()[:120]


def clean_source_url(raw: Optional[str]) -> str:
    s = (raw or "").strip()
    if not s:
        return ""
    if not _URL_RE.match(s):
        raise ValueError("source URL must start with http:// or https://")
    return s


@dataclass
class Pose:
    id: str
    name: str
    category: str
    photo: Optional[str] = None
    credit: str = ""
    source_url: str = ""
    enabled: bool = True
    sort_order: int = 0

    def public_json(self) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "category": self.category,
            "photo_url": MEDIA_URL_PREFIX + self.photo if self.photo else None,
            "credit": self.credit,
            "sort_order": self.sort_order,
        }


class PoseStore:
    """SQLite table ``pose_photos`` (v11; the v10 ``poses`` outline table is
    left untouched and unused)."""

    def __init__(self, db_path: str, media_dir: str):
        self.media_dir = media_dir
        os.makedirs(media_dir, exist_ok=True)
        self._db = sqlite3.connect(db_path, check_same_thread=False, isolation_level=None)
        self._db.execute("PRAGMA journal_mode=WAL")
        self._lock = threading.RLock()
        self._db.execute(
            """CREATE TABLE IF NOT EXISTS pose_photos(
                 id TEXT PRIMARY KEY,
                 name TEXT NOT NULL,
                 category TEXT NOT NULL,
                 photo TEXT,
                 credit TEXT NOT NULL DEFAULT '',
                 source_url TEXT NOT NULL DEFAULT '',
                 enabled INTEGER NOT NULL DEFAULT 1,
                 sort_order INTEGER NOT NULL DEFAULT 0,
                 updated_at REAL NOT NULL)"""
        )

    _COLS = "id, name, category, photo, credit, source_url, enabled, sort_order"

    @staticmethod
    def _row(r) -> Pose:
        return Pose(r[0], r[1], r[2], r[3], r[4] or "", r[5] or "", bool(r[6]), r[7])

    def list(self, include_disabled: bool = False) -> list[Pose]:
        q = f"SELECT {self._COLS} FROM pose_photos"
        if not include_disabled:
            q += " WHERE enabled=1 AND photo IS NOT NULL"
        q += " ORDER BY sort_order, name"
        return [self._row(r) for r in self._db.execute(q)]

    def get(self, pid: str) -> Optional[Pose]:
        r = self._db.execute(f"SELECT {self._COLS} FROM pose_photos WHERE id=?", (pid,)).fetchone()
        return self._row(r) if r else None

    def upsert(self, p: Pose) -> Pose:
        if p.category not in CATEGORIES:
            raise ValueError("unknown category")
        if not (p.name or "").strip():
            raise ValueError("name is required")
        with self._lock:
            self._db.execute(
                f"INSERT INTO pose_photos({self._COLS}, updated_at) VALUES(?,?,?,?,?,?,?,?,?) "
                "ON CONFLICT(id) DO UPDATE SET name=excluded.name, category=excluded.category, "
                "photo=excluded.photo, credit=excluded.credit, source_url=excluded.source_url, "
                "enabled=excluded.enabled, sort_order=excluded.sort_order, updated_at=excluded.updated_at",
                (p.id, p.name.strip()[:60], p.category, p.photo, clean_credit(p.credit),
                 p.source_url or "", int(p.enabled), int(p.sort_order), time.time()),
            )
        return p

    def count(self) -> int:
        return int(self._db.execute("SELECT COUNT(*) FROM pose_photos").fetchone()[0])

    def new_id(self, name: str) -> str:
        base = "srv_" + slugify(name)
        pid, i = base, 2
        while self.get(pid) is not None:
            pid, i = f"{base}_{i}", i + 1
        return pid

    def next_sort_order(self) -> int:
        r = self._db.execute("SELECT COALESCE(MAX(sort_order), -1) FROM pose_photos").fetchone()
        return int(r[0]) + 1

    def delete(self, pid: str) -> None:
        with self._lock:
            p = self.get(pid)
            if p is None:
                return
            self._db.execute("DELETE FROM pose_photos WHERE id=?", (pid,))
            self.remove_file(p.photo)

    def move(self, pid: str, direction: int) -> None:
        """Swap sort order with the neighbour above (-1) / below (+1)."""
        with self._lock:
            items = self.list(include_disabled=True)
            idx = next((i for i, p in enumerate(items) if p.id == pid), None)
            if idx is None:
                return
            j = idx + (1 if direction > 0 else -1)
            if not 0 <= j < len(items):
                return
            for k, p in enumerate(items):  # normalise to 0..n-1 first
                p.sort_order = k
            items[idx].sort_order, items[j].sort_order = items[j].sort_order, items[idx].sort_order
            for p in items:
                self.upsert(p)

    def version(self) -> str:
        r = self._db.execute(
            "SELECT COUNT(*), COALESCE(MAX(updated_at), 0) FROM pose_photos WHERE enabled=1").fetchone()
        return f"{r[0]}-{int(r[1] * 1000)}"

    # -- seed ----------------------------------------------------------------
    def seed_if_empty(self, seed_json: str, seed_dir: str) -> int:
        if self.count() > 0 or not os.path.isfile(seed_json):
            return 0
        data = json.load(open(seed_json, encoding="utf-8"))
        n = 0
        for i, s in enumerate(data.get("poses", [])):
            src = os.path.join(seed_dir, os.path.basename(s.get("file", "")))
            if s.get("category") not in CATEGORIES or not os.path.isfile(src):
                continue
            name = uuid.uuid4().hex + ".jpg"
            shutil.copyfile(src, os.path.join(self.media_dir, name))
            self.upsert(Pose(id=s.get("id") or self.new_id(s.get("name", "pose")), name=s.get("name", "Pose"),
                             category=s["category"], photo=name, credit=s.get("credit", ""),
                             source_url=s.get("source_url", ""), enabled=True,
                             sort_order=int(s.get("sort_order", i))))
            n += 1
        return n

    # -- files -----------------------------------------------------------------
    def save_photo(self, raw: bytes) -> str:
        """Validates + re-encodes a pose photo as JPEG (EXIF-upright, ≤1280
        px, metadata stripped). Raises on non-images."""
        im = Image.open(io.BytesIO(raw))
        im = ImageOps.exif_transpose(im)
        if im.mode in ("RGBA", "LA", "P"):
            bg = Image.new("RGB", im.size, (255, 255, 255))
            rgba = im.convert("RGBA")
            bg.paste(rgba, mask=rgba.split()[-1])
            im = bg
        im = im.convert("RGB")
        if max(im.size) > MAX_PHOTO_LONG:
            im.thumbnail((MAX_PHOTO_LONG, MAX_PHOTO_LONG), Image.LANCZOS)
        name = uuid.uuid4().hex + ".jpg"
        im.save(os.path.join(self.media_dir, name), "JPEG", quality=82, optimize=True, progressive=True)
        return name

    def path_for(self, name: str) -> Optional[str]:
        if not valid_media_name(name):
            return None
        p = os.path.join(self.media_dir, name)
        return p if os.path.isfile(p) else None

    def read_file(self, name: str) -> Optional[bytes]:
        p = self.path_for(name)
        return open(p, "rb").read() if p else None

    def remove_file(self, name: Optional[str]) -> None:
        p = self.path_for(name or "")
        if p:
            try:
                os.remove(p)
            except OSError:
                pass
