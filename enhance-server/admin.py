"""Password-protected admin panel: AI style library (/admin), the free
Pose-mode photo library (/admin/poses, v11 real photos) and the hidden Pro AI
prompts (/admin/prompts, v11: portrait / night / macro / color filters).

* ADMIN_PASSWORD env enables it (unset → /admin returns 503).
* Login form → signed, HttpOnly, SameSite=Strict session cookie (12 h).
  Changing ADMIN_PASSWORD invalidates all sessions.
* Simple brute-force throttle: 5 failed logins per IP per 10 minutes.
* Pages are plain server-rendered HTML (no JS framework, works on a phone).
"""
from __future__ import annotations

import hashlib
import hmac
import html
import json
import os
import re
import time
from typing import Callable, Optional

from fastapi import APIRouter, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import HTMLResponse, RedirectResponse, Response

import prompts as P
from mode_prompts import ModePromptStore
from poses import CATEGORIES as POSE_CATEGORIES, Pose, PoseStore, clean_source_url
from styles import (MAX_REFERENCES, STYLE_MODELS, Style, StyleStore, normalize_style_model, normalize_ui_category,
                    ui_categories_for)

COOKIE = "admin_session"
SESSION_SECONDS = 12 * 3600
MAX_FAILS = 5
FAIL_WINDOW = 600
_fails: dict[str, list[float]] = {}


def admin_password() -> str:
    return os.environ.get("ADMIN_PASSWORD", "")


def _key() -> bytes:
    return hashlib.sha256(b"ai-camera-admin:" + admin_password().encode()).digest()


def make_session(now: Optional[float] = None) -> str:
    exp = str(int((now or time.time()) + SESSION_SECONDS))
    sig = hmac.new(_key(), exp.encode(), hashlib.sha256).hexdigest()
    return f"{exp}.{sig}"


def session_ok(value: Optional[str]) -> bool:
    if not admin_password() or not value or "." not in value:
        return False
    exp, sig = value.split(".", 1)
    good = hmac.new(_key(), exp.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sig, good):
        return False
    try:
        return int(exp) > time.time()
    except ValueError:
        return False


def _esc(v) -> str:
    return html.escape("" if v is None else str(v), quote=True)


CSS = """
body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;margin:0;background:#101218;color:#eceff4}
header{display:flex;justify-content:space-between;align-items:center;padding:14px 18px;background:#181b24}
a{color:#8ab4ff} h1{font-size:19px;margin:0} main{padding:16px;max-width:1000px;margin:auto}
table{width:100%;border-collapse:collapse} td,th{padding:8px;border-bottom:1px solid #2a2f3c;text-align:left;vertical-align:middle}
img.t{width:56px;height:74px;object-fit:cover;border-radius:8px;background:#222}
.btn{display:inline-block;padding:7px 12px;border-radius:8px;border:0;background:#3a6ff7;color:#fff;cursor:pointer;text-decoration:none;font-size:14px}
.btn.s{background:#2a2f3c}.btn.d{background:#b3261e}
form.i{display:inline} label{display:block;margin:12px 0 4px;font-weight:600}
input[type=text],input[type=number],input[type=password],textarea{width:100%;box-sizing:border-box;padding:9px;border-radius:8px;border:1px solid #3a4050;background:#0c0e13;color:#eceff4;font-size:15px}
textarea{min-height:140px} .muted{color:#9aa3b5;font-size:13px} .off{opacity:.45} .pill{font-size:12px;padding:2px 7px;border-radius:9px;background:#2a2f3c}
.tabs{display:flex;gap:6px;margin:0 0 14px;border-bottom:1px solid #2a2f3c}
.tab{padding:9px 16px;border-radius:8px 8px 0 0;background:#181b24;color:#eceff4;text-decoration:none}
.tab.on{background:#3a6ff7}.tab.dis{opacity:.45;cursor:not-allowed}
.soon{padding:40px;text-align:center;border:1px dashed #3a4050;border-radius:12px;color:#9aa3b5}
.refs img{width:70px;height:70px;object-fit:cover;border-radius:6px;margin-right:6px}
"""


def page(title: str, body: str, logged_in: bool = True) -> HTMLResponse:
    out = f"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>{_esc(title)}</title>
<style>{CSS}</style></head><body><header><h1>AI Camera · Admin</h1>
{'<nav><a href="/admin">Photo Styles</a> · <a href="/admin/poses">Poses</a> · <a href="/admin/prompts">Prompts</a> · <a href="/admin/macro-credits">Macro credits</a> <form class="i" method="post" action="/admin/logout"><button class="btn s">Log out</button></form></nav>' if logged_in else ''}
</header><main>{body}</main></body></html>"""
    return HTMLResponse(out, headers={"Cache-Control": "no-store", "X-Frame-Options": "DENY"})


def guard(request: Request) -> Optional[Response]:
    if not admin_password():
        raise HTTPException(status_code=503, detail="admin disabled: set ADMIN_PASSWORD")
    if not session_ok(request.cookies.get(COOKIE)):
        return RedirectResponse("/admin/login", status_code=303)
    return None


async def apply_samples(store, s: Style, uploads: dict, remove: tuple = ()) -> None:
    """v11.56: upload / replace / remove the before/after sample images.
    Video styles keep only an AFTER sample."""
    for field in remove:
        store.remove_sample(getattr(s, field))
        setattr(s, field, None)
    for field, up in uploads.items():
        if field == "sample_before_url" and s.media_type == "video":
            continue
        if up is None or not getattr(up, "filename", None):
            continue
        raw = await up.read()
        if not raw:
            continue
        try:
            url = store.save_sample(raw)
        except Exception as e:
            raise HTTPException(status_code=400, detail=f"bad sample image: {e}") from e
        store.remove_sample(getattr(s, field))
        setattr(s, field, url)


def build_router(get_store: Callable[[], StyleStore]) -> APIRouter:
    r = APIRouter()

    @r.get("/admin/login")
    async def login_form(error: str = ""):
        if not admin_password():
            raise HTTPException(status_code=503, detail="admin disabled: set ADMIN_PASSWORD")
        msg = f'<p style="color:#ff8a80">{_esc(error)}</p>' if error else ""
        return page("Login", f"""{msg}<form method="post" action="/admin/login" style="max-width:360px">
