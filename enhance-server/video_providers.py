"""v11.53 video generation: 8scale Wan 2.2 14B (≤5 s) and Phosor MiniMax H3
Turbo (>5 s). Server-side keys (VIDEO_API_KEY, PHOSOR_API_KEY) never leave
the server; errors are key-redacted.

Job ids handed to the app are stateless signed tokens
`<provider>~<request_id>.<sig>` (sig = HMAC(device_id|provider|request_id)).
"""
from __future__ import annotations

import base64
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

WAN = "wan"          # 8scale Wan 2.2 14B
MINIMAX = "minimax"  # Phosor MiniMax H3 Turbo

EIGHTSCALE_BASE = "https://8scale.run"
PHOSOR_BASE = "https://phosor.ai/api/v1"

WAN_SECONDS = (3, 5)
WAN_RES = ("480p", "580p", "720p")
WAN_ASPECTS = ("16:9", "9:16", "1:1")
MM_SECONDS = (6, 8, 10, 15)          # app chips; provider accepts 4..15
MM_RES = ("480p", "768p")
MM_ASPECTS = ("16:9", "9:16")
MAX_PROMPT = 1500
TIMEOUT = float(os.environ.get("VIDEO_HTTP_TIMEOUT", "60"))

USD_INR = 95.0
# Provider cost in ₹ (published / measured, $1 = ₹95).
WAN_COST_INR_5S = {"480p": 1.43, "580p": 2.28, "720p": 4.18}
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


def configured(provider: str) -> bool:
    return bool(_key(provider))


def minimax_enabled() -> bool:
    """Licence region policy switch (undecided → default allow everywhere)."""
    return os.environ.get("MINIMAX_ENABLED", "1").strip() not in ("0", "false", "no")


def provisional_credits(cost_inr: float) -> int:
    return max(1, math.ceil(round(cost_inr * MARGIN / INR_PER_CREDIT, 6)))


def cost_inr(provider: str, seconds: int, resolution: str) -> float:
    if provider == WAN:
        return round(WAN_COST_INR_5S[resolution] * (seconds / 5.0), 3)
    return round(MM_COST_INR_PER_S[resolution] * seconds, 3)


def credit_table(override: Optional[dict] = None) -> dict:
    """Defaults ← VIDEO_CREDITS_JSON env ← admin override {"wan_5_480p": 3, ...}."""
    t = {}
    for r in WAN_RES:
        for s in WAN_SECONDS:
            t[f"wan_{s}_{r}"] = provisional_credits(cost_inr(WAN, s, r))
    for r in MM_RES:
        for s in MM_SECONDS:
            t[f"minimax_{s}_{r}"] = provisional_credits(cost_inr(MINIMAX, s, r))
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
        return "Wan 2.2" if self.provider == WAN else "MiniMax H3"


def route(kind: str, prompt: str, seconds: int, resolution: str, aspect_ratio: str) -> VideoSpec:
    p = (prompt or "").strip()
    if not p:
        raise VideoError("prompt is required", 422)
    if len(p) > MAX_PROMPT:
        raise VideoError(f"prompt too long (max {MAX_PROMPT} chars)", 422)
    if kind not in ("t2v", "i2v"):
        raise VideoError("kind must be t2v or i2v", 422)
    if seconds <= 5:
        if seconds not in WAN_SECONDS:
            raise VideoError(f"seconds must be one of {list(WAN_SECONDS + MM_SECONDS)}", 422)
        if resolution not in WAN_RES:
            raise VideoError(f"resolution for {seconds}s must be one of {list(WAN_RES)}", 422)
        if aspect_ratio not in WAN_ASPECTS:
            raise VideoError(f"aspect_ratio must be one of {list(WAN_ASPECTS)}", 422)
        return VideoSpec(WAN, kind, p, seconds, resolution, aspect_ratio)
    if not minimax_enabled():
        raise VideoError("videos longer than 5 s are not available", 403)
    if seconds not in MM_SECONDS:
        raise VideoError(f"seconds must be one of {list(WAN_SECONDS + MM_SECONDS)}", 422)
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


def _headers(provider: str) -> dict:
    k = _key(provider)
    if not k:
        raise VideoError("video generation is not configured", 503)
    return {"Authorization": f"Bearer {k}"} if provider == WAN else {"X-API-Key": k}


def _client(transport) -> httpx.AsyncClient:
    return httpx.AsyncClient(timeout=TIMEOUT, transport=transport)


# -- submit ------------------------------------------------------------------
async def submit(spec: VideoSpec, image: Optional[bytes] = None, image_mime: str = "image/jpeg",
                 transport=None) -> str:
    if spec.kind == "i2v" and not image:
        raise VideoError("image is required for image-to-video", 422)
    async with _client(transport) as c:
        try:
            if spec.provider == WAN:
                body = {"prompt": spec.prompt, "resolution": spec.resolution,
                        "aspect_ratio": spec.aspect_ratio, "seconds": spec.seconds}
                path = "/wan-2.2/14b/text-to-video"
                if spec.kind == "i2v":
                    body["image"] = f"data:{image_mime};base64," + base64.b64encode(image).decode()
                    path = "/wan-2.2/14b/image-to-video"
                r = await c.post(EIGHTSCALE_BASE + path, json=body, headers=_headers(WAN))
                if r.status_code >= 400:
                    raise _fail("Wan 2.2 submit", r)
                js = r.json() or {}
                rid = js.get("requestId") or js.get("request_id") or js.get("id")
            else:
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
        try:
            if provider == WAN:
                r = await c.get(f"{EIGHTSCALE_BASE}/status/{rid}", headers=_headers(WAN))
            else:
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
            if not url and provider == MINIMAX:
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
    """Best effort (8scale only while queued). Never raises."""
    if provider != WAN:
        return False
    try:
        async with _client(transport) as c:
            r = await c.post(f"{EIGHTSCALE_BASE}/cancel/{rid}", headers=_headers(WAN))
            return r.status_code < 300
    except Exception:
        return False
