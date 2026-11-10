"""AI style library storage (v9): SQLite rows + images on disk.

Prompts and reference-image files NEVER leave the server: the public listing
(`public_json`) only exposes id, name, category, cost, flags and the display
image URL. The apply endpoint composes prompt + reference images server-side.
"""
from __future__ import annotations

import hashlib
import io
import json
import os
import re
import shutil
import sqlite3
import threading
import time
import uuid
from dataclasses import dataclass, field
from typing import Optional

from PIL import Image, ImageOps

MEDIA_URL_PREFIX = "/media/styles/"
MAX_IMAGE_LONG = 1600
MAX_REFERENCES = 4
MAX_SAMPLE_LONG = 1920  # v11.56 before/after samples (9:16, 1080x1920)
MEDIA_TYPES = ("photo", "video")
PHOTO_UI_CATEGORIES = (("new", "New"), ("trending", "Trending"), ("appearance", "Appearance"),
                       ("cities", "Cities"), ("bw", "Black & White"), ("cinematic", "Cinematic"),
                       ("ai_photo", "AI for Photo"))
VIDEO_UI_CATEGORIES = (("new", "New"), ("trending", "Trending"), ("motion", "Motion"),
                       ("cinematic", "Cinematic"), ("zoom", "Zoom"))


def ui_categories_for(media_type: str) -> tuple:
    return VIDEO_UI_CATEGORIES if media_type == "video" else PHOTO_UI_CATEGORIES


def normalize_ui_category(value, media_type: str = "photo") -> str:
    v = (value or "").strip().lower()
    return v if v in {k for k, _ in ui_categories_for(media_type)} else "new"


_FILE_RE = re.compile(r"^[a-z0-9_\-]{1,80}\.jpg$")


@dataclass
class Style:
    id: str
    name: str
    category: str
    prompt: str
    credit_cost: int = 2
    pro_only: bool = False
    enabled: bool = True
    sort_order: int = 0
    display_image: Optional[str] = None
    ref_images: list = field(default_factory=list)
    # Made for photos of people → the app warns "No person found in this
    # photo" before spending credits when it can't find a face.
    needs_person: bool = True
    # v11.1.29 Photo Styles admin: "photo" now; "video" reserved (Coming soon).
    media_type: str = "photo"
    # Whether the once-per-device "library_style" starter trial may make this
    # style free the first time (existing ledger logic). Off → always charged.
    free_trial: bool = True
    # v11.51: "filter" → shown in the camera's filter row (Styles carousel);
    # "style" → the normal Styles library. Same prompt/credit/apply path.
    kind: str = "style"
    # v11.54: browse category for the app's Styles sheet chips (photo: new,
    # trending, appearance, cities, bw, cinematic, ai_photo; video: new,
    # trending, motion, cinematic, zoom). Unknown/empty → "new".
    ui_category: str = "new"
    # v11.56: real before/after sample shown on the app's style cards
    # (absolute public URLs or /media/styles/<file>). Video: after only.
    sample_before_url: Optional[str] = None
    sample_after_url: Optional[str] = None

    def public_json(self) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "category": self.category,
            "credit_cost": self.credit_cost,
            "pro_only": self.pro_only,
            "sort_order": self.sort_order,
            "image_url": MEDIA_URL_PREFIX + self.display_image if self.display_image else None,
            "has_reference": bool(self.ref_images),
            "needs_person": self.needs_person,
            "kind": self.kind if self.kind in KINDS else "style",
            "ui_category": normalize_ui_category(self.ui_category, self.media_type),
            "sample_before_url": self.sample_before_url or None,
            "sample_after_url": self.sample_after_url or None,
        }

    def admin_json(self) -> dict:
        """Full record for the token/admin API only (includes the prompt)."""
        return {**self.public_json(), "prompt": self.prompt, "enabled": self.enabled,
                "media_type": self.media_type, "free_trial": self.free_trial, "display_image": self.display_image,
                "ref_images": list(self.ref_images)}


KINDS = ("style", "filter")


def slugify(name: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "_", (name or "").lower()).strip("_")
    return (s or "style")[:40]


def valid_media_name(name: str) -> bool:
    return bool(_FILE_RE.match(name or ""))


