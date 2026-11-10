# AI Camera server (v10)

FastAPI + SQLite. Holds `OPENROUTER_API_KEY`, runs the credits ledger (free 2/day IST reset, Pro, packs,
starter trials), TEST MODE purchases, `/v1/enhance` (crop + context → Flare, optional night add-on),
the **AI Style Library** (`/v1/styles`, `/v1/looks/apply`) and the **admin panel** (`/admin`).
Credits are charged only after a successful AI result.

## Run locally (now)

```bash
cd /workspace/ai-camera-app/enhance-server
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt -r requirements-dev.txt
.venv/bin/python -m pytest -q tests                      # 33 tests, OpenRouter mocked

export OPENROUTER_API_KEY=...        # never commit / never put in the release APK
export ADMIN_PASSWORD='pick-a-long-password'
.venv/bin/python main.py             # http://0.0.0.0:8787  (PORT= to change)
```

- Admin on the same computer: open `http://127.0.0.1:8787/admin`.
- Admin from a phone on the same Wi-Fi: `http://<computer-LAN-IP>:8787/admin` (browser allows http).
- The **app** needs HTTPS (Android blocks cleartext), so expose the server with a tunnel and paste the HTTPS URL in
  app Settings → "Enhance server URL":
  ```bash
  cloudflared tunnel --url http://localhost:8787      # free quick tunnel → https://xxxx.trycloudflare.com
  # or: ngrok http 8787
  ```
  The same HTTPS URL + `/admin` then works from anywhere (phone included) while the computer and tunnel run.
- Dry run without spending: `ENHANCE_MOCK=1` (returns a resized copy of the input instead of calling OpenRouter).

## Env vars

| Var | Default | Meaning |
|-----|---------|---------|
| `OPENROUTER_API_KEY` | — | required for real AI calls |
| `ADMIN_PASSWORD` | unset | enables `/admin`; unset → admin returns 503 (disabled) |
| `STYLES_DB` | `./styles.sqlite3` | style library database (seeded from `seed_styles.json` on first run) |
| `STYLE_MEDIA_DIR` | `./media/styles` | public display images (served at `/media/styles/<file>`); reference images go to `<dir>_refs` (private, never served publicly) |
| `POSES_DB` | `./poses.sqlite3` | v10 pose library database |
| `POSE_MEDIA_DIR` | `./media/poses` | pose outline PNGs (public, served at `/media/poses/<file>`) |
| `LEDGER_DB` | `./ledger.sqlite3` | credits ledger |
| `ALLOW_TEST_PURCHASES` | `1` | TEST MODE purchases (no money). Set `0` in production until Play Billing verification exists |
| `ENHANCE_MOCK` | `0` | `1` = never call OpenRouter |
| `ENABLE_LEGACY_ENHANCE` | `0` | `1` = keep the old free v6 `/enhance` |
| `UPSTREAM_TIMEOUT` | `90` | seconds per OpenRouter request; timeout → 504 `{reason: timeout}`, no charge |
| `PORT` | `8787` | listen port |

Keep `STYLES_DB`, `STYLE_MEDIA_DIR` (+ `_refs`), `POSES_DB`, `POSE_MEDIA_DIR` and `LEDGER_DB` on a persistent disk.

## Admin panel (`/admin`)

1. Open `/admin` → log in with `ADMIN_PASSWORD` (session cookie, 12 h, HttpOnly, SameSite=Strict; 5 wrong
   passwords per IP per 10 min → temporarily blocked).
