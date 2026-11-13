"""v11.63 video generation: Phosor MiniMax H3 Turbo only (5/8/10/15 s).
VIDEO_API_KEY is read only for HMAC of existing job ids; new jobs need
PHOSOR_API_KEY. Server-side keys never leave the server; errors are
key-redacted.

Job ids handed to the app are stateless signed tokens
`<provider>~<request_id>.<sig>` (sig = HMAC(device_id|provider|request_id)).
"""
from __future__ import annotations

import hashlib
import hmac
import json
import logging
import math
import os
import re
from dataclasses import dataclass
from typing import Optional

import httpx

log = logging.getLogger("enhance.video")

WAN = "wan"          # legacy job-id provider tag (HMAC / in-flight only)
MINIMAX = "minimax"  # Phosor MiniMax H3 Turbo (all new jobs)

PHOSOR_BASE = "https://phosor.ai/api/v1"

# App chips are 5, 8, 10, 15 s. Phosor accepts duration 4..15, so 5 s is valid.
# Unused 3 s (old Wan) and 6 s (old server-only) are dropped.
MM_SECONDS = (5, 8, 10, 15)
MM_RES = ("480p", "768p")
MM_ASPECTS = ("16:9", "9:16")
MAX_PROMPT = 1500
TIMEOUT = float(os.environ.get("VIDEO_HTTP_TIMEOUT", "60"))

USD_INR = 95.0
# Provider cost in ₹ (published / measured, $1 = ₹95). Unchanged.
MM_COST_INR_PER_S = {"480p": 0.57, "768p": 0.855}
# Provisional (NOT approved): credits = ceil(cost_₹ × MARGIN / ₹ per credit
# at the cheapest credit price, Pro ₹99/100 credits).
INR_PER_CREDIT = 0.99
MARGIN = 1.5

_RID = re.compile(r"^[A-Za-z0-9_-]{6,100}$")


class VideoError(Exception):
    def __init__(self, message: str, status: int = 502):
        super().__init__(message)
        self.status = status


def _key(provider: str) -> str:
    return os.environ.get("VIDEO_API_KEY" if provider == WAN else "PHOSOR_API_KEY", "").strip()


def configured(provider: str = MINIMAX) -> bool:
    """Video needs the Phosor key only. VIDEO_API_KEY is unused except HMAC."""
    return bool(_key(MINIMAX))


def minimax_enabled() -> bool:
    """Licence region policy switch (undecided → default allow everywhere).
    When off, all video is unavailable (everything is MiniMax)."""
    return os.environ.get("MINIMAX_ENABLED", "1").strip() not in ("0", "false", "no")


def provisional_credits(cost_inr: float) -> int:
    return max(1, math.ceil(round(cost_inr * MARGIN / INR_PER_CREDIT, 6)))


def cost_inr(provider: str, seconds: int, resolution: str) -> float:
    return round(MM_COST_INR_PER_S[resolution] * seconds, 3)


def credit_table(override: Optional[dict] = None) -> dict:
    """Defaults ← VIDEO_CREDITS_JSON env ← admin override {"minimax_5_480p": 3, ...}.

    wan_* override keys no longer apply (provider keys changed in v11.63).
    minimax_5_480p is hard-set to 3 (do not use the provisional formula, which
    would be 5). Other MiniMax cells use the existing provisional formula.
    """
    t = {}
    for r in MM_RES:
        for s in MM_SECONDS:
            t[f"minimax_{s}_{r}"] = provisional_credits(cost_inr(MINIMAX, s, r))
    t["minimax_5_480p"] = 3
    try:
        ov = json.loads(os.environ.get("VIDEO_CREDITS_JSON", "") or "{}")
        for k, v in ov.items():
            if k in t and int(v) >= 0:
                t[k] = int(v)
    except Exception:
        log.warning("bad VIDEO_CREDITS_JSON ignored")
    for k, v in (override or {}).items():
        try:
            if k in t and int(v) >= 0:
                t[k] = int(v)
        except (TypeError, ValueError):
            continue
    return t