<label>Password</label><input type="password" name="password" autofocus>
<p><button class="btn">Log in</button></p></form>""", logged_in=False)

    @r.post("/admin/login")
    async def login(request: Request, password: str = Form("")):
        if not admin_password():
            raise HTTPException(status_code=503, detail="admin disabled: set ADMIN_PASSWORD")
        ip = request.client.host if request.client else "?"
        now = time.time()
        fails = [t for t in _fails.get(ip, []) if now - t < FAIL_WINDOW]
        if len(fails) >= MAX_FAILS:
            raise HTTPException(status_code=429, detail="too many attempts, try later")
        if not hmac.compare_digest(password.encode(), admin_password().encode()):
            _fails[ip] = fails + [now]
            return RedirectResponse("/admin/login?error=Wrong+password", status_code=303)
        _fails.pop(ip, None)
        resp = RedirectResponse("/admin", status_code=303)
        resp.set_cookie(COOKIE, make_session(), max_age=SESSION_SECONDS, httponly=True,
                        samesite="strict", secure=request.url.scheme == "https", path="/admin")
        return resp

    @r.post("/admin/logout")
    async def logout():
        resp = RedirectResponse("/admin/login", status_code=303)
        resp.delete_cookie(COOKIE, path="/admin")
        return resp

    @r.get("/admin")
    async def index(request: Request, tab: str = "photo"):
        if (g := guard(request)) is not None:
            return g
        tabs = ('<div class="tabs"><a class="tab {p}" href="/admin">Photo</a>'
                '<a class="tab {v}" href="/admin?tab=video">Video</a>'
                '<a class="tab" href="/admin/video/credits">Video credits</a>'
                '<a class="tab" href="/admin/video/history">Video history</a></div>')
        media = "video" if tab == "video" else "photo"
        rows = []
        for s in get_store().list(include_disabled=True, media_type=media):
            img = f'<img class="t" src="/media/styles/{_esc(s.display_image)}">' if s.display_image else '<div class="t"></div>'
            rows.append(f"""<tr class="{'' if s.enabled else 'off'}"><td>{img}</td>
<td><b>{_esc(s.name)}</b><div class="muted">{_esc(s.id)} · {_esc(s.category)} · app: {_esc(normalize_ui_category(s.ui_category, s.media_type))}{'' if s.media_type == 'video' else ' · model: ' + _esc(normalize_style_model(s.model))}</div></td>
<td>⚡{s.credit_cost}</td>
<td>{'<span class="pill">Pro only</span>' if s.pro_only else ''} {'' if s.enabled else '<span class="pill">disabled</span>'}
{f'<span class="pill">{len(s.ref_images)} ref</span>' if s.ref_images else ''}
{'' if s.free_trial else '<span class="pill">no free trial</span>'}
{'<span class="pill">camera filter</span>' if s.kind == 'filter' else ''}</td>
<td><form class="i" method="post" action="/admin/styles/{_esc(s.id)}/toggle"><button class="btn s">{'Disable' if s.enabled else 'Enable'}</button></form></td>
<td style="white-space:nowrap">
<form class="i" method="post" action="/admin/styles/{_esc(s.id)}/move"><input type="hidden" name="direction" value="-1"><button class="btn s" title="Up">↑</button></form>
<form class="i" method="post" action="/admin/styles/{_esc(s.id)}/move"><input type="hidden" name="direction" value="1"><button class="btn s" title="Down">↓</button></form>
<a class="btn" href="/admin/styles/{_esc(s.id)}/edit">Edit</a>
<form class="i" method="post" action="/admin/styles/{_esc(s.id)}/delete" onsubmit="return confirm('Delete {_esc(s.name)}?')"><button class="btn d">Delete</button></form>
</td></tr>""")
        add = ('<a class="btn" href="/admin/styles/new?media=video">+ Add video style</a>'
               '<span class="muted"> Video presets: image-to-video, 9:16, 5 s (Phosor MiniMax H3 Turbo). Display image = preview.</span>'
               if media == "video" else
               '<a class="btn" href="/admin/styles/new">+ Add photo style</a>'
               '<span class="muted"> Styles are listed in the app in this order. Prompts and reference images stay on the server.</span>')
        body = tabs.format(p="" if media == "video" else "on", v="on" if media == "video" else "") + f"""<p>{add}</p>
