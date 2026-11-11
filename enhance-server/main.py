"""
AI Camera enhance server (v11) — keeps OPENROUTER_API_KEY, the credits
ledger and the AI style library (hidden prompts + reference images)
server-side.

Endpoints
  GET  /health
  GET  /v1/products                       catalogue + tier prices
  GET  /v1/account?device_id=…            balance, Pro status, starter trials
  GET  /v1/trials?device_id=…             starter-trial status only
  GET  /v1/history?device_id=…            ledger entries (debug)
  POST /v1/purchase  {device_id, product_id}   TEST MODE purchase (no money)
  POST /v1/enhance   multipart: device_id, image, [context], quality, zoom,
                     optical_limit, [filter_id], [night], v11: [mode]
                     (photo|portrait|night|macro), [color_filter], [subject]
                     → image bytes; 402 {detail:{reason}} when not allowed;
                       502 on upstream failure (nothing charged);
                       v11 Pro Night guard: 400 {reason:"too_dark"} (no AI
                       call) / 422 {reason:"structure_changed"} (AI result
                       rejected) — nothing charged
  GET  /v1/styles                          enabled styles, NO prompts
  GET  /media/styles/{file}                public style display images
  POST /v1/looks/apply  multipart: device_id, image, style_id | custom_prompt,
                     [quality] (custom only), [variations 1..4]
                     → JSON {images:[b64…], credits_charged, trials_used,
                       account, cost}; 402/502 as above (nothing charged)
  GET  /v1/poses                           v11 Pose-mode photo library (free; id,
                                           name, category, photo_url, credit)
  GET  /media/poses/{file}                 public pose reference photos (JPEG)
  GET  /admin        password-protected style library admin (see admin.py)
  GET  /admin/poses  pose photo library admin (photo, category, order, enabled)
  GET  /admin/prompts v11 hidden Pro AI prompts (portrait / night / macro /
                     premium color filters), editable + reset to default
  POST /enhance      legacy v6 endpoint (disabled unless ENABLE_LEGACY_ENHANCE=1)

Env
  OPENROUTER_API_KEY     required for real enhance
  LEDGER_DB              SQLite path (default ./ledger.sqlite3)
  ALLOW_TEST_PURCHASES   "1" (default) enables fake purchases
  ENHANCE_MOCK           "1" → never call OpenRouter, return a resized copy
  ENABLE_LEGACY_ENHANCE  "1" → keep the old free /enhance endpoint
  ADMIN_PASSWORD         enables /admin (unset → admin disabled)
  STYLES_BACKEND         "sqlite" (default) or "supabase" (+ SUPABASE_URL,
                         SUPABASE_SERVICE_ROLE_KEY; table public.styles,
                         buckets style-thumbs / private style-refs)
  ADMIN_API_TOKEN        enables the JSON style API /admin/api/* (Bearer token;
                         unset → API returns 503). Separate from ADMIN_PASSWORD.
  STYLES_DB              styles SQLite path (default ./styles.sqlite3)
  STYLE_MEDIA_DIR        public style images (default ./media/styles);
                         reference images go to <STYLE_MEDIA_DIR>_refs (private)
  POSES_DB               poses SQLite path (default ./poses.sqlite3)
  POSE_MEDIA_DIR         pose photos (default ./media/poses); seeded from
                         seed_poses.json + seed_poses/ on first run
  MODE_PROMPTS_DB        admin prompt overrides (default ./mode_prompts.sqlite3)
  PORT                   default 8787
  GET  /v1/video/options                      credits per provider/length/resolution
  POST /v1/video/generate  multipart: device_id, prompt|style_id, kind t2v|i2v, seconds,
                           resolution, aspect_ratio, [image] → {job_id, credits, model_label}
  GET  /v1/video/status/{job_id}?device_id=…   queued|running|done (+video_url, charged once)|failed
  POST /v1/video/cancel/{job_id}               best effort, never charged
  VIDEO_API_KEY (8scale) / PHOSOR_API_KEY (Phosor) in .env; MINIMAX_ENABLED (1);
  VIDEO_CREDITS_JSON overrides; VIDEO_PER_DEVICE_PER_HOUR (10)
"""
from __future__ import annotations

import asyncio
import base64
import datetime as dt
import io
import logging
import json
import os
from typing import Optional

import httpx
from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response
from PIL import Image, ImageOps
from pydantic import BaseModel

import envload

# Load enhance-server/.env (FAL_KEY …) without overriding real env vars.
envload.load_env_file(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))

import admin  # noqa: E402
import color_match as CM
import image_guard as G
import ledger as L
import mode_prompts as MP
import poses as PO
import prompts as P
import styles as S
import video_providers as VP  # noqa: E402
import video_log as VL  # noqa: E402

log = logging.getLogger("enhance")
logging.basicConfig(level=logging.INFO)

OPENROUTER_URL = "https://openrouter.ai/api/v1/images"
OPENROUTER_CHAT_URL = "https://openrouter.ai/api/v1/chat/completions"
DETECT_TIMEOUT = float(os.environ.get("DETECT_TIMEOUT", "5"))
# v11.29 shutter spot: flash try + one flash-lite retry within the app's ~10 s.
SPOT_TIMEOUT = float(os.environ.get("SPOT_TIMEOUT", "6"))
SPOT_RETRY_TIMEOUT = float(os.environ.get("SPOT_RETRY_TIMEOUT", "3.5"))
DETECT_LONG = 768  # v11.49: was 512 (box check names the object)
MODEL = "openai/gpt-image-2.5-flare"
# v11.58 style models (per style, admin "Model" select; fallback = Custom/Flare).
KLEIN_MODEL = os.environ.get("KLEIN_MODEL", "black-forest-labs/flux-3-image-klein")
RUNWARE_URL = "https://api.runware.ai/v1"
RUNWARE_KLEIN4B_MODEL = os.environ.get("RUNWARE_KLEIN4B_MODEL", "runware:400@4")
RUNWARE_LONG = 1024  # FLUX.2 Klein 4B ~1 MP output
MAX_UPLOAD_BYTES = 25 * 1024 * 1024

app = FastAPI(title="AI Camera Enhance Server", version="11.1.59")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

_ledger: Optional[L.Ledger] = None
_styles: Optional[S.StyleStore] = None
_poses: Optional[PO.PoseStore] = None
_mode_prompts: Optional[MP.ModePromptStore] = None
_device_locks: dict[str, asyncio.Lock] = {}
HERE = os.path.dirname(os.path.abspath(__file__))


def now_utc() -> dt.datetime:
    """Clock (monkeypatched in tests for daily-reset checks)."""
    return dt.datetime.now(dt.timezone.utc)


def get_ledger() -> L.Ledger:
    global _ledger
    if _ledger is None:
        _ledger = L.Ledger(os.environ.get("LEDGER_DB", "ledger.sqlite3"))
    return _ledger


def reset_ledger(path: str) -> None:
    """Tests: point the app at a fresh DB."""
    global _ledger, _video_log
    _ledger = L.Ledger(path)
    _video_log = VL.SafeLog(VL.SqliteVideoLog(path + ".videos"))
    _device_locks.clear()


_video_log = None


