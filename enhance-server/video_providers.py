"""v11.63 video generation: Phosor MiniMax H3 Turbo (Standard, 5/8/10/15 s).
v11.65: + Fast ⚡ = fal.ai MiniMax H3 Max Turbo (same lengths / resolutions,
FAL_KEY, queue API). Fast credits = the matching Standard cell for now
(credits TBD — not approved yet).
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
MINIMAX = "minimax"  # Phosor MiniMax H3 Turbo (Standard)
FAL = "fal"          # v11.65 fal.ai MiniMax H3 Max Turbo (Fast ⚡)
PROVIDERS = (WAN, MINIMAX, FAL)

FAL_QUEUE = "https://queue.fal.run"
FAL_APP = "minimax/h3-max-turbo"   # status / result / cancel use the app id
FAL_I2V = FAL_APP + "/image-to-video"
FAL_T2V = FAL_APP + "/text-to-video"
FAL_RES = {"480p": "480P", "768p": "768P"}
# fal published standard rate from 16 Nov 2026 ($/s): 480p 0.025, 768p 0.04.
FAL_COST_INR_PER_S = {"480p": 0.025 * 93, "768p": 0.04 * 93}

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
    env = {WAN: "VIDEO_API_KEY", FAL: "FAL_KEY"}.get(provider, "PHOSOR_API_KEY")
    return os.environ.get(env, "").strip()


def configured(provider: str = MINIMAX) -> bool:
    """Standard needs PHOSOR_API_KEY, Fast needs FAL_KEY. VIDEO_API_KEY is
    unused except HMAC."""
    return bool(_key(FAL if provider == FAL else MINIMAX))


def minimax_enabled() -> bool:
    """Licence region policy switch (undecided → default allow everywhere).
    When off, all video is unavailable (everything is MiniMax)."""
    return os.environ.get("MINIMAX_ENABLED", "1").strip() not in ("0", "false", "no")


def provisional_credits(cost_inr: float) -> int:
    return max(1, math.ceil(round(cost_inr * MARGIN / INR_PER_CREDIT, 6)))


def cost_inr(provider: str, seconds: int, resolution: str) -> float:
    if provider == FAL:
        return round(FAL_COST_INR_PER_S[resolution] * seconds, 3)
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
    # v11.65 Fast ⚡ (fal): credits TBD — for now the SAME as the matching
    # Standard cell (fal_<s>_<res> = minimax_<s>_<res>); an explicit
    # fal_* key in the env / admin override wins.
    fal = {f"fal_{s}_{r}": t[f"minimax_{s}_{r}"] for r in MM_RES for s in MM_SECONDS}
    for src in (_env_override(), override or {}):
        for k, v in src.items():
            try:
                if k in fal and int(v) >= 0:
                    fal[k] = int(v)
            except (TypeError, ValueError):
                continue
    t.update(fal)
    return t


def _env_override() -> dict:
    try:
        ov = json.loads(os.environ.get("VIDEO_CREDITS_JSON", "") or "{}")
        return ov if isinstance(ov, dict) else {}
    except Exception:
        return {}


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
        return model_label(self.provider)


def model_label(provider: str) -> str:
    return {MINIMAX: "MiniMax H3", FAL: "MiniMax H3 Max Turbo"}.get(provider, "Wan 2.2")


def route(kind: str, prompt: str, seconds: int, resolution: str, aspect_ratio: str,
          fast: bool = False) -> VideoSpec:
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
    return VideoSpec(FAL if fast else MINIMAX, kind, p, seconds, resolution, aspect_ratio)


# -- signed job ids -----------------------------------------------------------
def _sig(device_id: str, provider: str, rid: str, credits: int) -> str:
    base = _key(WAN) + _key(MINIMAX)
    if not base:
        base = _key(FAL)  # v11.65: Fast-only server (no Phosor key)
    secret = hashlib.sha256(b"video-job-v1153:" + base.encode()).digest()
    msg = f"{device_id}|{provider}|{rid}|{credits}".encode()
    return hmac.new(secret, msg, hashlib.sha256).hexdigest()[:24]


def make_job_id(device_id: str, provider: str, rid: str, credits: int) -> str:
    return f"{provider}~{rid}~{credits}.{_sig(device_id, provider, rid, credits)}"


def parse_job_id(device_id: str, job_id: str) -> tuple[str, str, int]:
    """→ (provider, request_id, credits) — all covered by the signature."""
    head, _, sig = (job_id or "").rpartition(".")
    parts = head.split("~")
    if len(parts) != 3 or parts[0] not in PROVIDERS or not _RID.match(parts[1]) \
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
    for k in (_key(WAN), _key(MINIMAX), _key(FAL)):
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
    if spec.provider == FAL:
        return await _fal_submit(spec, image, image_mime, transport)
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


def _fal_headers() -> dict:
    k = _key(FAL)
    if not k:
        raise VideoError("fast video is not configured", 503)
    return {"Authorization": f"Key {k}", "Content-Type": "application/json"}


def fal_body(spec: VideoSpec, image_url: Optional[str] = None) -> dict:
    """fal MiniMax H3 Max Turbo input (llms.txt, Nov 2026): prompt, duration
    (s), resolution "480P"/"768P", prompt_expansion_mode (required),
    image_url (i2v: first frame, canvas follows the image), aspect_ratio
    (t2v only)."""
    body = {"prompt": spec.prompt, "duration": spec.seconds,
            "resolution": FAL_RES[spec.resolution],
            "prompt_expansion_mode": "disabled", "enable_safety_checker": True}
    if spec.kind == "i2v":
        body["image_url"] = image_url
    else:
        body["aspect_ratio"] = spec.aspect_ratio
    return body


def _fal_image_url(image: bytes, mime: str) -> str:
    """Base64 data URI (fal accepts data URIs), downscaled to ≤1536 px."""
    import base64
    import io
    try:
        from PIL import Image, ImageOps
        im = ImageOps.exif_transpose(Image.open(io.BytesIO(image))).convert("RGB")
        im.thumbnail((1536, 1536), Image.LANCZOS)
        buf = io.BytesIO()
        im.save(buf, "JPEG", quality=90)
        image, mime = buf.getvalue(), "image/jpeg"
    except Exception:  # noqa: BLE001 — send the original bytes
        pass
    return f"data:{mime};base64,{base64.b64encode(image).decode()}"


async def _fal_submit(spec: VideoSpec, image: Optional[bytes], mime: str, transport=None) -> str:
    path = FAL_I2V if spec.kind == "i2v" else FAL_T2V
    url = _fal_image_url(image, mime) if spec.kind == "i2v" else None
    async with _client(transport) as c:
        try:
            r = await c.post(f"{FAL_QUEUE}/{path}", json=fal_body(spec, url), headers=_fal_headers())
            if r.status_code >= 400:
                raise _fail("Fast video submit", r)
            js = r.json() or {}
            rid = js.get("request_id")
        except httpx.TimeoutException as e:
            raise VideoError("provider timed out during submit — not retried (job may still run)", 504) from e
        except httpx.HTTPError as e:
            raise VideoError(f"provider unreachable: {type(e).__name__}") from e
    if not rid or not _RID.match(str(rid)):
        raise VideoError("provider returned no request id")
    return str(rid)


async def _fal_status(rid: str, transport=None) -> dict:
    base = f"{FAL_QUEUE}/{FAL_APP}/requests/{rid}"
    async with _client(transport) as c:
        try:
            r = await c.get(base + "/status", headers=_fal_headers())
            if r.status_code == 404:
                raise VideoError("unknown job id", 404)
            if r.status_code >= 400:
                raise _fail("status", r)
            js = r.json() or {}
            st = str(js.get("status", "")).upper()
            if st == "IN_QUEUE":
                return {"status": "queued", "progress": None}
            if st != "COMPLETED":
                return {"status": "running", "progress": None}
            if js.get("error"):
                return {"status": "failed", "error": str(js.get("error"))[:300]}
            rr = await c.get(base, headers=_fal_headers())
            if rr.status_code == 202:
                return {"status": "running", "progress": None}
            if rr.status_code >= 400:
                return {"status": "failed", "error": f"result failed (HTTP {rr.status_code}): {error_text(rr)}"}
            out = rr.json() or {}
        except httpx.HTTPError as e:
            raise VideoError(f"provider unreachable: {type(e).__name__}") from e
    v = out.get("video") if isinstance(out, dict) else None
    url = v.get("url") if isinstance(v, dict) else None
    if not url or not str(url).startswith("http"):
        url = _find_url(out)
    if not url:
        return {"status": "failed", "error": "provider returned no video"}
    return {"status": "done", "video_url": url}


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
    if provider == FAL:
        return await _fal_status(rid, transport)
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
    """Phosor has no cancel API (no-op). fal: PUT …/requests/{id}/cancel
    (only works while IN_QUEUE). Never raises."""
    if provider != FAL or not _key(FAL):
        return False
    try:
        async with _client(transport) as c:
            r = await c.put(f"{FAL_QUEUE}/{FAL_APP}/requests/{rid}/cancel", headers=_fal_headers())
        return r.status_code < 300
    except Exception:  # noqa: BLE001
        return False