<table><tr><th></th><th>Style</th><th>Cost</th><th>Flags</th><th>Status</th><th></th></tr>{''.join(rows)}</table>"""
        return page("Video styles" if media == "video" else "Photo styles", body)

    def form_html(s: Optional[Style], action: str) -> str:
        s = s or Style(id="", name="", category="Travel", prompt="", credit_cost=2)
        refs = "".join(
            f'<label style="display:inline-block;margin-right:10px;font-weight:400">'
            f'<img src="/admin/ref/{_esc(f)}"><br><input type="checkbox" name="remove_refs" value="{_esc(f)}"> remove</label>'
            for f in s.ref_images)
        cats = sorted({x.category for x in get_store().list(include_disabled=True)} | {"Travel", "Outfit", "Festival", "Portrait", "Mood"})
        opts = "".join(f'<option value="{_esc(c)}">' for c in cats)
        disp = f'<img class="t" src="/media/styles/{_esc(s.display_image)}"> ' if s.display_image else ""
        cur = normalize_ui_category(s.ui_category, s.media_type)
        ui_opts = "".join(f'<option value="{k}" {"selected" if k == cur else ""}>{_esc(lbl)}</option>'
                          for k, lbl in ui_categories_for(s.media_type))
        cur_model = normalize_style_model(s.model)
        model_opts = "".join(f'<option value="{k}" {"selected" if k == cur_model else ""}>{_esc(lbl)}</option>'
                             for k, lbl in STYLE_MODELS)
        model_html = "" if s.media_type == "video" else (
            '<label>Model (which AI renders this style)</label><select name="model" '
            f'style="padding:9px;border-radius:8px;background:#0c0e13;color:#eceff4">{model_opts}</select>'
            '<div class="muted">FLUX Klein gets only the user\'s photo (no reference images). Use Runware '
            'FLUX.2 Klein 4B for violent / bloody looks. If the chosen model fails or is not set up, the '
            'style falls back to the Custom model.</div>')
        def _sample(field: str, label: str, url: Optional[str]) -> str:
            cur_img = (f'<img class="t" src="{_esc(url)}"> <label style="display:inline;font-weight:400">'
                       f'<input type="checkbox" name="remove_{field}" value="1"> remove</label><br>') if url else ""
            return f'<label>{label}</label>{cur_img}<input type="file" name="{field}" accept="image/*">'
        sample_html = ""
        if s.media_type != "video":
            sample_html += _sample("sample_before", "Sample BEFORE image (9:16, shown in the app's before/after slider)",
                                   s.sample_before_url)
        sample_html += _sample("sample_after", "Sample AFTER image (9:16; the app's card thumbnail" +
                               (")" if s.media_type == "video" else " + slider)"), s.sample_after_url)
        return f"""<form method="post" action="{action}" enctype="multipart/form-data" style="max-width:640px">