def get_video_log() -> "VL.SafeLog":
    global _video_log
    if _video_log is None:
        if os.environ.get("STYLES_BACKEND", "sqlite").lower() == "supabase":
            _video_log = VL.SafeLog(VL.SupabaseVideoLog(os.environ.get("SUPABASE_URL", ""),
                                                        os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")))
        else:
            _video_log = VL.SafeLog(VL.SqliteVideoLog(os.environ.get("VIDEO_LOG_DB", "video_jobs.sqlite3")))
    return _video_log


def get_styles() -> S.StyleStore:
    global _styles
    if _styles is None and os.environ.get("STYLES_BACKEND", "sqlite").lower() == "supabase":
        import supabase_styles as SB
        _styles = SB.SupabaseStyleStore(os.environ.get("SUPABASE_URL", ""),
                                        os.environ.get("SUPABASE_SERVICE_ROLE_KEY", ""))
    if _styles is None:
        _styles = S.StyleStore(os.environ.get("STYLES_DB", "styles.sqlite3"),
                               os.environ.get("STYLE_MEDIA_DIR", os.path.join("media", "styles")))
        _styles.seed_if_empty(os.path.join(HERE, "seed_styles.json"), os.path.join(HERE, "seed_media"))
    return _styles


def reset_styles(db_path: str, media_dir: str) -> S.StyleStore:
    """Tests: fresh style store (seeded)."""
    global _styles
    _styles = S.StyleStore(db_path, media_dir)
    _styles.seed_if_empty(os.path.join(HERE, "seed_styles.json"), os.path.join(HERE, "seed_media"))
    return _styles


def _seed_poses(store: PO.PoseStore) -> PO.PoseStore:
    store.seed_if_empty(os.path.join(HERE, "seed_poses.json"), os.path.join(HERE, "seed_poses"))
    return store


def get_poses() -> PO.PoseStore:
    global _poses
    if _poses is None:
        _poses = _seed_poses(PO.PoseStore(os.environ.get("POSES_DB", "poses.sqlite3"),
                                          os.environ.get("POSE_MEDIA_DIR", os.path.join("media", "poses"))))
    return _poses


def reset_poses(db_path: str, media_dir: str, seed: bool = True) -> PO.PoseStore:
    """Tests: fresh pose store (seeded unless seed=False)."""
    global _poses
    _poses = PO.PoseStore(db_path, media_dir)
    if seed:
        _seed_poses(_poses)
    return _poses


def get_mode_prompts() -> MP.ModePromptStore:
    global _mode_prompts
    if _mode_prompts is None:
        _mode_prompts = MP.ModePromptStore(os.environ.get("MODE_PROMPTS_DB", "mode_prompts.sqlite3"))
    return _mode_prompts


def macro_credit_table() -> dict:
    """v11.33 Macro credits (defaults + admin override)."""
    raw = get_mode_prompts().get_config("macro_credits")
    try:
        ov = json.loads(raw) if raw else None
    except Exception:  # noqa: BLE001
        ov = None
    return P.merge_macro_credits(ov if isinstance(ov, dict) else None)


def reset_mode_prompts(db_path: str) -> MP.ModePromptStore:
    """Tests: fresh prompt store (all defaults)."""
    global _mode_prompts
    _mode_prompts = MP.ModePromptStore(db_path)
    return _mode_prompts


app.include_router(admin.build_router(lambda: get_styles()))
app.include_router(admin.build_style_api_router(lambda: get_styles()))
app.include_router(admin.build_pose_router(lambda: get_poses()))
app.include_router(admin.build_prompt_router(lambda: get_mode_prompts()))
app.include_router(admin.build_macro_credits_router(lambda: get_mode_prompts()))
app.include_router(admin.build_video_admin_router(lambda: get_mode_prompts(), lambda: get_video_log()))


def _flag(name: str, default: str = "0") -> bool:
    return os.environ.get(name, default).strip() in ("1", "true", "yes")


def _check_device(device_id: str) -> str:
    d = (device_id or "").strip()
    if not (4 <= len(d) <= 128) or not all(c.isalnum() or c in "-_." for c in d):
        raise HTTPException(status_code=400, detail="invalid device_id")
    return d


def _api_key() -> str:
    key = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if not key:
        raise HTTPException(status_code=500, detail="OPENROUTER_API_KEY not configured")
    return key


# --------------------------------------------------------------------------
# Image helpers
# --------------------------------------------------------------------------
ASPECTS = {"1:1": 1.0, "3:2": 1.5, "2:3": 2 / 3, "4:3": 4 / 3, "3:4": 3 / 4,
           "16:9": 16 / 9, "9:16": 9 / 16, "21:9": 21 / 9}


def aspect_for(w: int, h: int) -> str:
    if w <= 0 or h <= 0:
        return "3:4"
    r = w / h
    return min(ASPECTS.items(), key=lambda kv: abs(kv[1] - r))[0]


def prepare(raw: bytes, max_long: int) -> tuple[bytes, int, int]:
    """EXIF-upright (no stretch), ≤max_long, JPEG."""
    im = Image.open(io.BytesIO(raw))
    im = ImageOps.exif_transpose(im).convert("RGB")
    if max(im.size) > max_long:
        im.thumbnail((max_long, max_long), Image.LANCZOS)
    out = io.BytesIO()
    im.save(out, "JPEG", quality=100)  # v11.58: no lossy q90 re-encode
    return out.getvalue(), im.width, im.height


MACRO_CONTEXT_LONG = 1024


def ensure_min_long_side(raw: bytes, min_long: int) -> bytes:
    im = Image.open(io.BytesIO(raw))
    long = max(im.size)
    if long >= min_long * 0.98:
        return raw
    s = min_long / long
    im = im.convert("RGB").resize((round(im.width * s), round(im.height * s)), Image.LANCZOS)
    out = io.BytesIO()
    im.save(out, "JPEG", quality=95)
    return out.getvalue()


# v9.1: Flare answers in ~10–30 s; a stalled call fails after this (504,
# nothing charged) instead of hanging the phone for 4 minutes.
UPSTREAM_TIMEOUT = float(os.environ.get("UPSTREAM_TIMEOUT", "90"))
LOOK_INPUT_LONG = 1536  # looks: Flare returns ~1.5K anyway
ENHANCE_INPUT_LONG = 2048


def ai_failure(status: int, reason: str, message: str) -> HTTPException:
    """502/504 with a machine-readable reason (timeout / no_image / refused /
    upstream) so the app can show a clear message. Nothing is charged."""
    return HTTPException(status_code=status, detail={"reason": reason, "message": message[:400]})


def upstream_failure(status: int, body) -> HTTPException:
    text = str(body)[:500]
    if status == 200:
        return ai_failure(502, "refused" if P.looks_like_refusal(text) else "no_image",
                          f"no image in response: {text}")
    if status == 400 and P.looks_like_refusal(text):
        return ai_failure(502, "refused", f"OpenRouter {status}: {text}")
    return ai_failure(502, "upstream", f"OpenRouter {status}: {text}")


def data_url(b: bytes) -> str:
    return "data:image/jpeg;base64," + base64.b64encode(b).decode("ascii")


def is_multi_image_rejection(status: int) -> bool:
    return 400 <= status < 500 and status not in (401, 402, 403, 429)


async def call_openrouter(payload: dict) -> tuple[int, dict | str]:
    """Upstream call (monkeypatched in tests). Returns (status, json|text)."""
    if _flag("ENHANCE_MOCK"):
        refs = payload.get("input_references") or []
        if refs:
            ref = refs[0]["image_url"]["url"].split(",", 1)[1]
        else:  # v11.30 text-only (Macro Extreme / Ultra): plain grey image
            buf = io.BytesIO()
            Image.new("RGB", (512, 512), (128, 128, 128)).save(buf, "JPEG")
            ref = base64.b64encode(buf.getvalue()).decode("ascii")
        return 200, {"data": [{"b64_json": ref}], "usage": {"cost": 0}}
    headers = {
        "Authorization": f"Bearer {_api_key()}",
        "Content-Type": "application/json",
        "HTTP-Referer": "https://ai-camera.local",
        "X-Title": "AI Camera Enhance Server",
    }
    async with httpx.AsyncClient(timeout=UPSTREAM_TIMEOUT) as client:
        resp = await client.post(OPENROUTER_URL, json=payload, headers=headers)
    try:
        return resp.status_code, resp.json()
    except Exception:
        return resp.status_code, resp.text


async def extract_image(body: dict) -> bytes:
    data = (body.get("data") or [None])[0]
    if not data:
        raise ValueError("no image in response")
    b64 = data.get("b64_json") or data.get("b64")
    if b64:
        return base64.b64decode(b64)
    if data.get("url"):
        async with httpx.AsyncClient(timeout=60.0) as client:
            r = await client.get(data["url"])
            r.raise_for_status()
            return r.content
    raise ValueError("unexpected image payload")


def build_payload(prompt: str, tier: str, aspect: str, image_url: Optional[str], context_url: Optional[str],
                  extra_urls: Optional[list[str]] = None, n: int = 1,
                  leading_urls: Optional[list[str]] = None) -> dict:
    _, _, quality, resolution, _ = L.TIERS[tier]
    refs = [{"type": "image_url", "image_url": {"url": u}} for u in leading_urls or []]
    if image_url:  # v11.30: None → text-only (Macro Extreme / Ultra)
        refs.append({"type": "image_url", "image_url": {"url": image_url}})
    if context_url:
        refs.append({"type": "image_url", "image_url": {"url": context_url}})
    for u in extra_urls or []:
        refs.append({"type": "image_url", "image_url": {"url": u}})
    out = {
        "model": MODEL,
        "prompt": prompt,
        "quality": quality,
        "resolution": resolution,
        "aspect_ratio": aspect,
        "n": n,
        "output_format": "jpeg",
    }
    if refs:
        out["input_references"] = refs
    return out


def klein_payload(prompt: str, aspect: str, image_url: str) -> dict:
    """v11.58 FLUX Klein (OpenRouter): the user's photo ONLY (no style
    reference images) and no quality / resolution params (Klein supports
    neither)."""
    return {
        "model": KLEIN_MODEL,
        "prompt": prompt,
        "aspect_ratio": aspect,
        "n": 1,
        "output_format": "jpeg",
        "input_references": [{"type": "image_url", "image_url": {"url": image_url}}],
    }


def _runware_key() -> str:
    return os.environ.get("RUNWARE_API_KEY", "").strip()


def runware_size(w: int, h: int, long_side: int = RUNWARE_LONG) -> tuple[int, int]:
    """Runware wants 128–2048 px, multiples of 16, same aspect as the photo."""
    s = long_side / max(w, h, 1)
    def r16(v: float) -> int:
        return max(128, min(2048, int(round(v / 16.0)) * 16))
    return r16(w * s), r16(h * s)


def runware_payload(prompt: str, image_url: str, w: int, h: int) -> list:
    import uuid
    rw, rh = runware_size(w, h)
    return [{
        "taskType": "imageInference",
        "taskUUID": str(uuid.uuid4()),
        "model": RUNWARE_KLEIN4B_MODEL,
        "positivePrompt": prompt,
        "width": rw,
        "height": rh,
        "inputs": {"referenceImages": [image_url]},
        "outputType": "base64Data",
        "outputFormat": "JPG",
        "numberResults": 1,
        "includeCost": True,
    }]


async def call_runware(tasks: list) -> tuple[int, dict | str]:
    """Runware FLUX.2 Klein 4B (monkeypatched in tests). Key from env
    RUNWARE_API_KEY, never logged."""
    if _flag("ENHANCE_MOCK"):
        ref = tasks[0]["inputs"]["referenceImages"][0].split(",", 1)[1]
        return 200, {"data": [{"imageBase64Data": ref, "cost": 0}]}
    key = _runware_key()
    if not key:
        return 503, "runware not configured"
    async with httpx.AsyncClient(timeout=UPSTREAM_TIMEOUT) as client:
        resp = await client.post(RUNWARE_URL, json=tasks, headers={
            "Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    try:
        return resp.status_code, resp.json()
    except Exception:
        return resp.status_code, resp.text


async def runware_images(body: dict) -> tuple[list[bytes], float]:
    out, cost = [], 0.0
    for d in body.get("data") or []:
        if not isinstance(d, dict):
            continue
        cost += float(d.get("cost") or 0)
        b64 = d.get("imageBase64Data")
        if b64:
            out.append(base64.b64decode(b64.split(",", 1)[-1]))
        elif d.get("imageURL"):
            async with httpx.AsyncClient(timeout=60.0) as client:
                r = await client.get(d["imageURL"])
                r.raise_for_status()
                out.append(r.content)
    return out, cost


def style_model_for(style) -> str:
    """Model actually used for a style: its admin model, or "custom" when the
    model is unknown / its provider is not configured (fallback to Custom)."""
    m = S.normalize_style_model(getattr(style, "model", None)) if style else "custom"
    if m == "runware_klein4b" and not (_runware_key() or _flag("ENHANCE_MOCK")):
        return "custom"
    return m


def look_quality(tier: str) -> str:
    """Looks use Flare low (HD) / medium (everything else): `high` doubled
    latency and cost in v9.1 measurements with no visible gain on edits."""
    return "low" if tier == "hd" else "medium"


def look_tier(tier: str) -> str:
    """Custom changes offer HD / Full HD only; UHD / 4K clamp to Full HD."""
    return "full_hd" if tier in L.PREMIUM_TIERS else tier


async def extract_images(body: dict) -> list[bytes]:
    out = []
    for i in range(len(body.get("data") or [])):
        try:
            out.append(await extract_image({"data": [body["data"][i]]}))
        except Exception as e:  # skip a bad entry, keep the rest
            log.warning("bad image entry %s: %s", i, e)
    return out


# --------------------------------------------------------------------------
# Routes
# --------------------------------------------------------------------------
@app.get("/health")
async def health():
    return {
        "ok": True,
        "version": app.version,
        "model": MODEL,
        "has_key": bool(os.environ.get("OPENROUTER_API_KEY")),
        "mock": _flag("ENHANCE_MOCK"),
        "test_purchases": _flag("ALLOW_TEST_PURCHASES", "1"),
    }


@app.get("/v1/products")
async def products():
    return {
        "test_mode": _flag("ALLOW_TEST_PURCHASES", "1"),
        "products": [{"id": k, **v} for k, v in L.PRODUCTS.items()],
        "tiers": [{"id": k, "label": v[0], "credits": v[1]} for k, v in L.TIERS.items()],
        "free_daily": L.FREE_DAILY,
    }


def _account_json(device_id: str, s: L.State, now: dt.datetime) -> dict:
    return {
        "device_id": device_id,
        "state": s.to_json(),
        "is_pro": s.is_pro(now),
        "total": s.total(now),
        "date_ist": L.ist_date(now),
        "trials_available": [t for t in L.TRIALS if t not in s.trials_used],
    }


@app.get("/v1/account")
async def account(device_id: str):
    d = _check_device(device_id)
    now = now_utc()
    return _account_json(d, get_ledger().load(d, now), now)


@app.get("/v1/trials")
async def trials(device_id: str):
    d = _check_device(device_id)
    s = get_ledger().load(d, now_utc())
    return {"used": sorted(s.trials_used), "available": [t for t in L.TRIALS if t not in s.trials_used]}


@app.get("/v1/history")
async def history(device_id: str):
    d = _check_device(device_id)
    return {"entries": get_ledger().history(d)}


class PurchaseIn(BaseModel):
    device_id: str
    product_id: str


_LAST_FINISH: dict = {"v": ""}


async def call_vision(payload: dict) -> str:
    """v11.15 cheap vision text call (network-blocked / patched in tests)."""
    if _flag("ENHANCE_MOCK"):
        return ""
    headers = {
        "Authorization": f"Bearer {_api_key()}",
        "Content-Type": "application/json",
        "HTTP-Referer": "https://ai-camera.local",
        "X-Title": "AI Camera Enhance Server",
    }
    async with httpx.AsyncClient(timeout=DETECT_TIMEOUT) as client:
        resp = await client.post(OPENROUTER_CHAT_URL, json=payload, headers=headers)
    resp.raise_for_status()
    ch = resp.json()["choices"][0]
    _LAST_FINISH["v"] = ch.get("finish_reason") or ""  # v11.29 spot retry
    c = ch["message"].get("content")
    if isinstance(c, list):  # v11.21: content parts
        c = " ".join(p.get("text", "") for p in c if isinstance(p, dict))
    return c or ""


def detect_payload(text: str, jpgs: list[bytes], max_tokens: int, model: str = "",
                   no_thinking: bool = False) -> dict:
    content: list = [{"type": "text", "text": text}]
    for j in jpgs:
        content.append({"type": "image_url", "image_url": {"url": data_url(j)}})
    out = {"model": model or P.DETECT_MODEL, "max_tokens": max_tokens, "temperature": 0,
           "messages": [{"role": "user", "content": content}]}
    if no_thinking:  # v11.29: never spend the budget on hidden reasoning
        out["reasoning"] = {"max_tokens": 0}
    return out


async def _vision_text(payload: dict, timeout: float = 0) -> str:
    _LAST_FINISH["v"] = ""
    try:
        return await asyncio.wait_for(call_vision(payload), timeout or DETECT_TIMEOUT)
    except Exception as e:  # noqa: BLE001
        log.warning("detect failed: %s", e)
        return ""


@app.get("/v1/macro/credits")
async def macro_credits():
    """v11.33 credits per Macro quality + level; locked qualities can't be
    bought yet ("Coming soon")."""
    return {"credits": macro_credit_table(), "locked": list(P.MACRO_LOCKED_QUALITIES),
            "qualities": list(P.MACRO_QUALITIES)}


@app.post("/v1/macro/box")
async def macro_box(device_id: str = Form(...), image: UploadFile = File(...),
                    wide: Optional[UploadFile] = File(None)):
    """v11.33 shutter: ONE check on the box area → {spot, clear, model}.
    Spot-check model setup (flash, thinking off, lite retry). Free."""
    _check_device(device_id)
    a, _, _ = prepare(await image.read(), DETECT_LONG)
    # v11.49: optional wider view first (overview + zoomed centre).
    imgs, prompt = [a], P.DETECT_BOX_PROMPT
    if wide is not None:
        raw_w = await wide.read()
        if raw_w:
            imgs = [prepare(raw_w, DETECT_LONG)[0], a]
            prompt = P.DETECT_BOX_WIDE_LINE + P.DETECT_BOX_PROMPT
    text = await _vision_text(detect_payload(prompt, imgs, P.DETECT_SPOT_MAX_TOKENS,
                                             P.DETECT_SPOT_MODEL, no_thinking=True),
                              SPOT_TIMEOUT)
    source = "flash"
    if not text.strip() or _LAST_FINISH["v"] == "length":
        source = "lite"
        text = await _vision_text(detect_payload(prompt, imgs, P.DETECT_MAX_TOKENS),
                                  SPOT_RETRY_TIMEOUT)
    spot, clear = P.parse_box_reply(text)
    if clear and P.is_vague_detect(spot):  # v11.49: look words only
        clear = False
    return {"spot": spot if clear else "", "clear": clear, "model": source}


@app.post("/v1/macro/subject")
async def macro_subject(device_id: str = Form(...), image: UploadFile = File(...)):
    """1.5x photo → centre object (≤8 words) + other visible objects
    (v11.22). Free; "" on failure."""
    _check_device(device_id)
    jpg, _, _ = prepare(await image.read(), DETECT_LONG)
    text = await _vision_text(detect_payload(P.DETECT_SUBJECT_PROMPT, [jpg], P.DETECT_MAX_TOKENS))
    main, others = P.parse_subject_reply(text)
    fill, whole = P.parse_fill(text)  # v11.32 level unlock by frame fill
    return {"name": main, "others": others, "fill": fill, "whole": whole}


def _others_field(raw: str) -> list[str]:
    try:
        v = json.loads(raw) if raw else []
    except Exception:  # noqa: BLE001
        v = [x for x in raw.split(";")]
    return [str(x) for x in v][:P.DETECT_MAX_OTHERS] if isinstance(v, list) else []


@app.post("/v1/macro/part")
async def macro_part(device_id: str = Form(...), parent: str = Form(...),
                     others: str = Form(""),
                     one_x: UploadFile = File(...), step: UploadFile = File(...)):
    """1.5x photo + boxed step photo → {object, part, in_scene} (v11.22;
    same_subject = in_scene for older apps). Free."""
    _check_device(device_id)
    a, _, _ = prepare(await one_x.read(), DETECT_LONG)
    b, _, _ = prepare(await step.read(), DETECT_LONG)
    main = P.sanitize_detected(parent) or "the subject"
    prompt = (P.DETECT_PART_PROMPT.replace("{parent}", main)
              .replace("{objects}", P.objects_text(main, _others_field(others))))
    text = await _vision_text(detect_payload(prompt, [a, b], P.DETECT_MAX_TOKENS))
    obj, part, ins = P.parse_object_part_reply(text)
    fill, whole = P.parse_fill(text)  # v11.32 level unlock by frame fill
    return {"object": obj, "part": part, "in_scene": ins, "same_subject": ins,
            "fill": fill, "whole": whole}


@app.post("/v1/macro/spot")
async def macro_spot(device_id: str = Form(...), subject: str = Form(""),
                     others: str = Form(""),
                     overview: UploadFile = File(...), closer: UploadFile = File(...)):
    """At the shutter: 1.5x photo + last clear photo with the final zoom
    boxed → spot = object + part (v11.22). Free; "" on failure."""
    _check_device(device_id)
    a, _, _ = prepare(await overview.read(), DETECT_LONG)
    b, _, _ = prepare(await closer.read(), DETECT_LONG)
    main = P.sanitize_detected(subject) or "the subject"
    prompt = (P.DETECT_SPOT_PROMPT.replace("{subject}", main)
              .replace("{objects}", P.objects_text(main, _others_field(others))))
    # v11.29: flash with thinking off + 200 tokens; empty / cut off → one
    # retry on flash-lite.
    text = await _vision_text(detect_payload(prompt, [a, b], P.DETECT_SPOT_MAX_TOKENS,
                                             P.DETECT_SPOT_MODEL, no_thinking=True),
                              SPOT_TIMEOUT)
    source = "flash"
    if not text.strip() or _LAST_FINISH["v"] == "length":
        source = "lite"
        text = await _vision_text(detect_payload(prompt, [a, b], P.DETECT_MAX_TOKENS),
                                  SPOT_RETRY_TIMEOUT)
    obj, part, ins = P.parse_object_part_reply(text)
    return {"spot": P.spot_text(obj, part), "object": obj, "part": part, "in_scene": ins,
            "model": source}


@app.post("/v1/purchase")
async def purchase(body: PurchaseIn):
    if not _flag("ALLOW_TEST_PURCHASES", "1"):
        raise HTTPException(status_code=403, detail="test purchases disabled; use Play Billing")
    d = _check_device(body.device_id)
    if body.product_id not in L.PRODUCTS:
        raise HTTPException(status_code=400, detail="unknown product")
    now = now_utc()
    s = get_ledger().purchase(d, body.product_id, now, test_mode=True)
    return {**_account_json(d, s, now), "test_mode": True}


@app.post("/v1/enhance")
async def enhance_v1(
    request: Request,
    device_id: str = Form(...),
    image: UploadFile = File(...),
    context: Optional[UploadFile] = File(None),
    steps: Optional[list[UploadFile]] = File(None),
    quality: str = Form("hd"),
    zoom: float = Form(1.0),
    optical_limit: float = Form(1.0),
    filter_id: Optional[str] = Form(None),
    night: bool = Form(False),
    mode: str = Form("photo"),
    color_filter: Optional[str] = Form(None),
    subject: Optional[str] = Form(None),
    macro_level: Optional[str] = Form(None),
    part: Optional[str] = Form(None),
    subject_sure: bool = Form(False),
    context_boxed: bool = Form(False),
    zoom_ladder: bool = Form(False),
    zoom_clean: bool = Form(False),
    zoom_source: bool = Form(False),
):
    dev = _check_device(device_id)
    mode = (mode or "photo").strip().lower()
    if night:
        mode = "night"  # v10 clients
    if quality == "4k":
        quality = "ultra_hd"  # v11.39: 4K removed from the picker (2K "Coming soon")
    if quality not in L.TIERS and not (mode == "macro" and quality in P.MACRO_QUALITIES):
        raise HTTPException(status_code=400, detail="unknown quality")
    if night:
        mode = "night"  # v10 clients
    if mode not in P.MODES:
        raise HTTPException(status_code=400, detail="unknown mode")
    if color_filter and color_filter not in P.COLOR_FILTER_PROMPTS:
        raise HTTPException(status_code=400, detail="unknown color filter")
    raw = await image.read()
    if not raw or len(raw) > MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=400, detail="empty or too large image")
    ctx_raw = await context.read() if context is not None else b""
    # v11.13 Macro: the 1x / 2x / 3x / 4x step photos, each with the zoomed area boxed.
    steps_raw = [b for b in [await f.read() for f in (steps or [])[:4]] if b]
    # v11.30 100x zoom ladder (cheap phones): steps = boxed lower-zoom references.
    # v11.59 sharp-source zoom: image = the sharp aligned lower-zoom source,
    # steps[0] = the final zoom (framing only). No framing photo → fail closed.
    zsrc = bool(zoom_source) and mode == "photo"
    if zsrc and not steps_raw:
        raise HTTPException(status_code=422, detail={
            "reason": "no_sharp_source",
            "message": "Hold steady and retake the zoom. No credits used."})
    ladder = bool(zoom_ladder) and mode == "photo" and bool(steps_raw) and not zsrc
    # v11.34: 2x+ photo (flagship single / ladder with no matching refs).
    zoom_only = ((bool(zoom_clean) or bool(zoom_ladder)) and mode == "photo"
                 and not ladder and not zsrc)

    filt = P.FILTER_PROMPTS.get(filter_id or "")
    macro_credits = None
    if mode == "macro":
        if quality in P.MACRO_LOCKED_QUALITIES:
            raise HTTPException(status_code=400, detail={
                "reason": "coming_soon", "message": "2K is coming soon."})
        if quality not in ("hd", "full_hd"):
            raise HTTPException(status_code=400, detail="macro quality must be hd or full_hd")
        _lvl = macro_level if macro_level in P.MACRO_LEVELS else P.macro_level_for_zoom(zoom)
        # v11.33: credits by quality + level (admin-editable).
        macro_credits = P.macro_credits_for(_lvl, quality, macro_credit_table())
    spec = L.Spec(tier=quality, zoom=zoom, optical_limit=optical_limit, ai_filter=filt is not None,
                  credits=macro_credits)
    # Modes / color looks are add-ons to the enhance (no extra cost): their
    # hidden admin prompt is appended right after the locked enhance prompt.
    prompts_store = get_mode_prompts()
    mode_text = ""
    portrait_text = ""
    level = None
    if mode == "macro":
        # v11.1: the level comes from the zoom at shutter time (the app also
        # sends it; an unknown value falls back to the zoom mapping).
        level = macro_level if macro_level in P.MACRO_LEVELS else P.macro_level_for_zoom(zoom)
        mode_text = P.macro_prompt(prompts_store.get(P.MACRO_LEVELS[level][0]), subject, level, zoom,
                                       part=part)
        if level in ("microscope", "extreme", "ultra"):
            color_filter = None  # v11.9: no colour filter at Microscope / Extreme
    elif mode == "portrait":
        # v11.58: the Portrait variant of the universal prompt REPLACES the
        # base; Night uses the universal prompt alone (no night sentence).
        portrait_text = prompts_store.get("portrait")
    color_text = prompts_store.get(f"filter:{color_filter}") if color_filter else ""
    is_night = mode == "night"

    # v11 Pro Night guard (1): no real signal → never ask the AI to invent.
    if is_night:
        try:
            sig = G.night_signal(raw)
        except Exception as e:
            raise HTTPException(status_code=400, detail=f"bad image: {e}") from e
        if sig.too_dark:
            raise HTTPException(status_code=400, detail={
                "reason": "too_dark",
                "message": "Too dark for Pro Night. Use Normal Night or turn on flash.",
                "mean": round(sig.mean, 4)})

    lock = _device_locks.setdefault(dev, asyncio.Lock())
    async with lock:  # one enhance per device at a time → no double spend
        led = get_ledger()
        d = led.decide(dev, spec, now_utc())
        if not d.allowed:
            raise HTTPException(status_code=402, detail={"reason": d.reason})

        try:
            _text_only = P.macro_text_only(level, subject, part)  # v11.47
            _max_steps, _crop_long = P.macro_input_plan(level) if level else (0, None)
            if ladder:
                _crop_long = P.ZOOM_LADDER_MAIN_LONG  # v11.31: final photo 1536 px
            if zsrc:
                _crop_long = P.ZOOM_SOURCE_MAIN_LONG  # v11.59: the sharp source
            main_jpg, w, h = prepare(raw, _crop_long or ENHANCE_INPUT_LONG)
            if level is not None and not _text_only:
                main_jpg = CM.soften_chroma(main_jpg)  # v11.39 colour-noise clean-up
            ctx_jpg = prepare(ctx_raw, 768)[0] if ctx_raw else None
        except Exception as e:
            raise HTTPException(status_code=400, detail=f"bad image: {e}") from e
        aspect = aspect_for(w, h)

        is_macro = level is not None
        if ladder:
            # v11.30: ≤3 boxed references + the final photo; no wide context.
            ctx_raw, ctx_jpg = b"", None
            try:
                step_jpgs_ladder = [prepare(b, P.ZOOM_LADDER_LONG)[0]
                                    for b in steps_raw[:P.ZOOM_LADDER_MAX_REFS]]
            except Exception as e:
                raise HTTPException(status_code=400, detail=f"bad image: {e}") from e
        else:
            step_jpgs_ladder = []
        framing_jpg = None
        if zsrc:
            ctx_raw, ctx_jpg = b"", None
            try:
                framing_jpg = prepare(steps_raw[0], P.ZOOM_FRAMING_LONG)[0]
            except Exception as e:
                raise HTTPException(status_code=400, detail=f"bad image: {e}") from e
        # v11.40: Extreme / Ultra with no detected spot → the zoomed photo (+ context
        # photos) instead of the spot-text-only call.
        # v11.47: Microscope too (detected spot only).
        deep_text_only = P.macro_text_only(level, subject, part)
        if deep_text_only:
            # v11.19/20 (Ultra too): Extreme sends ONLY the spot text (no step photos /
            # boxed frame) — they made the model copy the whole object.
            steps_raw, ctx_raw, ctx_jpg = [], b"", None
        elif level in P.MACRO_DEEP_LEVELS:
            steps_raw, ctx_raw, ctx_jpg = steps_raw[:_max_steps], b"", None
        elif level is not None:
            # v11.26: Macro/Close crop only; Microscope ≤2 step photos at 768 px. No ctx.
            steps_raw, ctx_raw, ctx_jpg = steps_raw[:_max_steps], b"", None
        step_jpgs = []
        if is_macro:
            try:
                step_jpgs = [prepare(b, P.MACRO_STEP_LONG)[0] for b in steps_raw]
            except Exception as e:
                raise HTTPException(status_code=400, detail=f"bad image: {e}") from e
        if is_macro and ctx_raw:
            # v11.5: the 2nd image is the full sharp frame with the region
            # boxed in red — keep it big enough to read the box.
            try:
                ctx_jpg = prepare(ctx_raw, MACRO_CONTEXT_LONG)[0]
            except Exception as e:
                raise HTTPException(status_code=400, detail=f"bad image: {e}") from e

        def payload(with_ctx: bool) -> dict:
            ctx_url = data_url(ctx_jpg) if with_ctx and ctx_jpg else None
            if is_macro:
                # v11.12: ONE call — step photos (boxed) first, the zoomed crop
                # last, the level prompt alone.
                firsts = [data_url(j) for j in step_jpgs] if with_ctx else []
                if with_ctx and not firsts and ctx_jpg:
                    firsts = [data_url(ctx_jpg)]
                mt = mode_text
                if firsts and level != "microscope":
                    mt = f"{mt} {P.MACRO_CONTEXT_LINE}"  # v11.40 wider context photos
                mt = f"{mt} {color_text}".strip() if color_text else mt
                # v11.30: Extreme / Ultra send NO photo — text prompt from the
                # detected spot only (aspect still follows the crop).
                img = None if deep_text_only else data_url(main_jpg)
                return build_payload(mt, quality, aspect, img, None, leading_urls=firsts)
            if zsrc and with_ctx:
                # v11.59: the sharp source FIRST (content), the final zoom after it (framing).
                return build_payload(P.zoom_source_prompt(filt, color_text), quality, aspect,
                                     data_url(main_jpg), None,
                                     extra_urls=[data_url(framing_jpg)])
            if zsrc:
                # one-image fallback: the sharp source alone, the safe zoom prompt.
                return build_payload(P.zoom_ladder_prompt(filt, color_text, refs=False), quality,
                                     aspect, data_url(main_jpg), None)
            if ladder and with_ctx:
                # v11.31: the final photo FIRST, reference crops after it.
                return build_payload(P.zoom_ladder_prompt(filt, color_text), quality, aspect,
                                     data_url(main_jpg), None,
                                     extra_urls=[data_url(j) for j in step_jpgs_ladder])
            if zoom_only or ladder:
                # v11.34: final photo only, the zoom clean-up prompt.
                return build_payload(P.zoom_ladder_prompt(filt, color_text, refs=False), quality,
                                     aspect, data_url(main_jpg), None)
            prompt = P.build_prompt(
                has_context=with_ctx, zoom=zoom, optical_limit=optical_limit, tier=quality,
                style_prompt=filt, mode_prompt=mode_text, color_prompt=color_text,
                context_boxed=context_boxed, portrait_prompt=portrait_text,
            )
            return build_payload(prompt, quality, aspect, data_url(main_jpg), ctx_url)

        with_ctx = (ctx_jpg is not None or bool(step_jpgs) or bool(step_jpgs_ladder)
                    or framing_jpg is not None)
        try:
            status, body = await call_openrouter(payload(with_ctx))
            if with_ctx and status != 200 and is_multi_image_rejection(status):
                log.warning("2-image input rejected (HTTP %s): %s — retrying crop only", status, str(body)[:300])
                with_ctx = False
                status, body = await call_openrouter(payload(False))
        except httpx.TimeoutException as e:
            raise ai_failure(504, "timeout", f"upstream timeout after {UPSTREAM_TIMEOUT:g}s") from e
        except httpx.HTTPError as e:
            raise ai_failure(502, "upstream", f"upstream request failed: {e}") from e
        if status != 200 or not isinstance(body, dict):
            raise upstream_failure(status, body)
        try:
            out = await extract_image(body)
        except Exception as e:
            raise upstream_failure(200, body) from e
        # v11 Pro Night guard (2): reject results whose structure changed
        # (new / moved objects) — nothing charged, the app offers Retry.
        similarity = None
        if is_night:
            try:
                ok, similarity = G.structure_ok(main_jpg, out)
            except Exception as e:
                raise ai_failure(502, "upstream", f"bad upstream image: {e}") from e
            if not ok:
                log.warning("night result rejected: structure %.3f < %.2f (%s)", similarity,
                            G.STRUCTURE_MIN, dev)
                raise HTTPException(status_code=422, detail={
                    "reason": "structure_changed",
                    "message": "AI changed the scene, so the result was rejected. No credits used.",
                    "similarity": round(similarity, 3)})
        if ladder and with_ctx:
            # v11.31 free framing check: the model copied a reference's wide
            # framing → reject before charging (nothing used).
            try:
                ok, similarity = G.framing_ok(main_jpg, out)
            except Exception as e:
                raise ai_failure(502, "upstream", f"bad upstream image: {e}") from e
            if not ok:
                log.warning("zoom result rejected: framing %.3f < %.2f (%s)", similarity,
                            G.FRAMING_MIN, dev)
                raise HTTPException(status_code=422, detail={
                    "reason": "framing_changed",
                    "message": "Couldn't enhance this zoom — credit refunded",
                    "similarity": round(similarity, 3)})
        if zsrc or zoom_only:
            # v11.59: every zoom result is checked against its SOURCE area (the
            # sharp source when sent, else the final zoom) — changed → rejected.
            try:
                ok, similarity = G.zoom_output_ok(main_jpg, out,
                                                  check_colour=not filt and not color_text)
            except Exception as e:
                raise ai_failure(502, "upstream", f"bad upstream image: {e}") from e
            if not ok:
                log.warning("zoom result rejected: output check %.3f (%s)", similarity, dev)
                raise HTTPException(status_code=422, detail={
                    "reason": "structure_changed",
                    "message": "AI changed the scene, so the result was rejected. No credits used.",
                    "similarity": round(similarity, 3)})
        if is_macro and not color_text and level not in P.MACRO_DEEP_LEVELS and not deep_text_only:
            # v11.5: colours follow the real source crop (e.g. leaf hue).
            try:
                out = CM.match_colors(out, main_jpg)
            except Exception as e:
                log.warning("macro colour match skipped: %s", e)
        # v11.58: the AI image is delivered at its native size (no 1920 /
        # tier upscale, no re-encode).

        # The phone gave up (Cancel / its own timeout) → don't charge.
        if request is not None and await request.is_disconnected():
            log.info("client disconnected before result — not charged (%s)", dev)
            raise ai_failure(499, "cancelled", "client disconnected")

        # Success → charge now (atomic re-decide inside the ledger).
        cost = (body.get("usage") or {}).get("cost")
        state, charged = led.commit(dev, spec, now_utc(),
                                    note=f"{quality} z{zoom:g} {mode}"
                                         f"{' ' + color_filter if color_filter else ''} cost={cost}")

    media = "image/png" if out[:4] == b"\x89PNG" else "image/jpeg"
    headers = {
        "X-Enhance-Model": MODEL,
        "X-Enhance-Aspect": aspect,
        "X-Credits-Charged": str(charged.credits),
        "X-Trials-Used": ",".join(charged.trials),
        "X-Context-Used": "1" if with_ctx else "0",
        "X-Night": "1" if is_night else "0",
        "X-Mode": mode,
        "X-Account": L.state_header(state),
    }
    if level is not None:
        headers["X-Macro-Level"] = level
    if cost is not None:
        headers["X-Enhance-Cost"] = str(cost)
    if similarity is not None:
        headers["X-Structure"] = f"{similarity:.3f}"
    return Response(content=out, media_type=media, headers=headers)


# --------------------------------------------------------------------------
# AI style library (v9)
# --------------------------------------------------------------------------
LOOK_TIER = "full_hd"  # library styles render at Full HD params (medium, 1.5K)


@app.get("/v1/styles")
async def list_styles():
    """Public catalogue. Never includes prompts or reference images."""
    st = get_styles()
    return {"version": st.version(), "styles": [s.public_json() for s in st.list(media_type="photo")]}


@app.get("/media/styles/{name}")
async def style_media(name: str):
    raw = get_styles().read_file(name)
    if raw is None:
        raise HTTPException(status_code=404, detail="not found")
    return Response(raw, media_type="image/jpeg", headers={"Cache-Control": "public, max-age=86400"})


@app.get("/v1/poses")
async def list_poses():
    """v11 Pose-mode photo library (free, no credits)."""
    st = get_poses()
    return {"version": st.version(), "poses": [p.public_json() for p in st.list()]}


@app.get("/media/poses/{name}")
async def pose_media(name: str):
    raw = get_poses().read_file(name)
    if raw is None:
        raise HTTPException(status_code=404, detail="not found")
    return Response(raw, media_type="image/jpeg", headers={"Cache-Control": "public, max-age=86400"})


@app.post("/v1/looks/apply")
async def apply_look(
    request: Request,
    device_id: str = Form(...),
    image: UploadFile = File(...),
    style_id: Optional[str] = Form(None),
    custom_prompt: Optional[str] = Form(None),
    quality: str = Form("full_hd"),
    variations: int = Form(1),
):
    """Style apply (by id; prompt + references composed here) or a custom
    "Describe a change…" edit. Charged only for images actually returned."""
    dev = _check_device(device_id)
    raw = await image.read()
    if not raw or len(raw) > MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=400, detail="empty or too large image")
    if variations not in (1, 2, 3, 4):
        raise HTTPException(status_code=400, detail="variations must be 1..4")
    custom = P.sanitize_custom_prompt(custom_prompt)
    if not style_id and custom and P.blocked_custom_prompt(custom):
        raise HTTPException(status_code=400, detail={"reason": "blocked"})
    # v10: "enhance / HD / sharp" only → enhance happens at capture (Pro AI);
    # no AI call, nothing charged (app shows the same tip).
    if not style_id and custom and P.enhance_only_custom_prompt(custom):
        raise HTTPException(status_code=400, detail={"reason": "enhance_only"})
    style = None
    if style_id:
        style = get_styles().get(style_id)
        if style is None or not style.enabled or style.media_type != "photo":
            raise HTTPException(status_code=404, detail="style not found")
        tier = LOOK_TIER
        spec = L.LookSpec(credit_cost=style.credit_cost, variations=variations, pro_only=style.pro_only,
                          allow_trial=style.free_trial)
    elif custom:
        if quality not in L.TIERS:
            raise HTTPException(status_code=400, detail="unknown quality")
        tier = look_tier(quality)
        spec = L.LookSpec(credit_cost=L.TIERS[tier][1], variations=variations, is_style=False)
    else:
        raise HTTPException(status_code=400, detail="style_id or custom_prompt required")

    lock = _device_locks.setdefault(dev, asyncio.Lock())
    async with lock:
        led = get_ledger()
        d = led.decide(dev, spec, now_utc())
        if not d.allowed:
            raise HTTPException(status_code=402, detail={"reason": d.reason})
        try:
            main_jpg, w, h = prepare(raw, LOOK_INPUT_LONG)
        except Exception as e:
            raise HTTPException(status_code=400, detail=f"bad image: {e}") from e
        style_model = style_model_for(style)
        ref_urls = []
        # v11.58: Klein / Runware get only the user's photo (no references).
        for f in (style.ref_images if style and style_model == "custom" else []):
            b = get_styles().read_file(f, private=True)
            if b:
                ref_urls.append(data_url(prepare(b, 1024)[0]))
        prompt = P.build_look_prompt(style_prompt=style.prompt if style else None,
                                     custom_prompt=None if style else custom,
                                     has_references=bool(ref_urls))
        aspect = aspect_for(w, h)

        def look_payload(n: int) -> dict:
            p = build_payload(prompt, tier, aspect, data_url(main_jpg), None, ref_urls, n=n)
            p["quality"] = look_quality(tier)
            return p

        images: list[bytes] = []
        total_cost = 0.0
        failure: Optional[HTTPException] = None

        async def styled_call() -> list[bytes]:
            """v11.58 Klein (OpenRouter) or FLUX.2 Klein 4B (Runware)."""
            nonlocal total_cost, failure
            try:
                if style_model == "klein":
                    status, body = await call_openrouter(klein_payload(prompt, aspect, data_url(main_jpg)))
                else:
                    status, body = await call_runware(runware_payload(prompt, data_url(main_jpg), w, h))
            except httpx.TimeoutException:
                failure = ai_failure(504, "timeout", f"upstream timeout after {UPSTREAM_TIMEOUT:g}s")
                return []
            except httpx.HTTPError as e:
                failure = ai_failure(502, "upstream", f"upstream request failed: {e}")
                return []
            if status != 200 or not isinstance(body, dict):
                failure = upstream_failure(status, body)
                return []
            try:
                if style_model == "klein":
                    total_cost += float((body.get("usage") or {}).get("cost") or 0)
                    got = await extract_images(body)
                else:
                    got, c = await runware_images(body)
                    total_cost += c
            except Exception as e:  # noqa: BLE001
                failure = ai_failure(502, "no_image", f"bad image payload: {e}")
                return []
            if not got:
                failure = upstream_failure(200, body)
            return got[:1]

        async def one_call(n: int) -> list[bytes]:
            nonlocal total_cost, failure
            try:
                status, body = await call_openrouter(look_payload(n))
            except httpx.TimeoutException:
                failure = ai_failure(504, "timeout", f"upstream timeout after {UPSTREAM_TIMEOUT:g}s")
                return []
            except httpx.HTTPError as e:
                failure = ai_failure(502, "upstream", f"upstream request failed: {e}")
                return []
            if status != 200 or not isinstance(body, dict):
                failure = upstream_failure(status, body)
                return []
            total_cost += float((body.get("usage") or {}).get("cost") or 0)
            got = await extract_images(body)
            if not got:
                failure = upstream_failure(200, body)
            return got

        used_model = MODEL
        if style_model in ("klein", "runware_klein4b"):
            images = await styled_call()
            if images and variations > 1:  # Klein returns one image per call
                for extra in await asyncio.gather(*[styled_call() for _ in range(variations - 1)]):
                    images += extra[:1]
            if images:
                used_model = KLEIN_MODEL if style_model == "klein" else RUNWARE_KLEIN4B_MODEL
            else:  # v11.58: the style's model failed → fall back to Custom (Flare)
                log.info("style %s: %s failed (%s) — falling back to Custom", style.id, style_model,
                         getattr(failure, "detail", failure))
                failure = None
                images = await one_call(variations)
        else:
            images = await one_call(variations)
        # Providers that return fewer than n → top up with single calls IN
        # PARALLEL (only when variations > 1; a single look is one request).
        missing = variations - len(images)
        if images and missing > 0:
            for extra in await asyncio.gather(*[one_call(1) for _ in range(missing)]):
                images += extra[:1]
        images = images[:variations]
        if not images:
            raise failure or ai_failure(502, "no_image", "no image returned")
        # Looks are delivered at the model's native size (no upscale).

        # The phone gave up (Cancel / its own timeout) → don't charge.
        if request is not None and await request.is_disconnected():
            log.info("client disconnected before look result — not charged (%s)", dev)
            raise ai_failure(499, "cancelled", "client disconnected")

        got = len(images)
        charge_spec = L.LookSpec(credit_cost=spec.credit_cost, variations=got, pro_only=spec.pro_only,
                                 is_style=spec.is_style, allow_trial=spec.allow_trial and variations == 1)
        what = f"style:{style.id}" if style else "custom"
        state, charged = led.commit(dev, charge_spec, now_utc(),
                                    note=f"{what} x{got}/{variations} cost={total_cost:.4f}")
        if not charged.allowed:  # balance changed mid-flight (should not happen under lock)
            raise HTTPException(status_code=402, detail={"reason": charged.reason})

    return JSONResponse({
        "images": [base64.b64encode(x).decode("ascii") for x in images],
        "mime": ["image/png" if x[:4] == b"\x89PNG" else "image/jpeg" for x in images],
        "credits_charged": charged.credits,
        "trials_used": list(charged.trials),
        "account": L.state_header(state),
        "cost": total_cost,
        "model": used_model,
        "style_id": style.id if style else None,
        "references_used": len(ref_urls),
    })


# ---------------------------------------------------------------------------
# v11.53 video: 8scale Wan 2.2 14B (≤5 s) / Phosor MiniMax H3 Turbo (>5 s).
# Keys stay on the server. Credits (provisional, VIDEO_CREDITS_JSON) are
# checked at submit and charged ONCE, only when the finished video is first
# reported done (failed / cancelled / abandoned jobs are never charged).
# ---------------------------------------------------------------------------
VIDEO_PER_DEVICE_PER_HOUR = int(os.environ.get("VIDEO_PER_DEVICE_PER_HOUR", "10"))
_video_hits: dict = {}
_video_transport = None  # tests inject an httpx.MockTransport


def _video_rate_ok(dev: str) -> bool:
    import time as _t
    now = _t.time()
    hits = [t for t in _video_hits.get(dev, []) if now - t < 3600]
    ok = len(hits) < VIDEO_PER_DEVICE_PER_HOUR
    if ok:
        hits.append(now)
    _video_hits[dev] = hits
    return ok


def _video_http(e: "VP.VideoError") -> HTTPException:
    return HTTPException(status_code=e.status, detail=str(e))


def _video_look_spec(credits: int) -> "L.LookSpec":
    return L.LookSpec(credit_cost=credits, is_style=False, allow_trial=False)


def _video_override() -> dict:
    try:
        ov = json.loads(get_mode_prompts().get_config("video_credits") or "{}")
        return ov if isinstance(ov, dict) else {}
    except Exception:  # noqa: BLE001
        return {}


@app.get("/v1/video/styles")
async def video_styles():
    st = get_styles()
    return {"styles": [{**s.public_json(), "media_type": "video",
                        "credits": VP.credit_table(_video_override())}
                       for s in st.list(media_type="video")]}


@app.get("/v1/video/options")
async def video_options():
    return {"credits": VP.credit_table(_video_override()), "minimax_enabled": VP.minimax_enabled(),
            "wan": {"seconds": list(VP.WAN_SECONDS), "resolutions": list(VP.WAN_RES),
                    "aspect_ratios": list(VP.WAN_ASPECTS)},
            "minimax": {"seconds": list(VP.MM_SECONDS), "resolutions": list(VP.MM_RES),
                        "aspect_ratios": list(VP.MM_ASPECTS), "label": "MiniMax H3"}}


@app.post("/v1/video/generate")
async def video_generate(
    device_id: str = Form(...), prompt: str = Form(...), kind: str = Form("i2v"),
    seconds: int = Form(5), resolution: str = Form("480p"), aspect_ratio: str = Form("9:16"),
    style_id: Optional[str] = Form(None), image: Optional[UploadFile] = File(None),
):
    dev = _check_device(device_id)
    text = prompt
    if style_id:
        st = get_styles().get(style_id)
        if st is None or not st.enabled or st.media_type != "video":
            raise HTTPException(status_code=404, detail="video style not found")
        text = st.prompt
        kind, seconds, aspect_ratio = "i2v", 5, "9:16"  # presets: I2V · 9:16 · 5 s (Wan)
    elif P.blocked_custom_prompt(prompt):
        raise HTTPException(status_code=400, detail="Blocked by the safety list")
    try:
        spec = VP.route(kind, text, seconds, resolution, aspect_ratio)
    except VP.VideoError as e:
        raise _video_http(e) from e
    if not VP.configured(spec.provider):
        raise HTTPException(status_code=503, detail="video generation is not configured")
    credits_ = spec.credits(_video_override())
    led = get_ledger()
    d = led.decide(dev, _video_look_spec(credits_), now_utc())
    if not d.allowed:
        raise HTTPException(status_code=402, detail=d.reason or "not enough credits")
    raw = None
    if spec.kind == "i2v":
        if image is None:
            raise HTTPException(status_code=422, detail="image is required for image-to-video")
        raw = await image.read()
        if not raw or len(raw) > MAX_UPLOAD_BYTES:
            raise HTTPException(status_code=413, detail="image too large or empty")
    if not _video_rate_ok(dev):
        raise HTTPException(status_code=429, detail="too many videos, try again later")
    try:
        rid = await VP.submit(spec, raw, image.content_type if image else "image/jpeg",
                              transport=_video_transport)
    except VP.VideoError as e:
        raise _video_http(e) from e
    log.info("video submit %s %s %ss %s", dev[:6], spec.provider, spec.seconds, spec.resolution)
    get_video_log().add({"job_key": f"{spec.provider}:{rid}", "device_id": dev, "provider": spec.provider,
                         "kind": spec.kind, "seconds": spec.seconds, "resolution": spec.resolution,
                         "aspect_ratio": spec.aspect_ratio, "style_id": style_id, "credits": credits_,
                         "cost_inr": VP.cost_inr(spec.provider, spec.seconds, spec.resolution),
                         "status": "queued", "charged": 0})
    return {"job_id": VP.make_job_id(dev, spec.provider, rid, credits_),
            "status": "queued", "provider": spec.provider, "model_label": spec.model_label,
            "seconds": spec.seconds, "resolution": spec.resolution, "aspect_ratio": spec.aspect_ratio,
            "credits": credits_}


@app.get("/v1/video/status/{job_id}")
async def video_status(job_id: str, device_id: str):
    dev = _check_device(device_id)
    try:
        provider, rid, credits = VP.parse_job_id(dev, job_id)
        st = await VP.status(provider, rid, transport=_video_transport)
    except VP.VideoError as e:
        raise _video_http(e) from e
    out = {"job_id": job_id, "provider": provider,
           "model_label": "Wan 2.2" if provider == VP.WAN else "MiniMax H3", **st}
    if st["status"] == "done":
        state, d, fresh = get_ledger().commit_once(dev, f"video:{provider}:{rid}",
                                                   _video_look_spec(credits), now_utc())
        out["credits_charged"] = d.credits if fresh else 0
        out["account"] = _account_json(dev, state, now_utc())
        if fresh:
            get_video_log().update(f"{provider}:{rid}", status="done", charged=d.credits)
    elif st["status"] == "failed":
        get_video_log().update(f"{provider}:{rid}", status="failed", error=st.get("error", "")[:300])
    return out


@app.post("/v1/video/cancel/{job_id}")
async def video_cancel(job_id: str, device_id: str = Form(...)):
    dev = _check_device(device_id)
    try:
        provider, rid, _ = VP.parse_job_id(dev, job_id)
    except VP.VideoError as e:
        raise _video_http(e) from e
    ok = await VP.cancel(provider, rid, transport=_video_transport)
    get_video_log().update(f"{provider}:{rid}", status="cancelled")
    return {"job_id": job_id, "cancelled_at_provider": ok, "credits_charged": 0}




@app.post("/enhance")
async def enhance_legacy(photo: UploadFile = File(...), style: Optional[str] = Form(None)):
    """v6 endpoint (no credits). Disabled by default so the key can't be used
    for free once the server is public."""
    if not _flag("ENABLE_LEGACY_ENHANCE"):
        raise HTTPException(status_code=410, detail="legacy /enhance disabled; use /v1/enhance")
    raw = await photo.read()
    if not raw:
        raise HTTPException(status_code=400, detail="empty photo")
    jpg, w, h = prepare(raw, 2048)
    prompt = P.build_prompt(style_prompt=P.FILTER_PROMPTS.get((style or "").lower()))
    status, body = await call_openrouter(build_payload(prompt, "hd", aspect_for(w, h), data_url(jpg), None))
    if status != 200 or not isinstance(body, dict):
        raise HTTPException(status_code=502, detail=f"OpenRouter {status}: {str(body)[:500]}")
    return Response(content=await extract_image(body), media_type="image/png")


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("main:app", host="0.0.0.0", port=int(os.environ.get("PORT", "8787")), reload=False)
