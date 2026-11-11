# AI Camera (Flutter, v10)

India-first Android AI camera for Ankush. Capture → (Pro mode) auto AI enhance with
**OpenRouter `openai/gpt-image-2.5-flare`** → filters / AI styles → save.
v10 adds free on-device shooting modes (Portrait, Night, HDR, Document, Pose, QR, smile shot, editor), live
preview of AI looks before capture, and enhance only at capture time.
v9 adds: Samsung-style continuous zoom ruler, the AI Style Library (look generation with hidden prompts
+ reference images, managed from a web admin panel), and Night mode (free burst merge + Pro AI night).

## Paths

| Item | Path |
|------|------|
| Flutter app | `/workspace/ai-camera-app/ai_camera/` |
| Server (FastAPI + SQLite + admin) | `/workspace/ai-camera-app/enhance-server/` |
| APKs | `/workspace/ai-camera-app/apks/` |
| Source backups | `/workspace/ai-camera-app/backups/v6-src` … `v9-src`, `v9.1-src`, `v10-src` |
| v9 / v9.1 real-call evidence | `/workspace/ai-camera-app/verification/v9/`, `verification/v9.1/` |
| Flutter / Android SDK | `/home/box/devtools/flutter/`, `/home/box/devtools/android-sdk/` |

```bash
export PATH="/home/box/devtools/flutter/bin:$PATH"
export ANDROID_HOME=/home/box/devtools/android-sdk ANDROID_SDK_ROOT=/home/box/devtools/android-sdk
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
```

## v10 (free on-device modes, live AI-look preview, pose guide, enhance only at capture)

> Status: code complete + tested; **APK not built yet** (Ankush: one combined build after more features).

**Live preview of AI looks before capture (no credits until the shutter):** picking an AI filter / style / custom
change shows an on-device approximation in the viewfinder plus a "Live preview · AI applies after the shutter"
badge — colour grade (`ColorFilter` matrix) for colour looks (Cinematic, Film, Moody, B&W, Vintage, Warm…), light
skin smoothing for beauty/portrait looks, live background blur for portrait styles, and a small sample thumbnail
for big changes (outfit / place / festival). Credits are only spent after the shutter + a successful AI result
(unchanged ledger rules). `lib/services/live_look.dart`, `lib/widgets/live_effects_preview.dart`.

**Shooting modes (all free, on-device, 0 credits)** — strip above the shutter (PHOTO · PORTRAIT · NIGHT ·
DOCUMENT · MORE → HDR, POSE + toggles); NORMAL / PRO AI tabs stay under the shutter. Routing is a pure function
(`routeFor` in `lib/models/shoot_mode.dart`, unit-tested: `creditCost == 0`, `usesCloudAi == false` for every mode).