@dataclass(frozen=True)
class VideoSpec:
    provider: str
    kind: str          # "t2v" | "i2v"
    prompt: str
    seconds: int
    resolution: str
    aspect_ratio: str

    def credits(self, override: Optional[dict] = None) -> int:
        return credit_table(override)[f"{self.provider}_{self.seconds}_{self.resolution}"]

    @property
    def model_label(self) -> str:
        return "MiniMax H3" if self.provider == MINIMAX else "Wan 2.2"


def route(kind: str, prompt: str, seconds: int, resolution: str, aspect_ratio: str) -> VideoSpec:
    p = (prompt or "").strip()
    if not p:
        raise VideoError("prompt is required", 422)
    if len(p) > MAX_PROMPT:
        raise VideoError(f"prompt too long (max {MAX_PROMPT} chars)", 422)
    if kind not in ("t2v", "i2v"):
        raise VideoError("kind must be t2v or i2v", 422)
    if not minimax_enabled():
        raise VideoError("AI video is not available", 403)
    if seconds not in MM_SECONDS:
        raise VideoError(f"seconds must be one of {list(MM_SECONDS)}", 422)
    if resolution not in MM_RES:
        raise VideoError(f"resolution for {seconds}s must be one of {list(MM_RES)}", 422)
    if aspect_ratio not in MM_ASPECTS:
        raise VideoError(f"aspect_ratio must be one of {list(MM_ASPECTS)}", 422)
    return VideoSpec(MINIMAX, kind, p, seconds, resolution, aspect_ratio)


# -- signed job ids -----------------------------------------------------------
def _sig(device_id: str, provider: str, rid: str, credits: int) -> str:
    secret = hashlib.sha256(b"video-job-v1153:" + (_key(WAN) + _key(MINIMAX)).encode()).digest()
    msg = f"{device_id}|{provider}|{rid}|{credits}".encode()
    return hmac.new(secret, msg, hashlib.sha256).hexdigest()[:24]


def make_job_id(device_id: str, provider: str, rid: str, credits: int) -> str:
    return f"{provider}~{rid}~{credits}.{_sig(device_id, provider, rid, credits)}"


def parse_job_id(device_id: str, job_id: str) -> tuple[str, str, int]:
    """→ (provider, request_id, credits) — all covered by the signature."""
    head, _, sig = (job_id or "").rpartition(".")
    parts = head.split("~")
    if len(parts) != 3 or parts[0] not in (WAN, MINIMAX) or not _RID.match(parts[1]) \
            or not parts[2].isdigit() or not sig \
            or not hmac.compare_digest(sig, _sig(device_id, parts[0], parts[1], int(parts[2]))):
        raise VideoError("unknown job id", 404)
    return parts[0], parts[1], int(parts[2])


# -- helpers -----------------------------------------------------------------
def error_text(r: httpx.Response) -> str:
    try:
        js = r.json()
        msg = (js.get("detail") or js.get("error") or js.get("message") or js) if isinstance(js, dict) else js
        txt = msg if isinstance(msg, str) else json.dumps(msg)
    except Exception:
        txt = r.text or ""
    for k in (_key(WAN), _key(MINIMAX)):
        if k:
            txt = txt.replace(k, "<redacted>")
    return " ".join(txt.split())[:300]


def _fail(what: str, r: httpx.Response) -> VideoError:
    msg = f"{what} failed (HTTP {r.status_code}): {error_text(r)}"
    log.warning("%s", msg)
    if r.status_code in (401, 402, 403):
        return VideoError(msg, 502)
    return VideoError(msg, 400 if 400 <= r.status_code < 500 else 502)


def _headers(provider: str = MINIMAX) -> dict:
    k = _key(MINIMAX)
    if not k:
        raise VideoError("video generation is not configured", 503)
    return {"X-API-Key": k}


def _client(transport) -> httpx.AsyncClient:
    return httpx.AsyncClient(timeout=TIMEOUT, transport=transport)