class StyleStore:
    def __init__(self, db_path: str, media_dir: str, ref_dir: Optional[str] = None):
        # Display images (public) and reference images (private, never served).
        self.media_dir = media_dir
        self.ref_dir = ref_dir or media_dir.rstrip("/\\") + "_refs"
        os.makedirs(media_dir, exist_ok=True)
        os.makedirs(self.ref_dir, exist_ok=True)
        self._db = sqlite3.connect(db_path, check_same_thread=False, isolation_level=None)
        self._db.execute("PRAGMA journal_mode=WAL")
        self._lock = threading.RLock()
        self._db.executescript(
            """
            CREATE TABLE IF NOT EXISTS styles(
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              category TEXT NOT NULL,
              prompt TEXT NOT NULL,
              credit_cost INTEGER NOT NULL DEFAULT 2,
              pro_only INTEGER NOT NULL DEFAULT 0,
              enabled INTEGER NOT NULL DEFAULT 1,
              sort_order INTEGER NOT NULL DEFAULT 0,
              display_image TEXT,
              ref_images TEXT NOT NULL DEFAULT '[]',
              updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
            """
        )
        cols = {r[1] for r in self._db.execute("PRAGMA table_info(styles)")}
        if "needs_person" not in cols:  # v9 → v9.1 migration
            self._db.execute("ALTER TABLE styles ADD COLUMN needs_person INTEGER NOT NULL DEFAULT 1")
        if "media_type" not in cols:  # v11.1.29 migration
            self._db.execute("ALTER TABLE styles ADD COLUMN media_type TEXT NOT NULL DEFAULT 'photo'")
        if "free_trial" not in cols:
            self._db.execute("ALTER TABLE styles ADD COLUMN free_trial INTEGER NOT NULL DEFAULT 1")
        if "kind" not in cols:  # v11.51 migration
            self._db.execute("ALTER TABLE styles ADD COLUMN kind TEXT NOT NULL DEFAULT 'style'")
        if "ui_category" not in cols:  # v11.54 migration
            self._db.execute("ALTER TABLE styles ADD COLUMN ui_category TEXT DEFAULT 'new'")
        if "sample_before_url" not in cols:  # v11.56 migration
            self._db.execute("ALTER TABLE styles ADD COLUMN sample_before_url TEXT")
        if "sample_after_url" not in cols:
            self._db.execute("ALTER TABLE styles ADD COLUMN sample_after_url TEXT")

    # -- seed --------------------------------------------------------------
    def seed_if_empty(self, seed_json: str, seed_media: str) -> int:
        """First run: import the bundled seed styles (+ sample images)."""
        with self._lock:
            if self._db.execute("SELECT v FROM meta WHERE k='seeded'").fetchone():
                return 0
            n = 0
            try:
                data = json.load(open(seed_json, encoding="utf-8"))
            except Exception:
                data = {"styles": []}
            for s in data.get("styles", []):
                img = s.get("display_image")
                if img and os.path.exists(os.path.join(seed_media, img)):
                    shutil.copyfile(os.path.join(seed_media, img), os.path.join(self.media_dir, img))
                else:
                    img = None
                self.upsert(Style(
                    id=s["id"], name=s["name"], category=s["category"], prompt=s["prompt"],
                    credit_cost=int(s.get("credit_cost", 2)), pro_only=bool(s.get("pro_only")),
                    enabled=True, sort_order=int(s.get("sort_order", n)), display_image=img,
                    needs_person=bool(s.get("needs_person", True)),
                    ui_category=s.get("ui_category") or "new",
                ))
                n += 1
            self._db.execute("INSERT OR REPLACE INTO meta(k, v) VALUES('seeded', '1')")
            return n

    # -- rows ----------------------------------------------------------------
    @staticmethod
    def _row(r) -> Style:
        return Style(r[0], r[1], r[2], r[3], r[4], bool(r[5]), bool(r[6]), r[7], r[8], json.loads(r[9] or "[]"),
                     bool(r[10]), r[11] or "photo", bool(r[12]), r[13] or "style", r[14] or "new",
                     r[15] or None, r[16] or None)

    _COLS = ("id, name, category, prompt, credit_cost, pro_only, enabled, sort_order, display_image, "
             "ref_images, needs_person, media_type, free_trial, kind, ui_category, sample_before_url, sample_after_url")

    def list(self, include_disabled: bool = False, media_type: Optional[str] = None) -> list[Style]:
        q = f"SELECT {self._COLS} FROM styles"
        where, args = [], []
        if not include_disabled:
            where.append("enabled=1")
        if media_type:
            where.append("media_type=?")
            args.append(media_type)
        if where:
            q += " WHERE " + " AND ".join(where)
        q += " ORDER BY sort_order, name"
        return [self._row(r) for r in self._db.execute(q, args)]

    def get(self, sid: str) -> Optional[Style]:
        r = self._db.execute(f"SELECT {self._COLS} FROM styles WHERE id=?", (sid,)).fetchone()
        return self._row(r) if r else None

    def upsert(self, s: Style) -> Style:
        s.credit_cost = max(0, min(100, int(s.credit_cost)))
        with self._lock:
            self._db.execute(
                f"INSERT INTO styles({self._COLS}, updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) "
                "ON CONFLICT(id) DO UPDATE SET name=excluded.name, category=excluded.category, "
                "prompt=excluded.prompt, credit_cost=excluded.credit_cost, pro_only=excluded.pro_only, "
                "enabled=excluded.enabled, sort_order=excluded.sort_order, "
                "display_image=excluded.display_image, ref_images=excluded.ref_images, "
                "needs_person=excluded.needs_person, media_type=excluded.media_type, "
                "free_trial=excluded.free_trial, kind=excluded.kind, ui_category=excluded.ui_category, "
                "sample_before_url=excluded.sample_before_url, sample_after_url=excluded.sample_after_url, "
                "updated_at=excluded.updated_at",
                (s.id, s.name, s.category, s.prompt, s.credit_cost, int(s.pro_only), int(s.enabled),
                 s.sort_order, s.display_image, json.dumps(s.ref_images), int(s.needs_person),
                 s.media_type if s.media_type in MEDIA_TYPES else "photo", int(s.free_trial),
                 s.kind if s.kind in KINDS else "style",
                 normalize_ui_category(s.ui_category, s.media_type),
                 s.sample_before_url or None, s.sample_after_url or None, time.time()),
            )
        return s

    def new_id(self, name: str) -> str:
        base = slugify(name)
        sid, i = base, 2
        while self.get(sid) is not None:
            sid, i = f"{base}_{i}", i + 1
        return sid

    def next_sort_order(self) -> int:
        r = self._db.execute("SELECT COALESCE(MAX(sort_order), -1) FROM styles").fetchone()
        return int(r[0]) + 1

    def delete(self, sid: str) -> None:
        with self._lock:
            s = self.get(sid)
            if s is None:
                return
            self._db.execute("DELETE FROM styles WHERE id=?", (sid,))
            self.remove_file(s.display_image)
            for f in s.ref_images:
                self.remove_file(f, private=True)

    def move(self, sid: str, direction: int) -> None:
        """Swap with the neighbour above (-1) / below (+1); renumbers 0..n."""
        with self._lock:
            rows = self.list(include_disabled=True)
            ids = [r.id for r in rows]
            if sid not in ids:
                return
            i = ids.index(sid)
            j = i + (1 if direction > 0 else -1)
            if 0 <= j < len(ids):
                ids[i], ids[j] = ids[j], ids[i]
            for n, x in enumerate(ids):
                self._db.execute("UPDATE styles SET sort_order=?, updated_at=? WHERE id=?", (n, time.time(), x))

    def set_order(self, ids: list) -> None:
        """Explicit reorder: given ids first (in that order), the rest after."""
        with self._lock:
            known = [r.id for r in self.list(include_disabled=True)]
            order = [x for x in ids if x in known]
            order += [x for x in known if x not in order]
            for n, x in enumerate(order):
                self._db.execute("UPDATE styles SET sort_order=?, updated_at=? WHERE id=?", (n, time.time(), x))

    def version(self) -> str:
        r = self._db.execute(
            "SELECT COUNT(*), COALESCE(MAX(updated_at), 0), "
            "COALESCE(GROUP_CONCAT(id || ':' || enabled || ':' || sort_order), '') FROM styles"
        ).fetchone()
        return hashlib.sha1(repr(r).encode()).hexdigest()[:12]

    # -- files -----------------------------------------------------------------
    def save_image(self, raw: bytes, private: bool = False) -> str:
        """Validates + re-encodes an upload (EXIF-upright, ≤1600px, JPEG,
        metadata stripped). Returns the stored file name."""
        im = Image.open(io.BytesIO(raw))
        im = ImageOps.exif_transpose(im).convert("RGB")
        if max(im.size) > MAX_IMAGE_LONG:
            im.thumbnail((MAX_IMAGE_LONG, MAX_IMAGE_LONG), Image.LANCZOS)
        name = uuid.uuid4().hex + ".jpg"
        im.save(os.path.join(self.ref_dir if private else self.media_dir, name), "JPEG", quality=88)
        return name

    def save_sample(self, raw: bytes) -> str:
        """v11.56 before/after sample: re-encoded JPEG (≤1920px) in the
        public media dir. Returns its URL path (/media/styles/<file>)."""
        im = ImageOps.exif_transpose(Image.open(io.BytesIO(raw))).convert("RGB")
        if max(im.size) > MAX_SAMPLE_LONG:
            im.thumbnail((MAX_SAMPLE_LONG, MAX_SAMPLE_LONG), Image.LANCZOS)
        name = uuid.uuid4().hex + ".jpg"
        im.save(os.path.join(self.media_dir, name), "JPEG", quality=88)
        return MEDIA_URL_PREFIX + name

    def remove_sample(self, url: Optional[str]) -> None:
        if url and url.startswith(MEDIA_URL_PREFIX):
            self.remove_file(url[len(MEDIA_URL_PREFIX):])

    def path_for(self, name: str, private: bool = False) -> Optional[str]:
        if not valid_media_name(name):
            return None
        p = os.path.join(self.ref_dir if private else self.media_dir, name)
        return p if os.path.isfile(p) else None

    def read_file(self, name: str, private: bool = False) -> Optional[bytes]:
        p = self.path_for(name, private)
        return open(p, "rb").read() if p else None

    def remove_file(self, name: Optional[str], private: bool = False) -> None:
        p = self.path_for(name or "", private)
        if p:
            try:
                os.remove(p)
            except OSError:
                pass