| Mode / feature | How |
|---|---|
| Portrait | ML Kit Selfie Segmentation: live blur in the preview (mask → `ShaderMask`), and on the saved photo (`applyBokeh`, person kept sharp; "no person found" → photo kept sharp). PRO AI enhance (if on) runs on the blurred photo with the unchanged locked prompt. |
| Night | Same v9 night pipeline (burst merge / PRO AI night); the quick-menu moon and the strip stay in sync. |
| HDR | 3-frame bracket 0 / −s / +s EV (s on the camera's EV grid, ≤ 2 EV), MTB alignment coarse→fine, exposure fusion (well-exposedness weights), comparametric ghost rejection; falls back to 1 frame if the camera has no EV range or frames don't align. `lib/services/hdr_merge.dart`. |
| Document | Google ML Kit Document Scanner (Play services UI: edge detect, crop, clean-up, multi-page, gallery import) → PDF kept in app `Scans/Scan_YYYY-MM-DD_HH-MM-SS.pdf`; sheet: **Share PDF**, **Save pages** to Gallery. |
| QR / barcode | Live scanning → tappable chip: Open link · Open UPI app · Call · Email · Copy (Wi-Fi / text). |
| Grid / level | More → Grid (default on), Level (accelerometer roll, green when within ±1°, hidden when flat). |
| Smile shot | More → Smile shot (off by default): ML Kit smiling probability ≥ 0.8 twice in a row → auto-capture, 4 s cooldown. |
| Face-priority focus | Largest face metered (AF+AE, no ring) when you haven't tapped; the shutter's pre-capture AF uses the face. Tap focus / AE-AF lock always win. Same ML Kit face detector now powers "No person found" (native fallback kept). |
| Scene tips | ML Kit Image Labeling → subtle chip ("Document? Try Document scan", "Food? Try Portrait…", "Bright sky? Try HDR"), shown at most once per 20 s, needs 2 consistent sightings, ✕ hides it for the session. |
| Copy text | Preview screen top bar → on-device text recognition (Latin) → sheet with **Copy text**. |
| Editor | Preview → **Edit**: crop (Free / 1:1 / 3:4 / 4:3 / 9:16, drag corners), rotate, brightness, contrast, saturation, sharpness → new JPEG (original untouched). |

**Pose mode (free):** cards for Standing, Sitting, Couple, Group, Girls, Boys, Wedding (14 bundled vector
outlines + admin poses from `GET /v1/poses`). ML Kit Pose Detection (33 landmarks, base model, stream mode) is
compared with the selected outline: bone-angle similarity (60 %), placement (20 %), size (20 %), left/right
mirrored labels accepted; "Perfect!" needs ≥ 0.85 held 700 ms **and** the body roughly on the outline. Outline turns
red → amber → green; hints "Move left/right", "Come closer", "Step back", "Match the arms/legs". Optional
**Auto capture** on Perfect (4 s cooldown). Categories are re-ordered by the scene (wedding → Wedding, 2 faces →
Couple, 3+ → Group, chair → Sitting). Multi-person poses are outline guides (ML Kit tracks one person).

**Enhance only at capture time:** gallery photos and Normal captures never auto-enhance and show no AI filters;
Normal previews show the tip "Shoot in Pro AI for sharper, clearer photos". Gallery = creative Styles + Describe a
change only. If the describe text is only "enhance / clear / HD / sharp / 4K / upscale…" (`isEnhanceOnlyPrompt`,
mirrored on the server as `enhance_only_custom_prompt`), the sheet shows "Enhance happens at capture — shoot in Pro
AI for sharper, clearer photos. No credits used." and Apply is disabled; the service and the server
(400 `{reason: enhance_only}`) refuse it before any AI call → nothing charged. PRO AI capture auto-enhance, the AI
wave overlay and the locked enhance prompt are unchanged.

**ML Kit footprint (android/app/build.gradle.kts):**
- Barcode, face, text OCR and image labeling use the **Play services (unbundled)** variants — same API; the
  bundled artifacts are excluded. Models download via Play services (manifest `DEPENDENCIES=barcode,face,ocr,ica`).
- Document scanner is Play services only. Selfie segmentation and pose have no unbundled option.
- The arm64 APK now packages arm64 natives only (`-Ptarget-platform` → `abiFilters` on every build type — the Flutter
  Gradle plugin puts its default 3-ABI list on the build types, so a defaultConfig filter alone is not enough). ML Kit
  ships natives for every ABI, stored uncompressed.
- The unused "accurate" pose landmark model (6.4 MB) is dropped via `ignoreAssetsPattern`.
- `proguard-rules.pro` has `-dontwarn` for the CJK / Devanagari OCR classes the plugin compiles against.

Estimated arm64 APK impact (raw sizes from the Maven artifacts; **to be measured at the combined build**):

| Part | Size |
|---|---|
| mediapipe (segmentation + pose) | 21.1 MB |
| ML Kit common pipeline (pulled by image-labeling-custom) | 10.7 MB |
| Pose lite + person-detector models | 5.8 MB |
| Dex | ~1–2 MB |
| **Total** | **≈ +38–40 MB** |

**Measured (combined build, 08 Oct 2026):** profile/test APK `AI-Camera-v10-modes-arm64-profile-WITH-KEY-TEST-ONLY.apk` = **64.4 MB** (64,426,935 bytes; v9.1: 33.6 MB → +30.8 MB), arm64-v8a natives only, no full pose model. The first build without the build-type ABI fix was 101.8 MB (x86_64 + armeabi-v7a ML Kit natives). Release (no key) was not built for v10 yet; the estimate is ≈ 50 MB (v9.1: 20.7 MB). Bundling everything would have added about +31 MB more. Swapping in multi-ABI natives would have multiplied the total.

**Server:** `/admin/poses` (name, category, outline PNG upload, optional landmarks JSON, enabled, sort order; add /
edit / delete), public `GET /v1/poses` + `/media/poses/<file>`, enhance-only guard on `/v1/looks/apply`.

**Limitations (honest):**
- Portrait blur is a segmentation mask + Gaussian blur, not Samsung's depth/dual-camera bokeh: hair edges and
  glasses can look cut out, there is no depth falloff, and the live blur runs at mask resolution and ~10 fps.
- HDR is a 3-shot merge in Dart (≈ 3–6 s on a 12 MP still). Samsung's native multi-frame HDR in the ISP is
  faster and better on motion. Shaky hands → falls back to one frame.
- Night is the existing v9 burst, not Samsung Nightography.
- Pose scoring is single-person, based on 2D angles. Server poses without landmarks are derived on-device from
  the outline image (may fail → outline guide only). Outlines are stretched to the frame (upload 3:4).
- Overlay/mask mapping assumes the analysis stream has the same field of view as the preview (true for CameraX
  on tested setups). Unbundled models need Play services + a one-time download (features silently wait until ready).
- The live preview of AI looks is an approximation (colour/smoothing/blur/thumbnail). The AI result can differ.
- Live blur/smoothing draws the camera texture twice (extra GPU). Accurate pose mode is unavailable (model stripped).

## v9.1 (fast + reliable looks, tap-to-focus)

Fixes "custom change / style keeps processing forever" (S24 Ultra, TEST APK) and poor focus.

**Root cause:** custom changes used the capture tier (UHD/4K → Flare `high`, PNG output ~3 MB, pure-Dart
decode/upscale on the phone), 240 s timeouts with no progress/cancel, no body-read timeout in server mode,
and a no-person photo is not refused by Flare (it invents a person).

| | v9 | v9.1 |
|---|---|---|
| Look input | 2048 px (server: raw 2–6 MB original) | **1536 px** JPEG q90 (enhance ≤2048, context 768, refs 1024), EXIF baked, native decode |
| Look quality | tier (UHD/4K → `high`) | **`medium`** (HD → `low`); custom tiers HD / Full HD only (UHD/4K clamp → 2 credits) |
| Output | PNG + upscale | **JPEG**, no upscale of look outputs |
| Variations | sequential top-ups | parallel top-ups; n=1 → exactly one call |
| Timeout | 240 s | **90 s** per AI request (server: `UPSTREAM_TIMEOUT`, client 120 s incl. body read) |
| Progress | spinner | wave overlay + **elapsed seconds** + **Cancel** |
| Failures | generic | timeout / no image / refused / blocked / network / cancelled → clear message + Retry, **no credits charged** |

* **Person check (styles only):** styles with `needs_person` (admin checkbox, default on) run an on-device
  face check (Android `FaceDetector`, ≤1024 px, <5 s). No face → "No person found in this photo" dialog
  (Choose another photo / Apply anyway). Non-person styles and custom changes are never pre-checked.
* **Custom box:** 200-char limit, English example chips/placeholder (Black suit, Beach at sunset, Red saree,
  Snowy winter), identity-preserving wrapper prompt kept, tiny safety block list (nudity/undressing, sexual
  content, minors, face-swap with another person, gore). No relevance check — users may type anything.
  Model refusals / text-only answers → "Couldn't apply this change…" with no charge.
* **Focus:** continuous AF/AE on every new controller (init, lens switch, resume). Tap on the preview →
  AF + AE metering at the tapped point (mapping undoes the cover-fit, 4:3/9:16/1:1 crop and digital zoom;
  CameraX handles rotation/front mirroring) with a Samsung-like focus ring; back to continuous AF after 5 s
  or on zoom/lens/ratio change. Long-press → **AE/AF lock** (gold ring + label) until the next tap or
  zoom/lens/ratio change. Shutter runs an AF pass (tapped point, else centre, ≤900 ms) before the still.
  Pinch = 2 fingers, tap = 1 finger (same gesture arena; tested).

Real measurements (box → OpenRouter, 12 MP 4000×3000 JPEG, "black suit"):

| | request | network | local prep | output | cost |
|---|---|---|---|---|---|
| v9 (UHD → high, PNG) | 757 KB | 19.1 s | 7.6 s | 3.2 MB PNG | $0.061 |
| v9.1 scene (UHD → Full HD medium) | 426 KB | 76.3 s* | 0.37 s | 171 KB JPEG | $0.024 |
| v9.1 portrait (Full HD medium) | 324 KB | 12.0 s | 0.37 s | 146 KB JPEG | $0.024 |

\* Flare queue latency varies a lot between calls; the 90 s timeout + Cancel keep the app responsive either way.
Evidence: `verification/v9.1/`.

## v9

### 1. Continuous zoom (Samsung style)
- Pill keeps real-lens chips only (e.g. S24 Ultra `.6 1 2 3 5 10`); the 30/100 chips are gone (they are labelled
  ticks on the ruler instead).
- Long-press **or** horizontal drag on the pill (or a pinch) opens the ruler: big live label (`22.0x`), curved
  ruler, gold centre needle. Drag left = zoom in. Steps: 0.1x below 10x, 1x from 10x up to 100x; exact min
  (e.g. 0.6) and max stay reachable. Tap a labelled tick to jump. Closes 2.5 s after the last touch.
- Haptic tick (`selectionClick`) whenever a lens chip value is crossed (ruler, drag, pinch).
- Logic: `lib/services/zoom_ruler.dart` (log-scale position↔zoom, quantise, ticks, crossings);
  UI: `lib/widgets/zoom_ruler.dart`, `lib/widgets/zoom_pill.dart`. v8 zoom calibration is unchanged.

### 2. AI Style Library (looks, not filters)
- Styles come from the server (`GET /v1/styles`, no prompts), cached on the phone (prefs + thumbnail disk cache),
  with a bundled seed list (`assets/styles/seed_styles.json` + `samples/`) as fallback.
- Where: post-capture **Styles** strip (cards with 🪙 cost badge, "See all"), camera quick menu → Styles, and from
  the gallery (image_picker).
- Tap card → bottom sheet: the look sample on top, your photo below, `Apply · 🪙2` (or `Apply · Free` when the
  one-time starter trial covers it). Tapping charges nothing. No photo yet → `Take photo` / `Choose from gallery`.
- Apply → server `POST /v1/looks/apply` (style_id; the server composes hidden prompt + identity wrapper + reference
  images) → AI wave overlay → result screen with before/after compare slider, Save, Try another style, Retry.
  Original is kept. Credits are deducted only on success.
- "Describe a change…" custom prompt: costs the chosen quality tier's credits; wrapped in the identity-preserving
  prompt; available to Free users too.
- "4 variations": 4× credits, charged per image actually received.
- Test key build without a server URL: uses the bundled seed prompts locally (`local_style_prompts.dart`, compiled
  in only when a key is embedded — the release APK has neither key nor prompts).

### 3. Admin panel — see `enhance-server/README.md`

### 4. Night mode
- Quick menu → moon icon toggles Night; viewfinder shows a `Night` (Normal) / `Night · AI` (Pro AI) badge
  (tap to turn off). Exposure is raised +1 EV live (clamped to the camera max).
- Free: burst of 3 frames → aligned (global translation) + averaged on-device (noise reduction) with a
  "Hold steady 1–2s" overlay. Flash on → single frame.
- Pro AI: the night prompt is appended right after the locked enhance prompt (locked text unchanged).
- Extensible: `lib/services/night_pipeline.dart` → `NightStep` enum + `selectCapturePipeline()`; add a step there.
- Settings shows whether the phone exposes a Camera2 Night extension (info only — the camera plugin can't bind
  CameraX extensions yet).

## v8 UI (Samsung-style camera)

- Top bar: `PRO` (opens Pro sheet) · coin + balance · quality chip `HD/FHD/UHD/4K` (tap = change). No title, no top gallery/settings.
- Zoom pill (`widgets/zoom_pill.dart`, logic `services/zoom_chips.dart`): real-lens chips from Camera2
  (ultra-wide, 1, 2, usable optical lenses, 2× best optical, e.g. S24 Ultra `.6 1 2 3 5 10`); (v9: no 30/100 chips —
  use the ruler). Selected chip = dark circle `10×`.
- Four-dot button → `QuickMenuBar` (v9 order: Settings, Flash, Night, Styles, Filters, Timer, Ratio, Quality, ✕). Filters open a strip above the shutter; Styles opens the style library; active filter / pending look = small badge + gold dot.
- Free filters preview live on the viewfinder (colour matrix) and are applied after capture; AI filters in Pro AI mode; AI styles work in both modes.
- Mode tabs under the shutter: `NORMAL · PRO AI`. Long AI info → brief transient notices only.
- All UI text English (no Devanagari in `lib/`).
- Zoom calibration: displayed N× = CameraX zoomRatio × digital crop, 1x = main lens full 4:3 frame
  (`ZoomPlan.effectiveZoom`, `test/zoom_calibration_test.dart`). 9:16 keeps full height and crops width, so compare
  with the stock camera in the same ratio. Settings → zoom info shows "Last capture" (camera × digital, crop, EXIF focal/digital zoom).
- APKs: `apks/AI-Camera-v8-ui-arm64-profile-WITH-KEY-TEST-ONLY.apk`, `apks/AI-Camera-v8-ui-arm64-release-no-key.apk`.

## Credits rules (identical in `entitlements.dart` and `enhance-server/ledger.py`, unit-tested on both sides)
- Free: 2 credits/day, HD only, reset at 00:00 IST, no rollover/stacking.
- Above the optical limit, AI enhance is Pro-only (normal photos still go to 100x).
- Starter trial (once per device): 1 high-zoom AI shot, 1 AI filter, 1 single-image library style apply,
  1 Ultra HD/4K shot. A trial costs 0 credits. Pro never uses trials.
- Spend order: free daily → Pro credits → pack credits. Packs never expire.
- AI styles: Free and Pro, each style costs its admin-set credits (default 2); Pro-only styles need Pro.
  Custom change = tier credits. Variations = cost × images received.

## Build

```bash
cd /workspace/ai-camera-app/ai_camera
# TEST ONLY — embeds key, runs ledger + seed style prompts locally if no server URL is set:
flutter build apk --profile --target-platform android-arm64 --dart-define=OPENROUTER_API_KEY="$OPENROUTER_API_KEY"
# Release — NO key (needs an HTTPS server URL for AI + styles; otherwise local filters only):
env -u OPENROUTER_API_KEY flutter build apk --release --target-platform android-arm64
```

v9 copies (`apks/`):
- `AI-Camera-v9-styles-arm64-profile-WITH-KEY-TEST-ONLY.apk` (key inside — test only, never share publicly)
- `AI-Camera-v9-styles-arm64-release-no-key.apk` (checked: no key, no `sk-or-v1-`, no hidden style prompts)

The app talks to the server over HTTPS only (Android blocks cleartext http), so use a tunnel or a real host.
Settings → "Enhance server URL".

## Testing

```bash
cd ai_camera && flutter analyze && flutter test              # 301 tests (v10)
cd ../enhance-server && .venv/bin/python -m pytest -q tests  # 63 tests, upstream mocked
```

Real OpenRouter checks for v9 (2 calls, total $0.0535 ≈ ₹4.7): style apply `paris_eiffel` with 1 reference
image via the server ($0.0296, identity kept) and a Pro Full HD night enhance ($0.0239, denoised, night kept).
Evidence images in `verification/v9/`.

## v11 (app 1.11.0+12, server 11.0.0)

Mode carousel (selected mode centred over the shutter), Portrait = phone
BOKEH extension in Normal / AI bokeh in Pro AI, Pose = real photo gallery
(no outline, no auto-capture), Night = hold-still 8–15 frame Camera2 burst
with align + merge + tone map (Pro Night: natural tone → AI with darkness
and structure guards), Macro (Pro AI) with 2–5x chips, distance guide and
sharpest-of-burst, 10 premium colour filters (live, strength, pin; AI final
in Pro AI). See enhance-server/README.md for the API.

## v11.51 (1.11.51+64) — AI filters inside Styles
- Four-dot menu: "Filters" removed (old colour filters / AI style-filter chooser gone from the camera). Styles now opens a filter row above the shutter (before/after box, name, credit badge, "View more" → full Styles library).
- Filters = rows in `public.styles` with `kind='filter'` (Supabase). App reads enabled filters directly from Supabase with the publishable key (RLS policy "anon read enabled filters"); images from the public `style-thumbs` bucket; cached offline; built-in Vivid fallback (`lib/services/filter_catalog.dart`).
- Admin panel: "Show as filter on camera" checkbox; JSON API field `kind` ("style"|"filter").
- Selected filter = PendingLook → after capture + Enhance, the normal Styles look path applies it (credit only on success).

## v11.54 (1.11.54+67) — Styles behind the four-dot, Photo | Video sheet, bolt credits
- Camera screen: the v11.53 styles strip is gone (file removed). The four-dot opens the quick menu bar (items now spread over the whole bar) plus ONE row above the mode strip: PHOTO (filters + photo styles) · VIDEO (play icon) · gold "More ›" → full Styles sheet. 9:16 cards; the row is planned to fill its width (`planQuickRow`).
- First run: gold sparkle NEW on the four-dot + "Styles are here" tooltip (pref `styles_hint_seen_v1154`; dismissed on tap or when the panel / sheet opens).
- Full Styles sheet: Photo | Video tabs (Photo first), category chips with icons, 2–3 column grid of big 9:16 cards. Categories = `styles.ui_category` (Supabase column, default 'new'; anon column grant added; admin "App category" select for photo + video; `/v1/styles` exposes it; never the prompt). Missing/unknown → New; empty New → all.
  (`category` already existed as the admin group label, so the new column is `ui_category`.)
- Video cards: photo first (last shot pre-selected, Take photo, gallery) → confirm sheet (preview, 480p/580p/720p, default 480p, "Make video · ⚡N"). Cards show "from ⚡N".
- Custom: Photo or Video first; Video → Image → video / Text → video (image asked only for image → video).
- Credits icon: gold lightning bolt PNG `assets/icons/credit_bolt.png` (+2.0x/3.0x); `CreditText` renders the `🪙` token in labels as the bolt. Credit values unchanged.
- Screens rendered offscreen: `flutter test tool_shots/v1154_shots_test.dart --update-goldens` → `tool_shots/out/`.

## v11.59 (1.11.59+72) — Sharp-source zoom, fail-closed microscope, offline handling, anchored Styles hint

- **Zoom (cheap phones, ladder flow):** the sharpest CLEAR, matching lower-zoom checkpoint photo,
  cut at the final area x1.6 and aligned to the final area (edge NCC, every offset; strict - no
  evidence = no match), becomes the AI's primary image; the final zoom is sent after it as the
  framing reference only (`kZoomSourcePrompt` / `ZOOM_SOURCE_PROMPT`). A source must match
  (>= 0.45), keep >= 96 px and be >= 1.15x sharper than the final at the same resolution.
  Past the phone's own clear limit (observed per phone, else optical) with no usable source the
  app does NOT fall back to final-only: "Hold steady and retake", no AI call, no credits.
  Blurry checkpoints no longer break the chain (subject checks compare clear photos only).
  Every zoom result is checked against its source area (structure + colours without a look) on
  the key path and the server (`zoom_source` form field, `no_sharp_source` 422). Zoom uses a safe
  prompt (keep design / identity / text; unrecoverable detail stays soft, no invented texture).
  Key-build overlay: `chain ... · last zoom <refs tried / sent>`; diagnostics reset per session.
- **Microscope:** missing 1.5x photo, failed lock, a comparison error or a mismatch after the
  retakes fail closed (no AI call, nothing charged); the old detect-only fallback is removed.
- **Offline:** short multi-endpoint TCP probe (not connectivity only) before Pro AI shutter,
  enhance, styles / custom and video; "Check your internet connection", no spinner, no charge.
  A watchdog cancels a running AI call within ~8 s when the network drops; DNS / socket errors
  are classified as network, not provider errors. Normal photo is untouched.
- **Styles are here hint:** anchored to the real four-dot button (measured after layout,
  re-measured on rotation / width change), clamped inside the camera area, tail points at it.

## v11.58 (1.11.58+71) — Coordinated microscope, background video, DSLR enhance, per-style models
- Microscope / Extreme / Ultra: the object is locked from a 1.5x shot (`lib/services/micro_lock.dart`, reused for 3 min while the frame still matches); higher zooms detect only a PART of that object ("{part} on the {object}"). Frame mismatch → "Hold steady" + automatic retake (up to 2). Prompts are material-aware (no hardcoded "cells"). Bad result → "Bad result? Refund ⚡N" on the preview (local-ledger builds).
- Video: ≤5 s → 8scale Wan, >5 s → Phosor MiniMax H3 Turbo (unchanged routing). Jobs run in the background with a system notification when done/failed; long jobs show "Usually ready in 15–20 min"; 30-min timeout cancels at the provider ("Your credits were refunded" — nothing is charged before delivery). Phosor result HTTP 202 = still running. "AI-generated" label replaces the MiniMax chip. Video style cards read credit_cost + samples.
- Enhance: one universal DSLR prompt for all modes (+ Portrait bokeh variant). Upload JPEG q100, no 1920 upscale (app + server).
- Camera class: macro low-end flag now comes from the camera classifier (`_cameraClass.lowEnd`).
- Styles model routing: `styles.model` (Supabase column, default 'klein'; filters 'custom'; anon grant). `klein` = FLUX Klein (user photo only), `runware_klein4b` = Runware FLUX.2 Klein 4B (for violent/bloody looks; env/dart-define `RUNWARE_API_KEY`), `custom` = the Custom model. Any failure / missing key → falls back to Custom. Admin style editor has a "Model" select; API field `model`.
- Vercel env added: VIDEO_API_KEY, PHOSOR_API_KEY, RUNWARE_API_KEY (sensitive). Admin redeployed (Vercel `ai-camera-admin`, bundle `deploy-v1158.zip`).
- Test APK: `--dart-define-from-file` (OPENROUTER_API_KEY, RUNWARE_API_KEY, VIDEO_API_KEY, PHOSOR_API_KEY) from a temp file deleted after the build; keys never committed.

## v11.57 (1.11.57+70) — No Free styles; video cards = last photo → Generate
- Free labels and the free-first library-style trial are gone. Every photo/video style card shows ⚡N (admin credit_cost). Apply button is always "Apply · ⚡N". Backend `decide_look` charges the style cost on every apply.
- Video style cards are image-to-video only: tap uses the last captured photo and opens the confirm sheet (9:16 preview, 480/580/720p default 480p, "Generate · ⚡N"). No Take photo / gallery / Take video. No photo → "Take a photo first". Text-to-video stays in Custom only.
- Admin redeployed (Vercel `ai-camera-admin`, bundle `deploy-v1157.zip`).

## v11.56 (1.11.56+69) — Save on style cards, one variation, Prompt, Custom window, real samples
- SAVE (bookmark) on style cards: Styles sheet grid (photo + video), look-screen strip, apply sheet ("Save"/"Saved"), video confirm sheet, AI Video preset grid. Saved styles go FIRST in their quick-row group (Photo / Video) in saved order, then defaults (no duplicates), then gold "More ›". Prefs `saved_styles_photo_v1156` / `saved_styles_video_v1156` (ids; removed styles ignored). The quick row scrolls horizontally (`lib/services/saved_styles.dart`).
- "4 variations" removed (toggle, 4× price, n=4 / top-up path in the app). Always one image; credit values unchanged. (Server `/v1/looks/apply` still accepts `variations` 1..4 for old builds; the app always sends 1.)
- Custom photo sheet: title + field "Prompt", hint "Write your prompt…", no suggestion chips.
- Custom card → Custom window directly (no "photo or video?"): segments "AI Photo" | "AI Video" (Photo tab → AI Photo, Video tab → AI Video). AI Video = previous custom video (image→video / text→video, 9:16/16:9, 5/8/10/15 s, provider resolutions).
- Real before/after samples: `styles.sample_before_url` / `sample_after_url` (nullable; video uses after only). Public bucket `style-samples`; prompt-free anon view `public.style_samples_public` (app reads it with the publishable key). `/v1/styles` exposes both fields. Admin style editor: upload/replace/remove BEFORE + AFTER (video: AFTER); API `POST /admin/api/styles/{id}/images` fields `sample_before`, `sample_after`, `remove_samples`. Cards show the AFTER image; the apply sheet shows a draggable before/after slider above the photo selection. Uploaded for germany_street, paris_eiffel, santorini, rainy_mumbai, studio_headshot.
- Admin redeployed (Vercel `ai-camera-admin`, bundle `deploy-v1156.zip`).

## v11.60 (1.11.60+73) — Calmer zoom preview, wide→close tracking, aligned zoom burst

No hardware validation yet (no physical device in the build loop): every number below is a
bound or a synthetic-test result, not a measured clarity gain on any phone.

- **Live preview (cheap phones):** no centre-AF pass per zoom step any more. One centre AF
  nudge only when the zoom has rested 1.2 s AND the camera itself reports out-of-focus
  (CONTROL_AF_STATE 5/6), at most once per 5 s, never over a tap/lock, back to continuous AF
  after 2.5 s (`zoomAfNudgeDue`). Metering region `clamp(0.5/digital, 0.10, 0.15)` of the
  camera frame (`meteringSizeForZoom`, was down to 0.05). Preview stays `ResolutionPreset.max`.
  The bright latch (dark scenes only) is unchanged.
- **Reference stills instead of per-checkpoint photos:** a full-res reference only when the zoom
  rested 0.7 s, gyro steady, tracked, view motion < 0.02, ≥1.5x the last reference, ≤ the
  camera's own max zoom, ≤3 per session, flash off (`shouldCaptureReference`).
- **Wide→close tracking (`zoom_tracker.dart`, `image_register.dart`):** analysis frames
  (upright 72-px-wide grey proxy of the whole camera frame, 3×3 box-averaged, every 250 ms) are
  registered to a keyframe with a similarity transform (pyramid NCC search seeded by the zoom
  ratio, then Huber-weighted Gauss–Newton; scored at matched pixel density). Transforms chain
  root→key→current; blurry frames never become keyframes and never reset the chain; 8 misses,
  implausible motion (scale ±35 % vs zoom, rotation > 8°), leaving the reference or a different
  subject → lost → references dropped (hint) → a shot needing a source fails closed (no AI
  call, nothing charged). Orientation ≠ portraitUp or aspect change → tracking off. Each
  reference stores its tracked view; at the shutter the final region is mapped cur→root→ref,
  cut at ×1.3 (native region decode) and must still pass the strict v11.59 `pickZoomSource`
  match + sharper check. No whole-frame-similarity fallback.
- **Zoom burst (`burst_merge.dart`):** digitally zoomed shots (digital > 1.2, region ≤ 3 MP) on
  cheap phones, Normal (offline too) and Pro AI in Zoom mode: 2–4 sequential stills within
  1.8 s (a capture > 0.7 s ends it), only the region + 7.5 % decoded (Android
  BitmapRegionDecoder + EXIF rotation; Dart fallback), merged in a killable isolate (6 s
  budget): anchor = sharpest; frames with other exposure (±10 %) or that do not register
  (median tile NCC < 0.85) left out; similarity warp; 16-px ghost tiles (anchor only); robust
  per-pixel weights from the anchor's noise σ; mild halo-clamped sharpen only after a real
  merge. An aligned multi-frame DENOISE merge, not super-resolution. Temp files deleted.
- The merged region / tracked source feed the existing v11.59 payload (source first, final
  framing only) for both the direct key and the server; no server change, same model/prompts.
- Tests: `test/v1160_test.dart` (synthetic scenes with known transforms).