<input type="hidden" name="media_type" value="{_esc(s.media_type)}">
<label>Name</label><input type="text" name="name" value="{_esc(s.name)}" required maxlength="40">
<label>Category</label><input type="text" name="category" value="{_esc(s.category)}" list="cats" required maxlength="30"><datalist id="cats">{opts}</datalist>
<label>App category (chip in the app's Styles sheet)</label><select name="ui_category" style="padding:9px;border-radius:8px;background:#0c0e13;color:#eceff4">{ui_opts}</select>
{model_html}
<label>Display / sample image</label>{disp}<input type="file" name="display_image" accept="image/*">
{sample_html}
<label>Reference images (optional, up to {MAX_REFERENCES}; sent to the AI with the user's photo)</label>
<div class="refs">{refs}</div><input type="file" name="ref_images" accept="image/*" multiple>
<label>Hidden prompt (never shown in the app)</label><textarea name="prompt" required maxlength="2000">{_esc(s.prompt)}</textarea>
<div class="muted">The server always wraps it with the identity-preserving instructions (same face, same person).</div>
<label>Credit cost (per image)</label><input type="number" name="credit_cost" min="0" max="100" value="{s.credit_cost}">
<label><input type="checkbox" name="pro_only" value="1" {'checked' if s.pro_only else ''}> Pro only</label>
<label><input type="checkbox" name="enabled" value="1" {'checked' if s.enabled else ''}> Enabled (visible in the app)</label>
<label><input type="checkbox" name="needs_person" value="1" {'checked' if s.needs_person else ''}> Needs a person in the photo (app warns "No person found" before spending credits)</label>
<label><input type="checkbox" name="free_trial" value="1" {'checked' if s.free_trial else ''}> Free first try (the one-time "library style" starter trial can make the first single image free)</label>
<label><input type="checkbox" name="as_filter" value="1" {'checked' if s.kind == 'filter' else ''}> Show as filter on camera (filter row above the shutter instead of the Styles library; display image = before/after preview)</label>
<label>Sort order</label><input type="number" name="sort_order" value="{s.sort_order}">
<p><button class="btn">Save</button> <a class="btn s" href="/admin">Cancel</a></p></form>"""

    @r.get("/admin/styles/new")
    async def new_form(request: Request, media: str = "photo"):
        if (g := guard(request)) is not None:
            return g
        s = Style(id="", name="", category="Video" if media == "video" else "Travel", prompt="",
                  sort_order=get_store().next_sort_order(), enabled=True,
                  media_type="video" if media == "video" else "photo", needs_person=media != "video")
        return page("New style", "<h2>New style</h2>" + form_html(s, "/admin/styles"))

    @r.get("/admin/styles/{sid}/edit")
    async def edit_form(request: Request, sid: str):
        if (g := guard(request)) is not None:
            return g
        s = get_store().get(sid)
        if s is None:
            raise HTTPException(status_code=404, detail="style not found")
        return page("Edit style", f"<h2>Edit · {_esc(s.name)}</h2>" + form_html(s, f"/admin/styles/{_esc(s.id)}"))

    async def _save(store: StyleStore, s: Style, display_image: Optional[UploadFile],
                    ref_images: list[UploadFile], remove_refs: list[str],
                    samples: Optional[dict] = None, remove_samples: tuple = ()) -> None:
        await apply_samples(store, s, samples or {}, remove_samples)
        if display_image is not None and display_image.filename:
            raw = await display_image.read()
            if raw:
                try:
                    new = store.save_image(raw)
                except Exception as e:
                    raise HTTPException(status_code=400, detail=f"bad display image: {e}") from e
                store.remove_file(s.display_image)
                s.display_image = new
        keep = [f for f in s.ref_images if f not in set(remove_refs)]
        for f in s.ref_images:
            if f not in keep:
                store.remove_file(f, private=True)
        for up in ref_images or []:
            if not up.filename or len(keep) >= MAX_REFERENCES:
                continue
            raw = await up.read()
            if raw:
                try:
                    keep.append(store.save_image(raw, private=True))
                except Exception as e:
                    raise HTTPException(status_code=400, detail=f"bad reference image: {e}") from e
        s.ref_images = keep
        store.upsert(s)

    @r.post("/admin/styles")
    async def create(
        request: Request,
        name: str = Form(...), category: str = Form(...), prompt: str = Form(...),
        credit_cost: int = Form(2), sort_order: int = Form(0),
        pro_only: Optional[str] = Form(None), enabled: Optional[str] = Form(None),
        needs_person: Optional[str] = Form(None), free_trial: Optional[str] = Form(None),
        as_filter: Optional[str] = Form(None), media_type: str = Form("photo"),
        ui_category: str = Form("new"), model: str = Form(""),
        display_image: Optional[UploadFile] = File(None),
        ref_images: list[UploadFile] = File(default=[]),
        sample_before: Optional[UploadFile] = File(None),
        sample_after: Optional[UploadFile] = File(None),
    ):
        if (g := guard(request)) is not None:
            return g
        store = get_store()
        s = Style(id=store.new_id(name), name=name.strip()[:40], category=category.strip()[:30],
                  prompt=prompt.strip()[:2000], credit_cost=credit_cost, pro_only=bool(pro_only),
                  enabled=bool(enabled), sort_order=sort_order, needs_person=bool(needs_person),
                  free_trial=bool(free_trial), kind="filter" if as_filter else "style",
                  media_type="video" if media_type == "video" else "photo")
        s.ui_category = normalize_ui_category(ui_category, s.media_type)
        s.model = normalize_style_model(model) if model else ("custom" if s.kind == "filter" else "klein")
        await _save(store, s, display_image, ref_images, [],
                    {"sample_before_url": sample_before, "sample_after_url": sample_after})
        return RedirectResponse("/admin?tab=video" if s.media_type == "video" else "/admin", status_code=303)

    @r.post("/admin/styles/{sid}")
    async def update(
        request: Request, sid: str,
        name: str = Form(...), category: str = Form(...), prompt: str = Form(...),
        credit_cost: int = Form(2), sort_order: int = Form(0),
        pro_only: Optional[str] = Form(None), enabled: Optional[str] = Form(None),
        needs_person: Optional[str] = Form(None), free_trial: Optional[str] = Form(None),
        as_filter: Optional[str] = Form(None), media_type: str = Form("photo"),
        ui_category: str = Form("new"), model: str = Form(""),
        display_image: Optional[UploadFile] = File(None),
        ref_images: list[UploadFile] = File(default=[]),
        remove_refs: list[str] = Form(default=[]),
        sample_before: Optional[UploadFile] = File(None),
        sample_after: Optional[UploadFile] = File(None),
        remove_sample_before: Optional[str] = Form(None),
        remove_sample_after: Optional[str] = Form(None),
    ):
        if (g := guard(request)) is not None:
            return g
        store = get_store()
        s = store.get(sid)
        if s is None:
            raise HTTPException(status_code=404, detail="style not found")
        s.name, s.category, s.prompt = name.strip()[:40], category.strip()[:30], prompt.strip()[:2000]
        s.credit_cost, s.sort_order = credit_cost, sort_order
        s.pro_only, s.enabled, s.needs_person = bool(pro_only), bool(enabled), bool(needs_person)
        s.free_trial = bool(free_trial)
        s.kind = "filter" if as_filter else "style"
        s.ui_category = normalize_ui_category(ui_category, s.media_type)
        if model:
            s.model = normalize_style_model(model)
        rm = tuple(k for k, v in (("sample_before_url", remove_sample_before),
                                  ("sample_after_url", remove_sample_after)) if v)
        await _save(store, s, display_image, ref_images, remove_refs,
                    {"sample_before_url": sample_before, "sample_after_url": sample_after}, rm)
        return RedirectResponse("/admin", status_code=303)

    @r.post("/admin/styles/{sid}/delete")
    async def delete(request: Request, sid: str):
        if (g := guard(request)) is not None:
            return g
        get_store().delete(sid)
        return RedirectResponse("/admin", status_code=303)

    @r.post("/admin/styles/{sid}/toggle")
    async def toggle(request: Request, sid: str):
        if (g := guard(request)) is not None:
            return g
        store = get_store()
        s = store.get(sid)
        if s is None:
            raise HTTPException(status_code=404, detail="style not found")
        s.enabled = not s.enabled
        store.upsert(s)
        return RedirectResponse("/admin", status_code=303)

    @r.post("/admin/styles/{sid}/move")
    async def move(request: Request, sid: str, direction: int = Form(...)):
        if (g := guard(request)) is not None:
            return g
        get_store().move(sid, direction)
        return RedirectResponse("/admin", status_code=303)

    @r.get("/admin/ref/{name}")
    async def ref_image(request: Request, name: str):
        """Reference images are private: only visible to a logged-in admin."""
        if (g := guard(request)) is not None:
            return g
        raw = get_store().read_file(name, private=True)
        if raw is None:
            raise HTTPException(status_code=404)
        return Response(raw, media_type="image/jpeg", headers={"Cache-Control": "no-store"})

    return r


# ---------------------------------------------------------------------------
# v11.1.29: token-protected JSON API for photo styles (assistants / CLI)
# ---------------------------------------------------------------------------
def admin_api_token() -> str:
    return os.environ.get("ADMIN_API_TOKEN", "")


def api_guard(request: Request) -> None:
    tok = admin_api_token()
    if not tok:
        raise HTTPException(status_code=503, detail="admin API disabled: set ADMIN_API_TOKEN")
    auth = request.headers.get("authorization", "")
    given = auth[7:].strip() if auth.lower().startswith("bearer ") else request.headers.get("x-admin-token", "")
    if not given or not hmac.compare_digest(given.encode(), tok.encode()):
        raise HTTPException(status_code=401, detail="bad or missing admin API token")


_API_FIELDS = {"name": str, "category": str, "prompt": str, "credit_cost": int, "pro_only": bool,
               "enabled": bool, "sort_order": int, "needs_person": bool, "free_trial": bool,
               "media_type": str, "kind": str, "ui_category": str, "model": str}


def _apply_fields(s: Style, data: dict) -> Style:
    for k, typ in _API_FIELDS.items():
        if k in data and data[k] is not None:
            try:
                setattr(s, k, typ(data[k]))
            except (TypeError, ValueError) as e:
                raise HTTPException(status_code=422, detail=f"bad field {k}") from e
    s.name, s.category, s.prompt = s.name.strip()[:40], s.category.strip()[:30], s.prompt.strip()[:2000]
    if s.media_type not in ("photo", "video"):
        raise HTTPException(status_code=422, detail="media_type must be photo or video")
    if s.kind not in ("style", "filter"):
        raise HTTPException(status_code=422, detail="kind must be style or filter")
    if not s.name or not s.category or not s.prompt:
        raise HTTPException(status_code=422, detail="name, category and prompt are required")
    s.ui_category = normalize_ui_category(s.ui_category, s.media_type)
    s.model = normalize_style_model(s.model)
    return s


def build_style_api_router(get_store: Callable[[], StyleStore]) -> APIRouter:
    """JSON API. Auth: `Authorization: Bearer $ADMIN_API_TOKEN` (or X-Admin-Token).

    GET    /admin/api/styles                 list (incl. disabled, with prompts)
    GET    /admin/api/styles/{id}
    POST   /admin/api/styles                 JSON body → create (id optional)
    PUT    /admin/api/styles/{id}            JSON body → partial update
    DELETE /admin/api/styles/{id}
    POST   /admin/api/styles/{id}/images     multipart: display_image, ref_images[],
                                             sample_before, sample_after (v11.56;
                                             remove_samples=1|sample_before|sample_after);
                                             form replace_refs=1 to drop old refs
    POST   /admin/api/styles/order           {"ids": [...]}
    """
    r = APIRouter()

    async def _body(request: Request) -> dict:
        try:
            data = await request.json()
        except Exception as e:
            raise HTTPException(status_code=400, detail="JSON body required") from e
        if not isinstance(data, dict):
            raise HTTPException(status_code=400, detail="JSON object required")
        return data

    def _get(sid: str) -> Style:
        s = get_store().get(sid)
        if s is None:
            raise HTTPException(status_code=404, detail="style not found")
        return s

    @r.get("/admin/api/styles")
    async def api_list(request: Request):
        api_guard(request)
        st = get_store()
        return {"version": st.version(), "styles": [s.admin_json() for s in st.list(include_disabled=True)]}

    @r.post("/admin/api/styles/order")
    async def api_order(request: Request):
        api_guard(request)
        ids = (await _body(request)).get("ids")
        if not isinstance(ids, list):
            raise HTTPException(status_code=422, detail="ids list required")
        get_store().set_order([str(x) for x in ids])
        return {"ok": True, "ids": [s.id for s in get_store().list(include_disabled=True)]}

    @r.get("/admin/api/styles/{sid}")
    async def api_get(request: Request, sid: str):
        api_guard(request)
        return _get(sid).admin_json()

    @r.post("/admin/api/styles", status_code=201)
    async def api_create(request: Request):
        api_guard(request)
        data = await _body(request)
        store = get_store()
        sid = str(data.get("id") or "").strip()
        if sid:
            if not re.fullmatch(r"[a-z0-9_]{1,40}", sid):
                raise HTTPException(status_code=422, detail="id must be [a-z0-9_]{1,40}")
            if store.get(sid) is not None:
                raise HTTPException(status_code=409, detail="style id already exists")
        s = Style(id="", name="", category="", prompt="", sort_order=store.next_sort_order())
        _apply_fields(s, data)
        s.id = sid or store.new_id(s.name)
        store.upsert(s)
        return store.get(s.id).admin_json()

    @r.put("/admin/api/styles/{sid}")
    async def api_update(request: Request, sid: str):
        api_guard(request)
        s = _apply_fields(_get(sid), await _body(request))
        get_store().upsert(s)
        return get_store().get(sid).admin_json()

    @r.delete("/admin/api/styles/{sid}")
    async def api_delete(request: Request, sid: str):
        api_guard(request)
        _get(sid)
        get_store().delete(sid)
        return {"ok": True, "deleted": sid}

    @r.post("/admin/api/styles/{sid}/images")
    async def api_images(request: Request, sid: str,
                         display_image: Optional[UploadFile] = File(None),
                         ref_images: list[UploadFile] = File(default=[]),
                         replace_refs: Optional[str] = Form(None),
                         sample_before: Optional[UploadFile] = File(None),
                         sample_after: Optional[UploadFile] = File(None),
                         remove_samples: Optional[str] = Form(None)):
        api_guard(request)
        store = get_store()
        s = _get(sid)
        rm = tuple(f for f in ("sample_before_url", "sample_after_url")
                   if remove_samples in ("1", "true", "yes", "all") or remove_samples == f.replace("_url", ""))
        await apply_samples(store, s, {"sample_before_url": sample_before, "sample_after_url": sample_after}, rm)
        if display_image is not None and display_image.filename:
            try:
                new = store.save_image(await display_image.read())
            except Exception as e:
                raise HTTPException(status_code=400, detail=f"bad display image: {e}") from e
            store.remove_file(s.display_image)
            s.display_image = new
        refs = list(s.ref_images)
        if replace_refs in ("1", "true", "yes"):
            for f in refs:
                store.remove_file(f, private=True)
            refs = []
        ups = [u for u in ref_images or [] if u.filename]
        if len(refs) + len(ups) > MAX_REFERENCES:
            raise HTTPException(status_code=422, detail=f"max {MAX_REFERENCES} reference images")
        for up in ups:
            try:
                refs.append(store.save_image(await up.read(), private=True))
            except Exception as e:
                raise HTTPException(status_code=400, detail=f"bad reference image: {e}") from e
        s.ref_images = refs
        store.upsert(s)
        return store.get(sid).admin_json()

    return r


# ---------------------------------------------------------------------------
# v11: Pose photo library (free Pose mode in the app)
# ---------------------------------------------------------------------------
def build_pose_router(get_poses: Callable[[], PoseStore]) -> APIRouter:
    r = APIRouter()

    @r.get("/admin/poses")
    async def poses_index(request: Request):
        if (g := guard(request)) is not None:
            return g
        rows = []
        for p in get_poses().list(include_disabled=True):
            img = (f'<img class="t" src="/media/poses/{_esc(p.photo)}">' if p.photo
                   else '<div class="t"></div>')
            rows.append(f"""<tr class="{'' if p.enabled else 'off'}"><td>{img}</td>
<td><b>{_esc(p.name)}</b><div class="muted">{_esc(p.id)} · {_esc(p.category)} · #{p.sort_order}</div>
<div class="muted">{_esc(p.credit)}</div></td>
<td>{'' if p.enabled else '<span class="pill">disabled</span>'}</td>
<td style="white-space:nowrap">
<form class="i" method="post" action="/admin/poses/{_esc(p.id)}/move"><input type="hidden" name="direction" value="-1"><button class="btn s" title="Move up">↑</button></form>
<form class="i" method="post" action="/admin/poses/{_esc(p.id)}/move"><input type="hidden" name="direction" value="1"><button class="btn s" title="Move down">↓</button></form>
<a class="btn" href="/admin/poses/{_esc(p.id)}/edit">Edit</a>
<form class="i" method="post" action="/admin/poses/{_esc(p.id)}/delete" onsubmit="return confirm('Delete {_esc(p.name)}?')"><button class="btn d">Delete</button></form>
</td></tr>""")
        body = f"""<p><a class="btn" href="/admin/poses/new">+ Add pose photo</a>
<span class="muted"> Free (no credits). Users pick a photo; it floats on the camera as a reference to copy.
Use photos you have rights to (e.g. Pexels / Unsplash license). The app also ships 7 built-in photos for offline use.</span></p>
<table><tr><th></th><th>Pose</th><th></th><th></th></tr>{''.join(rows) or '<tr><td colspan=4 class="muted">No pose photos yet.</td></tr>'}</table>"""
        return page("Poses", body)

    def pose_form(p: Pose, action: str, error: str = "") -> str:
        opts = "".join(f'<option value="{_esc(c)}" {"selected" if c == p.category else ""}>{_esc(c)}</option>'
                       for c in POSE_CATEGORIES)
        cur = f'<img class="t" src="/media/poses/{_esc(p.photo)}"> ' if p.photo else ""
        err = f'<p style="color:#ff8a80">{_esc(error)}</p>' if error else ""
        return f"""{err}<form method="post" action="{action}" enctype="multipart/form-data" style="max-width:640px">
<label>Name</label><input type="text" name="name" value="{_esc(p.name)}" required maxlength="40">
<label>Category</label><select name="category" style="padding:9px;border-radius:8px;background:#0c0e13;color:#eceff4">{opts}</select>
<label>Photo</label>{cur}<input type="file" name="photo" accept="image/jpeg,image/png,image/webp,image/*">
<div class="muted">A real photo showing the pose clearly (portrait 3:4 works best). Re-encoded as JPEG, max 1280 px, metadata removed.</div>
<label>Credit (optional)</label><input type="text" name="credit" value="{_esc(p.credit)}" maxlength="120" placeholder="Photo: Name / Pexels">
<label>Source URL (optional)</label><input type="text" name="source_url" value="{_esc(p.source_url)}" maxlength="300">
<label><input type="checkbox" name="enabled" value="1" {'checked' if p.enabled else ''}> Enabled (visible in the app)</label>
<label>Sort order</label><input type="number" name="sort_order" value="{p.sort_order}">
<p><button class="btn">Save</button> <a class="btn s" href="/admin/poses">Cancel</a></p></form>"""

    @r.get("/admin/poses/new")
    async def pose_new(request: Request):
        if (g := guard(request)) is not None:
            return g
        p = Pose(id="", name="", category="Standing", sort_order=get_poses().next_sort_order())
        return page("New pose", "<h2>New pose photo</h2>" + pose_form(p, "/admin/poses"))

    @r.get("/admin/poses/{pid}/edit")
    async def pose_edit(request: Request, pid: str):
        if (g := guard(request)) is not None:
            return g
        p = get_poses().get(pid)
        if p is None:
            raise HTTPException(status_code=404, detail="pose not found")
        return page("Edit pose", f"<h2>Edit · {_esc(p.name)}</h2>" + pose_form(p, f"/admin/poses/{_esc(p.id)}"))

    async def _save_pose(store: PoseStore, p: Pose, photo: Optional[UploadFile], source_url: str,
                         action: str, is_new: bool):
        try:
            p.source_url = clean_source_url(source_url)
        except ValueError as e:
            return page("Pose", pose_form(p, action, str(e)))
        new_file = None
        if photo is not None and photo.filename:
            raw = await photo.read()
            if raw:
                try:
                    new_file = store.save_photo(raw)
                except Exception as e:  # noqa: BLE001 - surfaced to the admin
                    return page("Pose", pose_form(p, action, f"Bad photo: {e}"))
        if is_new and new_file is None:
            return page("Pose", pose_form(p, action, "Add a photo."))
        if new_file:
            store.remove_file(p.photo)
            p.photo = new_file
        store.upsert(p)
        return RedirectResponse("/admin/poses", status_code=303)

    @r.post("/admin/poses")
    async def pose_create(
        request: Request, name: str = Form(...), category: str = Form(...),
        credit: str = Form(""), source_url: str = Form(""),
        sort_order: int = Form(0), enabled: Optional[str] = Form(None),
        photo: Optional[UploadFile] = File(None),
    ):
        if (g := guard(request)) is not None:
            return g
        if category not in POSE_CATEGORIES:
            raise HTTPException(status_code=400, detail="unknown category")
        store = get_poses()
        p = Pose(id=store.new_id(name), name=name.strip()[:40] or "Pose", category=category,
                 credit=credit, enabled=bool(enabled), sort_order=sort_order)
        return await _save_pose(store, p, photo, source_url, "/admin/poses", True)

    @r.post("/admin/poses/{pid}")
    async def pose_update(
        request: Request, pid: str, name: str = Form(...), category: str = Form(...),
        credit: str = Form(""), source_url: str = Form(""),
        sort_order: int = Form(0), enabled: Optional[str] = Form(None),
        photo: Optional[UploadFile] = File(None),
    ):
        if (g := guard(request)) is not None:
            return g
        if category not in POSE_CATEGORIES:
            raise HTTPException(status_code=400, detail="unknown category")
        store = get_poses()
        p = store.get(pid)
        if p is None:
            raise HTTPException(status_code=404, detail="pose not found")
        p.name, p.category, p.credit = name.strip()[:40] or p.name, category, credit
        p.enabled, p.sort_order = bool(enabled), sort_order
        return await _save_pose(store, p, photo, source_url, f"/admin/poses/{p.id}", False)

    @r.post("/admin/poses/{pid}/move")
    async def pose_move(request: Request, pid: str, direction: int = Form(...)):
        if (g := guard(request)) is not None:
            return g
        get_poses().move(pid, direction)
        return RedirectResponse("/admin/poses", status_code=303)

    @r.post("/admin/poses/{pid}/delete")
    async def pose_delete(request: Request, pid: str):
        if (g := guard(request)) is not None:
            return g
        get_poses().delete(pid)
        return RedirectResponse("/admin/poses", status_code=303)

    return r


# ---------------------------------------------------------------------------
# v11: hidden Pro AI prompts (portrait / night / macro / color filters)
# ---------------------------------------------------------------------------
PROMPT_LABELS = {
    "night": "Pro Night",
    "portrait": "Pro Portrait (AI background blur)",
    "macro": "Macro 2x–5x (sent alone)",
    "macro_close": "Close Macro 6x (sent alone)",
    "macro_microscope": "Microscope 100x text-based, {spot} (no photo sent)",
    "macro_extreme": "Extreme Microscope 21x (1000x light; whole prompt; {spot})",
    "macro_ultra": "Ultra Electron Microscope 30x (2000x SEM; whole prompt; {spot})",
}


def _prompt_label(key: str) -> str:
    if key.startswith("filter:"):
        return "Color filter · " + key.split(":", 1)[1].replace("_", " ").title()
    return PROMPT_LABELS.get(key, key)


def build_prompt_router(get_store: Callable[[], ModePromptStore]) -> APIRouter:
    r = APIRouter()

    @r.get("/admin/prompts")
    async def prompts_index(request: Request, saved: str = "", error: str = ""):
        if (g := guard(request)) is not None:
            return g
        st = get_store()
        msg = ""
        if saved:
            msg = f'<p style="color:#9be59b">Saved {_esc(_prompt_label(saved))}.</p>'
        if error:
            msg = f'<p style="color:#ff8a80">{_esc(error)}</p>'
        cards = []
        for k in st.keys():
            custom = st.overridden(k) is not None
            cards.append(f"""<form method="post" action="/admin/prompts/save" style="margin-bottom:22px">
<input type="hidden" name="key" value="{_esc(k)}">
<label>{_esc(_prompt_label(k))} <span class="pill">{'custom' if custom else 'default'}</span></label>
<textarea name="prompt">{_esc(st.get(k))}</textarea>
<p><button class="btn">Save</button>
<button class="btn s" formaction="/admin/prompts/reset">Reset to default</button></p></form>""")
        body = f"""<p class="muted">Hidden from users. Each text is appended after the locked enhance prompt
(the locked prompt itself is not editable). Applies to the next AI request; credits are unchanged
(quality tier only, charged on success).</p>{msg}{''.join(cards)}"""
        return page("Prompts", body)

    @r.post("/admin/prompts/save")
    async def prompts_save(request: Request, key: str = Form(...), prompt: str = Form("")):
        if (g := guard(request)) is not None:
            return g
        try:
            get_store().set(key, prompt)
        except ValueError as e:
            from urllib.parse import quote
            return RedirectResponse(f"/admin/prompts?error={quote(str(e))}", status_code=303)
        return RedirectResponse(f"/admin/prompts?saved={key}", status_code=303)

    @r.post("/admin/prompts/reset")
    async def prompts_reset(request: Request, key: str = Form(...)):
        if (g := guard(request)) is not None:
            return g
        if key not in P.DEFAULT_MODE_PROMPTS:
            raise HTTPException(status_code=400, detail="unknown prompt key")
        get_store().reset(key)
        return RedirectResponse(f"/admin/prompts?saved={key}", status_code=303)

    return r


# ---------------------------------------------------------------------------
# v11.33: Macro credits per quality + level (2K shown locked, "Coming soon")
# ---------------------------------------------------------------------------
def build_macro_credits_router(get_store: Callable[[], ModePromptStore]) -> APIRouter:
    import json as _json

    import prompts as _P

    r = APIRouter()

    def _table() -> dict:
        raw = get_store().get_config("macro_credits")
        try:
            ov = _json.loads(raw) if raw else None
        except Exception:  # noqa: BLE001
            ov = None
        return _P.merge_macro_credits(ov if isinstance(ov, dict) else None)

    @r.get("/admin/macro-credits")
    async def credits_index(request: Request, saved: str = ""):
        if (g := guard(request)) is not None:
            return g
        t = _table()
        levels = list(_P.MACRO_LEVELS)
        head = "".join(f"<th>{_esc(_P.MACRO_LEVELS[l][1])}</th>" for l in levels)
        rows = []
        for q in _P.MACRO_QUALITIES:
            locked = q in _P.MACRO_LOCKED_QUALITIES
            cells = "".join(
                f'<td><input name="{_esc(q)}:{_esc(l)}" type="number" min="1" max="100" '
                f'value="{t[q][l]}" style="width:64px"></td>' for l in levels)
            tag = ' <span class="pill">Coming soon</span>' if locked else ""
            rows.append(f"<tr><td>{_esc(q)}{tag}</td>{cells}</tr>")
        msg = '<p style="color:#9be59b">Saved.</p>' if saved else ""
        body = f"""<p class="muted">Credits per Macro photo, charged only on success. 2K is
shown in the app but locked (Coming soon).</p>{msg}
<form method="post" action="/admin/macro-credits/save"><table><tr><th>Quality</th>{head}</tr>
{''.join(rows)}</table><p><button class="btn">Save</button>
<button class="btn s" formaction="/admin/macro-credits/reset">Reset to default</button></p></form>"""
        return page("Macro credits", body)

    @r.post("/admin/macro-credits/save")
    async def credits_save(request: Request):
        if (g := guard(request)) is not None:
            return g
        form = await request.form()
        ov: dict = {}
        for k, v in form.items():
            if ":" not in k:
                continue
            q, l = k.split(":", 1)
            try:
                ov.setdefault(q, {})[l] = int(str(v))
            except ValueError:
                continue
        get_store().set_config("macro_credits", _json.dumps(_P.merge_macro_credits(ov)))
        return RedirectResponse("/admin/macro-credits?saved=1", status_code=303)

    @r.post("/admin/macro-credits/reset")
    async def credits_reset(request: Request):
        if (g := guard(request)) is not None:
            return g
        get_store().reset_config("macro_credits")
        return RedirectResponse("/admin/macro-credits?saved=1", status_code=303)

    return r


def build_video_admin_router(get_store: Callable[[], ModePromptStore], get_log: Callable) -> APIRouter:
    """v11.53 Video credits (provisional, editable) + generation history."""
    import json as _json

    import video_providers as _VP

    r = APIRouter()

    def _override() -> dict:
        try:
            ov = _json.loads(get_store().get_config("video_credits") or "{}")
            return ov if isinstance(ov, dict) else {}
        except Exception:  # noqa: BLE001
            return {}

    @r.get("/admin/video/credits")
    async def vc_index(request: Request, saved: str = ""):
        if (g := guard(request)) is not None:
            return g
        t = _VP.credit_table(_override())
        rows = []
        for k, v in t.items():
            prov, secs, res = k.split("_")
            cost = _VP.cost_inr(prov, int(secs), res)
            label = "MiniMax H3 Turbo (Phosor)" if prov == _VP.MINIMAX else "legacy"
            rows.append(f"<tr><td>{label}</td><td>{secs} s</td><td>{res}</td><td>₹{cost:.2f}</td>"
                        f'<td><input name="{_esc(k)}" type="number" min="0" max="500" value="{v}" style="width:70px"></td></tr>')
        msg = '<p style="color:#9be59b">Saved.</p>' if saved else ""
        body = f"""<div class="tabs"><a class="tab" href="/admin">Photo</a><a class="tab" href="/admin?tab=video">Video</a>
<a class="tab on" href="/admin/video/credits">Video credits</a><a class="tab" href="/admin/video/history">Video history</a></div>
<p class="muted">PROVISIONAL (not approved). Default = ceil(provider cost ₹ × {_VP.MARGIN} / ₹{_VP.INR_PER_CREDIT} per credit).
Charged only when the video is delivered. MiniMax enabled: {_VP.minimax_enabled()}</p>{msg}
<form method="post" action="/admin/video/credits/save"><table><tr><th>Model</th><th>Length</th><th>Resolution</th>
<th>Provider cost</th><th>Credits</th></tr>{''.join(rows)}</table><p><button class="btn">Save</button>
<button class="btn s" formaction="/admin/video/credits/reset">Reset to provisional defaults</button></p></form>"""
        return page("Video credits", body)

    @r.post("/admin/video/credits/save")
    async def vc_save(request: Request):
        if (g := guard(request)) is not None:
            return g
        form = await request.form()
        known = _VP.credit_table({})
        ov = {}
        for k, v in form.items():
            if k in known:
                try:
                    ov[k] = max(0, min(500, int(str(v))))
                except ValueError:
                    continue
        get_store().set_config("video_credits", _json.dumps(ov))
        return RedirectResponse("/admin/video/credits?saved=1", status_code=303)

    @r.post("/admin/video/credits/reset")
    async def vc_reset(request: Request):
        if (g := guard(request)) is not None:
            return g
        get_store().reset_config("video_credits")
        return RedirectResponse("/admin/video/credits?saved=1", status_code=303)

    @r.get("/admin/video/history")
    async def vh(request: Request):
        if (g := guard(request)) is not None:
            return g
        rows = []
        for j in get_log().recent(200):
            rows.append(f"<tr><td>{_esc(j['created'])}</td><td>{_esc(j['device_id'][:10])}…</td><td>{_esc(j['provider'])}</td>"
                        f"<td>{_esc(j['kind'])}</td><td>{j['seconds']} s · {_esc(j['resolution'])} · {_esc(j['aspect_ratio'])}</td>"
                        f"<td>{_esc(j['style_id'] or 'custom')}</td><td>₹{j['cost_inr']:.2f}</td><td>{j['credits']}</td>"
                        f"<td>{_esc(j['status'])}</td><td>{j['charged']}</td><td class=\"muted\">{_esc((j['error'] or '')[:80])}</td></tr>")
        body = f"""<div class="tabs"><a class="tab" href="/admin">Photo</a><a class="tab" href="/admin?tab=video">Video</a>
<a class="tab" href="/admin/video/credits">Video credits</a><a class="tab on" href="/admin/video/history">Video history</a></div>
<p class="muted">Last 200 video jobs (server builds). Cost = estimated provider cost.</p>
<table><tr><th>Time (UTC)</th><th>Device</th><th>Provider</th><th>Kind</th><th>Settings</th><th>Style</th><th>Cost</th>
<th>Credits</th><th>Status</th><th>Charged</th><th>Error</th></tr>{''.join(rows)}</table>"""
        return page("Video history", body)

    return r