# -- submit ------------------------------------------------------------------
async def submit(spec: VideoSpec, image: Optional[bytes] = None, image_mime: str = "image/jpeg",
                 transport=None) -> str:
    if spec.kind == "i2v" and not image:
        raise VideoError("image is required for image-to-video", 422)
    async with _client(transport) as c:
        try:
            body = {"prompt": spec.prompt, "resolution_tier": spec.resolution,
                    "aspect_ratio": spec.aspect_ratio, "duration": spec.seconds,
                    "model": f"minimax/h3/{'image' if spec.kind == 'i2v' else 'text'}-to-video/turbo"}
            if spec.kind == "i2v":
                body["image_url"] = await _phosor_upload(c, image, image_mime)
            r = await c.post(PHOSOR_BASE + "/inference/submit", json=body, headers=_headers(MINIMAX))
            if r.status_code >= 400:
                raise _fail("MiniMax submit", r)
            js = r.json() or {}
            rid = js.get("request_id") or js.get("id")
        except httpx.TimeoutException as e:
            # Never resubmit blindly: the job may exist and be billed.
            raise VideoError("provider timed out during submit — not retried (job may still run)", 504) from e
        except httpx.HTTPError as e:
            raise VideoError(f"provider unreachable: {type(e).__name__}") from e
    if not rid or not _RID.match(str(rid)):
        raise VideoError("provider returned no request id")
    return str(rid)


async def _phosor_upload(c: httpx.AsyncClient, image: bytes, mime: str) -> str:
    last = None
    for path in ("/storage/image/upload", "/storage/upload_image"):
        r = await c.post(PHOSOR_BASE + path, headers=_headers(MINIMAX),
                         files={"image": ("photo.jpg", image, mime)})
        if r.status_code == 404:
            last = r
            continue
        if r.status_code >= 400:
            raise _fail("MiniMax image upload", r)
        url = (r.json() or {}).get("s3_url") or (r.json() or {}).get("url")
        if not url:
            raise VideoError("MiniMax image upload returned no URL")
        return url
    raise _fail("MiniMax image upload", last)


# -- status ------------------------------------------------------------------
_DONE = {"completed", "succeeded", "success", "done"}
_FAILED = {"failed", "error", "cancelled", "canceled"}


def _find_url(js) -> Optional[str]:
    if isinstance(js, str):
        return js if js.startswith("http") else None
    if isinstance(js, dict):
        for k in ("video_url", "url", "output", "video", "result", "data"):
            if k in js:
                u = _find_url(js[k])
                if u:
                    return u
    if isinstance(js, list):
        for x in js:
            u = _find_url(x)
            if u:
                return u
    return None


async def status(provider: str, rid: str, transport=None) -> dict:
    """→ {"status": queued|running|done|failed, "video_url"?, "progress"?, "error"?}"""
    async with _client(transport) as c:
        if provider != MINIMAX:
            # Legacy 8scale job ids still HMAC-verify; no 8scale API calls.
            return {"status": "failed", "error": "This video job is no longer available"}
        try:
            r = await c.get(f"{PHOSOR_BASE}/inference/status/{rid}", headers=_headers(MINIMAX))
            if r.status_code == 404:
                raise VideoError("unknown job id", 404)
            if r.status_code >= 400:
                raise _fail("status", r)
            js = r.json() or {}
            st = str(js.get("status", "")).lower()
            prog = js.get("progress")
            if st in _FAILED:
                return {"status": "failed", "error": str(js.get("error") or js.get("message") or st)[:300]}
            if st not in _DONE:
                return {"status": "queued" if st in ("in_queue", "queued", "pending") else "running",
                        "progress": prog}
            url = _find_url(js)
            if not url:
                rr = await c.get(f"{PHOSOR_BASE}/inference/result/{rid}", headers=_headers(MINIMAX))
                # v11.58: 202 = result not published yet (status may say
                # "completed" a moment early) → still running, keep polling.
                if rr.status_code == 202:
                    return {"status": "running", "progress": prog}
                if rr.status_code >= 400:
                    return {"status": "failed", "error": f"result failed (HTTP {rr.status_code}): {error_text(rr)}"}
                url = _find_url(rr.json() or {})
                if not url:
                    return {"status": "running", "progress": prog}
        except httpx.HTTPError as e:
            raise VideoError(f"provider unreachable: {type(e).__name__}") from e
    if not url:
        return {"status": "failed", "error": "provider returned no video"}
    return {"status": "done", "video_url": url}


async def cancel(provider: str, rid: str, transport=None) -> bool:
    """Phosor has no cancel API. Never raises; always a no-op."""
    return False