2. List: every style (enabled or not) with thumbnail, category, cost, Pro-only, enabled, ↑/↓ to reorder, Edit, Delete.
3. **Add / Edit**: name, category, display image (what users see on the card), up to 4 reference images
   (sent to the AI together with the user's photo; tick to remove), hidden prompt (textarea — never sent to the app),
   credit cost, Pro-only, enabled, sort order, **Needs a person** (default on: the app warns "No person found in this
   photo" before applying it to a photo without a face).
4. Changes are live immediately: the app fetches `/v1/styles` (version hash) and refreshes its cache.

Prompt tips: describe the look/scene/outfit; the server always wraps it with an identity-preservation prompt
(face, skin tone, body shape stay the same), so you don't need to repeat that.

## Pose library (`/admin/poses`, v10)

Header links: **Styles · Poses**. Poses feed the app's free Pose mode (no credits, no AI).
1. List: outline thumbnail, name, id, category, whether landmarks are set, Edit / Delete.
2. **Add / Edit**: name, category (Standing, Sitting, Couple, Group, Girls, Boys, Wedding), **outline image**
   (transparent PNG, 3:4 portrait, body drawn where the person should stand — it is stretched to the viewfinder;
   re-encoded as PNG ≤ 1200 px, metadata stripped), optional **landmarks JSON** (`[{"0":[x,y], "11":[x,y], …}]`,
   ML Kit indices 0–32, x/y 0..1 in the frame, one object per person; a single figure or a list of 33 `[x,y]` is
   also accepted), enabled, sort order. Without landmarks the phone derives them once from the outline image.
   One person → live "Perfect!" scoring; several → outline guide only.
3. The app adds server poses after its 14 built-in ones (`GET /v1/poses`).

## v10 behaviour
* `POST /v1/looks/apply` with a custom prompt that only asks for "enhance / clear / HD / sharp / 4K…"
  → 400 `{reason: "enhance_only"}` before any AI call (nothing charged); the app shows the capture-time tip.

## v9.1 behaviour

* Looks: input downscaled to 1536 px JPEG, Flare quality `medium` (HD → `low`), JPEG output, no upscale,
  custom tier clamped to HD / Full HD, variation top-ups in parallel.
* Failures return `detail: {reason, message}` with `reason` ∈ `timeout` (504), `no_image` (502), `refused`,
  `blocked` (400, custom prompt hit the safety list), `upstream`. Nothing is charged on any failure; if the
  app disconnects (Cancel) before the result, the request ends with 499 and is not charged.
* Custom prompts: max 200 chars; tiny safety block list (`prompts.BLOCKED_CUSTOM_PATTERNS`).

## Public API (app)

| Endpoint | Purpose |
|----------|---------|
| `GET /health` | status, model, mock / test-purchase flags |
| `GET /v1/products` | products + quality tiers |
| `GET /v1/account?device_id=` | balance, Pro expiry, trials left |
| `POST /v1/purchase` JSON `{device_id, product_id}` | TEST MODE purchase |
| `POST /v1/enhance` multipart | `device_id`, `image`, optional `context`, `quality` (hd/full_hd/ultra_hd/4k), `zoom`, `optical_limit`, `filter_id`, `night` (true → night prompt appended after the locked prompt). 200 → image + `X-Credits-Charged`, `X-Trials-Used`, `X-Account`, `X-Enhance-Cost`, `X-Night`. 402 `{detail:{reason}}`, 502 on AI failure (nothing charged). |
| `GET /v1/styles` | `{version, styles:[{id,name,category,credit_cost,pro_only,sort_order,image_url,has_reference}]}` — enabled only, **no prompts / no reference URLs** |
| `GET /media/styles/<file>` | public display images |
| `GET /v1/poses` | v10: `{version, poses:[{id,name,category,outline_url,landmarks,sort_order}]}` — enabled only |
| `GET /media/poses/<file>` | v10: public pose outline PNGs |
| `POST /v1/looks/apply` multipart | `device_id`, `image`, `style_id` **or** `custom_prompt` (+ `quality` for custom), `variations` 1–4. 200 → JSON `{images:[base64], mime, credits_charged, trials_used, account, cost, style_id, references_used}`; 404 disabled/unknown style; 402 not allowed; 502 AI failure (nothing charged). |

## Hosting (so Ankush can use admin + app without this computer)

Any host that runs Python and has a persistent disk works:
- **Small VPS** (e.g. DigitalOcean / Hetzner / AWS Lightsail, Mumbai region): `git clone`, create the venv,
  run `uvicorn main:app --host 127.0.0.1 --port 8787` under systemd, put **Caddy** in front
  (`yourdomain.com { reverse_proxy 127.0.0.1:8787 }` gives automatic HTTPS). Set the env vars in the systemd unit.
- **Render / Railway / Fly.io**: start command `uvicorn main:app --host 0.0.0.0 --port $PORT`, attach a
  persistent volume and point `STYLES_DB`, `STYLE_MEDIA_DIR`, `LEDGER_DB` into it; set secrets in the dashboard.
- Then: app Settings → server URL `https://yourdomain.com`, admin at `https://yourdomain.com/admin`.
- Production checklist: strong `ADMIN_PASSWORD`, `ALLOW_TEST_PURCHASES=0` once real billing exists, HTTPS only,
  back up the SQLite files + media folders.

## Files
`main.py` (API), `ledger.py` (credit rules + SQLite), `prompts.py` (locked prompt + additions + night + look
wrapper — must stay identical to the app's `prompt_builder.dart`; a test checks this), `styles.py` (style store,
image handling), `admin.py` (admin panel), `seed_styles.json` + `seed_media/` (initial library),
`poses.py` (v10 pose store + landmarks validation), `tests/test_server.py`, `tests/test_v9.py`,
`tests/test_v91.py`, `tests/test_v10.py`.

## v11 (server 11.0.0)

* `POST /v1/enhance` extra fields: `mode` (`photo` | `portrait` | `night` |
  `macro`), `color_filter` (premium filter id, e.g. `warm_gold`), `subject`
  (macro label, sanitised). Each mode / filter appends a hidden prompt that
  admins can edit at **/admin/prompts** (Reset = built-in default). The
  locked enhance prompt is unchanged. Credits = quality tier (1/2/4/8),
  charged only on success.
* Pro Night guards (nothing charged): near-black input → `400
  {"reason":"too_dark"}` before any OpenRouter call; AI result whose
  structure (gradient similarity < 0.50) differs from the input → `422
  {"reason":"structure_changed"}`. Headers `X-Mode`, `X-Structure`.
* Pose photos: `GET /v1/poses`, admin CRUD at **/admin/poses** (upload,
  category, credit, source URL, order). Seeded from `seed_poses/` (30 Pexels
  photos, see `seed_poses/ATTRIBUTION.md`).

## v11.1 (server 11.1.0) — Macro + AI Microscope

* `POST /v1/enhance` with `mode=macro` takes `subject` (locked on-device label or the
  user's pick) and optional `macro_level` (`macro` | `close` | `microscope`). Without it
  (or with an unknown value) the level is taken from `zoom`: 2–4x macro, 5–7x close,
  8–10x microscope. Response header `X-Macro-Level`.
* Three hidden, admin-editable prompts at `/admin/prompts`: `macro`, `macro_close`,
  `macro_microscope`. Each must contain `{subject}`; `{level}` is optional. All say:
  identify the subject, render THE SAME subject in its own colors and material, go only as
  deep as the level, never turn it into another object.
* Credits: normal tier credits (HD 1 / FHD 2 / UHD 4 / 4K 8), charged when an image is
  generated. Only technical failures (timeout, network, upstream error/refusal) are free.
  No structure / subject-change refund check in Macro (that guard stays Pro Night only).
  Retries are normal paid requests.

## v11.2 (server 11.1.1)

* Microscope level (8x–10x): ONLY the `macro_microscope` prompt is sent (no locked enhance
  prompt, no context image). Every other mode/level still starts with the unchanged locked
  enhance prompt. The default microscope prompt asks for a real photomicrograph look (cells,
  fibers, microstructure, microscope optics) of THE SAME subject and preserves the original
  color palette.

## v11.3 (server 11.1.2)

* `macro_microscope` default rewritten for a full inside-the-microscope view (~400x–1000x,
  cells / fibers / grain boundaries, brightfield look, optional eyepiece vignette), still the
  same subject, its own color palette, no text. Sent alone (no locked prompt), as in v11.2.
* App: distance gate before a Microscope shot ("Move closer for Microscope 🔬" → Move closer /
  Shoot as Macro). Nothing is sent or charged by the gate.

## v11.4 (server 11.1.3)

* Microscope + Close Macro follow a WYSIWYG framing rule (`MACRO_FRAMING_RULE`): same framing,
  positions, composition and scale. Microscope (still sent alone) is now an ultra-high-resolution
  super-macro photograph whose detail depth follows what fills the frame; no eyepiece vignette,
  stain colors, slide look or "400x–1000x" wording; exact original colors.

## v11.5 (server 11.1.4) — two-image Macro

* Macro (all levels): the app sends image 1 = sharp full-res crop of the zoomed region (camera
  never zooms past the optical limit, no upscaling) and `context` = full frame with the region
  boxed in red (1024 px). Prompts `macro` / `macro_close` / `macro_microscope` (admin-editable)
  explain both images, set the depth (light / strong close / true microscope), show only what
  exists, keep real colors, no new objects, nothing painted on reflections/pupil. Microscope is
  still sent alone; Macro/Close keep the locked enhance prompt (no generic context/zoom sentence).
* Server-side colour match (`color_match.py`) of every Macro result to the source crop.

## v11.6 (server 11.1.5)

* Macro zoom 2x–20x. Levels: 2–5x Macro, 6–11x Close Macro, 12–20x Microscope.
* Prompts take an optional `{zoom}` ("to 20x"). They say the crop is a tiny area of the subject,
  must be rendered much more magnified, filling the frame (Close + Microscope forbid returning
  the same composition merely sharpened); Microscope makes the material microstructure dominate
  (coin: metal grain, scratches, wear, pits). Two images, colour match, reflection rule unchanged.

## v11.7 (server 11.1.6)

* Macro zoom 2x–30x. New level `extreme` (21–30x, admin key `macro_extreme`, sent alone like
  Microscope): a single micro feature fills the frame, no readable lettering.
* Prompts: "depth scales with zoom" + one consistent material color rule (no golden/colored
  patches not in the source).
* Colour match adds a regional chroma pass (8×8 grid, bilinear): low-frequency colour follows the
  source crop, AI detail stays (server + app direct path).

## Photo Styles admin + JSON API (v11.1.28 + styles upgrade)

* Panel: `/admin` → **Photo | Video** tabs (Video = "Coming soon" placeholder).
  Add / edit / ↑↓ reorder / Enable-Disable / delete; name, category, hidden
  prompt, thumbnail, up to 4 reference images, credit cost, Pro only,
  needs-person, **Free first try** (per-style opt-in to the existing one-time
  `library_style` starter trial).
* JSON API (separate `ADMIN_API_TOKEN`, `Authorization: Bearer <token>`):
  `GET/POST /admin/api/styles`, `GET/PUT/DELETE /admin/api/styles/{id}`,
  `POST /admin/api/styles/{id}/images` (multipart `display_image`, `ref_images`,
  `replace_refs=1`), `POST /admin/api/styles/order` `{"ids":[...]}`.
* CLI: `ADMIN_API_TOKEN=… python tools/add_style.py style.json --thumbnail s.jpg --ref r1.jpg --ref r2.jpg`
  (`--update`, `--replace-refs`, `--list`, `--delete ID`, `--server URL`). See `tools/example_style.json`.
* Public `/v1/styles` still never returns prompts or reference images.

## Text-to-video (fal.ai LTX-2.3)
- Put the fal key in `enhance-server/.env` (see `.env.example`: `FAL_KEY=`). `main.py` loads `.env` at startup (does not override real env vars). The key stays on the server.
- `POST /v1/video/generate` JSON `{device_id, prompt, duration: 6|8|10, resolution: 1080p|1440p|2160p, aspect_ratio: 16:9|9:16, fps: 24|25|48|50, generate_audio}` → `{job_id, status:"queued", estimated_cost_usd}`.
- `GET /v1/video/status/{job_id}?device_id=…` → `{status: queued|running|done|failed, video:{url,…}}`.
- Prompt goes through the custom-prompt safety list; fal's safety checker stays on; 5 videos/device/hour (`VIDEO_PER_DEVICE_PER_HOUR`). No credits charged yet.
- On Vercel set `FAL_KEY` as a project env var (the `.env` file is not deployed).
