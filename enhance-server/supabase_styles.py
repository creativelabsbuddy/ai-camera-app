"""Supabase backend for the style library (STYLES_BACKEND=supabase).

Same interface as styles.StyleStore. Rows live in public.styles (RLS on, no
public policies → only the service-role key can read/write). Thumbnails go
to the `style-thumbs` bucket, reference images to the PRIVATE `style-refs`
bucket. The server still serves thumbnails via /media/styles/{name} so the
app contract is unchanged; refs are only read server-side.

Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
"""
from __future__ import annotations

import hashlib
import io
import json
import time
import uuid
from typing import Optional

import httpx
from PIL import Image, ImageOps

from styles import MAX_IMAGE_LONG, MAX_SAMPLE_LONG, MEDIA_TYPES, Style, normalize_ui_category, slugify, valid_media_name

THUMBS = "style-thumbs"
REFS = "style-refs"
SAMPLES = "style-samples"  # v11.56 public before/after samples
_FIELDS = ("id", "name", "category", "prompt", "credit_cost", "pro_only", "enabled", "sort_order",
           "display_image", "ref_images", "needs_person", "media_type", "free_trial", "kind", "ui_category",
           "sample_before_url", "sample_after_url")


class SupabaseStyleStore:
    def __init__(self, url: str, service_key: str, transport: Optional[httpx.BaseTransport] = None):
        if not url or not service_key:
            raise RuntimeError("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required")
        self.url = url.rstrip("/")
        self._c = httpx.Client(base_url=self.url, timeout=30, transport=transport, headers={
            "apikey": service_key, "Authorization": f"Bearer {service_key}"})

    # -- helpers --------------------------------------------------------------
    def _ok(self, r: httpx.Response) -> httpx.Response:
        if r.status_code >= 400:
            raise RuntimeError(f"supabase {r.request.method} {r.request.url.path} → {r.status_code}: {r.text[:200]}")
        return r

    @staticmethod
    def _from_row(r: dict) -> Style:
        return Style(id=r["id"], name=r["name"], category=r["category"], prompt=r["prompt"],
                     credit_cost=int(r["credit_cost"]), pro_only=bool(r["pro_only"]), enabled=bool(r["enabled"]),
                     sort_order=int(r["sort_order"]), display_image=r.get("display_image"),
                     ref_images=list(r.get("ref_images") or []), needs_person=bool(r.get("needs_person", True)),
                     media_type=r.get("media_type") or "photo", free_trial=bool(r.get("free_trial", True)),
                     kind=r.get("kind") or "style", ui_category=r.get("ui_category") or "new",
                     sample_before_url=r.get("sample_before_url") or None,
                     sample_after_url=r.get("sample_after_url") or None)

    def _rows(self, params: dict) -> list:
        return self._ok(self._c.get("/rest/v1/styles", params={"select": "*", **params})).json()

    # -- seed -----------------------------------------------------------------
    def seed_if_empty(self, seed_json: str, seed_media: str) -> int:
        """Never auto-seeds a remote DB (use tools/migrate_styles_to_supabase.py)."""
        return 0

    # -- rows -----------------------------------------------------------------
    def list(self, include_disabled: bool = False, media_type: Optional[str] = None) -> list:
        p = {"order": "sort_order.asc,name.asc"}
        if not include_disabled:
            p["enabled"] = "eq.true"
        if media_type:
            p["media_type"] = f"eq.{media_type}"
        return [self._from_row(r) for r in self._rows(p)]

    def get(self, sid: str) -> Optional[Style]:
        rows = self._rows({"id": f"eq.{sid}"})
        return self._from_row(rows[0]) if rows else None

    def upsert(self, s: Style) -> Style:
        s.credit_cost = max(0, min(100, int(s.credit_cost)))
        if s.media_type not in MEDIA_TYPES:
            s.media_type = "photo"
        if s.kind not in ("style", "filter"):
            s.kind = "style"
        s.ui_category = normalize_ui_category(s.ui_category, s.media_type)
        row = {k: getattr(s, k) for k in _FIELDS}
        row["updated_at"] = time.time()
        self._ok(self._c.post("/rest/v1/styles", json=row, headers={
            "Prefer": "resolution=merge-duplicates,return=minimal"}))
        return s

    def new_id(self, name: str) -> str:
        base = slugify(name)
        sid, i = base, 2
        while self.get(sid) is not None:
            sid, i = f"{base}_{i}", i + 1
        return sid

    def next_sort_order(self) -> int:
        rows = self._rows({"order": "sort_order.desc", "limit": "1"})
        return int(rows[0]["sort_order"]) + 1 if rows else 0

    def delete(self, sid: str) -> None:
        s = self.get(sid)
        if s is None:
            return
        self._ok(self._c.delete("/rest/v1/styles", params={"id": f"eq.{sid}"}))
        self.remove_file(s.display_image)
        for f in s.ref_images:
            self.remove_file(f, private=True)

    def _renumber(self, ids: list) -> None:
        for n, x in enumerate(ids):
            self._ok(self._c.patch("/rest/v1/styles", params={"id": f"eq.{x}"},
                                   json={"sort_order": n, "updated_at": time.time()}))

    def move(self, sid: str, direction: int) -> None:
        ids = [r.id for r in self.list(include_disabled=True)]
        if sid not in ids:
            return
        i = ids.index(sid)
        j = i + (1 if direction > 0 else -1)
        if 0 <= j < len(ids):
            ids[i], ids[j] = ids[j], ids[i]
        self._renumber(ids)

    def set_order(self, ids: list) -> None:
        known = [r.id for r in self.list(include_disabled=True)]
        order = [x for x in ids if x in known]
        self._renumber(order + [x for x in known if x not in order])

    def version(self) -> str:
        rows = self._rows({"select": "id,enabled,sort_order,updated_at", "order": "id.asc"})
        return hashlib.sha1(json.dumps(rows, sort_keys=True).encode()).hexdigest()[:12]

    # -- files ------------------------------------------------------------------
    def save_image(self, raw: bytes, private: bool = False) -> str:
        im = Image.open(io.BytesIO(raw))
        im = ImageOps.exif_transpose(im).convert("RGB")
        if max(im.size) > MAX_IMAGE_LONG:
            im.thumbnail((MAX_IMAGE_LONG, MAX_IMAGE_LONG), Image.LANCZOS)
        buf = io.BytesIO()
        im.save(buf, "JPEG", quality=88)
        name = uuid.uuid4().hex + ".jpg"
        self.put_file(name, buf.getvalue(), private)
        return name

    def save_sample(self, raw: bytes) -> str:
        """v11.56: before/after sample → public `style-samples` bucket; returns its public URL."""
        im = ImageOps.exif_transpose(Image.open(io.BytesIO(raw))).convert("RGB")
        if max(im.size) > MAX_SAMPLE_LONG:
            im.thumbnail((MAX_SAMPLE_LONG, MAX_SAMPLE_LONG), Image.LANCZOS)
        buf = io.BytesIO()
        im.save(buf, "JPEG", quality=88)
        name = uuid.uuid4().hex + ".jpg"
        self._ok(self._c.post(f"/storage/v1/object/{SAMPLES}/{name}", content=buf.getvalue(),
                              headers={"Content-Type": "image/jpeg", "x-upsert": "true"}))
        return f"{self.url}/storage/v1/object/public/{SAMPLES}/{name}"

    def remove_sample(self, url: Optional[str]) -> None:
        pre = f"{self.url}/storage/v1/object/public/{SAMPLES}/"
        if url and url.startswith(pre) and valid_media_name(url[len(pre):]):
            try:
                self._c.delete(f"/storage/v1/object/{SAMPLES}/{url[len(pre):]}")
            except httpx.HTTPError:
                pass

    def put_file(self, name: str, data: bytes, private: bool = False) -> None:
        self._ok(self._c.post(f"/storage/v1/object/{REFS if private else THUMBS}/{name}", content=data,
                              headers={"Content-Type": "image/jpeg", "x-upsert": "true"}))

    def path_for(self, name: str, private: bool = False):
        return None

    def read_file(self, name: str, private: bool = False) -> Optional[bytes]:
        if not valid_media_name(name):
            return None
        r = self._c.get(f"/storage/v1/object/authenticated/{REFS if private else THUMBS}/{name}")
        return r.content if r.status_code == 200 else None

    def remove_file(self, name: Optional[str], private: bool = False) -> None:
        if not valid_media_name(name or ""):
            return
        try:
            self._c.delete(f"/storage/v1/object/{REFS if private else THUMBS}/{name}")
        except httpx.HTTPError:
            pass
