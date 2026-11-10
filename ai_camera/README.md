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

## v11.40 (1.11.40+53) — Macro: manual zoom, soft hints, context photos
- Shutter is never blocked by the centre box check (all levels); Extreme / Ultra no longer refuse when the spot is unclear (they send the zoomed view instead of the spot text).
- Box check now reads the visible zoomed area (matches the on-screen box), loosened; soft hints only: "Hold steady", "Tap to focus", "Put your subject inside the box – zoom will do the rest". "Move closer" / "Zoom in more" / "Too close" removed.
- Level chips no longer auto-zoom; macro zoom is manual 1x–5x (chips 1x · 2x · 3x · 5x, pinch capped at min(5x, device max)).
- Macro / Close / Extreme / Ultra take up to 2 wider context photos (1x / 2x below the shot zoom, 768 px) at the shutter, sent as extra references with a general context line. Fail-safe; no extra credit. Microscope keeps its hint photo.
- Server (repo only): macro_input_plan allows 2 context photos for Macro / Close / Extreme / Ultra; context line; Extreme / Ultra without a spot send the photo. Needs a redeploy.

## v11.41 (1.11.41+54) — Macro zoom to 10x, no background colour tint
- Macro levels: manual zoom 1x–10x (min(10x, device max)); chips 1x · 2x · 3x · 5x · 10x (only within the device max).
- Macro / Close-up / Microscope prompts (app + server defaults) add: "Keep the subject's own natural colours, and do not let the background colour tint the subject." Admin-panel prompt overrides still win over these defaults.
- Colour match (app + server): the regional 8×8 chroma correction is capped at ±10 (0..255) per area, so a strong background colour can't be pushed onto a small subject. Global chroma spread gain stays ≤1.0 (v11.39).

## v11.42 (1.11.42+55) — framing-true macro, colour match safety, stability
- A. Macro / Close-up prompts keep the same framing and subject shape (no "strongly zoomed … filling the frame"); Microscope unchanged. Context line now: "The extra small photos only show the wider view around this photo; keep this photo's framing and subject the same."
- B. Colour match (app + server): skipped when the result's average Cb/Cr differs from the original by > 12; otherwise the overall Y/Cb/Cr shift is capped at ±10 (regional ±10 from v11.41).
- C. Context photos are cut to ~2.5x the main shot's area (and must be ≥1.5x wider) — genuinely wider.
- D. Framing check only when reference photos were sent (cheap-phone 100x ladder); single-photo zoom (e.g. moon at 83x) is never refused by it. Test builds: a rejected result stays viewable ("Rejected: framing 0.26 — tap to view"), still refunded.
- E. Stability: OIS + preview EIS (API 33+) via Camera2 interop where offered (re-applied after manual exposure is cleared); analysis stream ~640x480 (preview/photo stay max); analysis throttled to ~6–7/s above 5x; chip taps ramp ~200 ms; ruler 0.5x steps 10x–30x; gyro "Hold steady" above 10x and the shutter waits up to 1.5 s for ~0.3 s of stillness; Settings → "Camera debug overlay" (test builds) shows UI fps, analysis size/rate, gyro and stabilisation.

## v11.43 (1.11.43+56) — trial: Macro / Close save only the centre box
- Macro and Close shots at 5x or less are cropped to the on-screen centre box (50% x 50%) before the colour clean-up and the AI call; the saved photo and before/after are the box area. Preview note: "Saved: centre box area".
- Above 5x (and for Microscope / Extreme / Ultra) the full visible frame is sent as in v11.42.
- Context photos are measured against the box area (still at least 1.5x wider, else skipped). App-only change; no server change.

## v11.44 (1.11.44+57) — Macro zooms on the main lens only
- In Macro (all levels, back camera) the camera stays at zoomRatio 1.0 (the main wide lens) and every zoom above 1x is a centre digital crop of the main sensor, so the phone never switches to the ultra-wide or telephoto mid-zoom. Leaving Macro restores the normal multi-lens zoom. Normal and Pro AI non-macro modes are unchanged.

## v11.45 (1.11.45+58) — back to v11.42 Macro (lens lock + box crop removed)
- Macro (all levels) uses the phone's normal multi-lens zoom again (zoomRatio-based, telephoto lenses where the phone switches), as before v11.44 (main-lens-only Macro zoom removed). The v11.43 centre-box crop is also removed: Macro sends and saves the full visible zoomed view, as v11.42; the centre box stays as a visual guide for the hints.

## v11.46 (1.11.46+59) — Macro step photos + exposure + Normal zoom
- All five Macro levels: at the shutter the final photo at zoom Z is taken, then step photos at each of 2x / 5x / 10x strictly below Z (none for Z ≤ 2x), zoom restored to Z. Toast: "Capturing 2x… 5x… final". A failed step is skipped. Sent to the AI widest first, final photo last (existing v11.40 context mechanism). Step photos replace the Microscope hint photo when present.
- Level start zoom rises with level: Macro 2x, Close 3x, Microscope 4x, Extreme 6x, Ultra 8x (capped at min(10x, device max)); chips still change it.
- Macro prompt lighter than Microscope; new context line (earlier images = wider context, last = final frame). App + server same. Microscope prompt unchanged.
- Pro Zoom mode going dark: the far-bright latch (manual 1/250 s ISO 100) engaged on any lamp/window at ≥5x when the rest of the frame was only "darker than 80" — normal for a lit room. Now only on a really dark background (rest ≤ 35) and a small spot (≤ 8%). Entering Zoom mode and any Normal/Pro switch restore plain auto exposure (manual cleared, AE unlocked, tap/AE point cleared, mode EV).
- Normal (non-Pro) camera zoom reaches the phone's own max (ruler + 10/30/100 ticks). Pro without Zoom mode keeps 10x.

## v11.47 (1.11.47+60) — Microscope = detect + 100x text-only
- Microscope only: at the shutter the final photo + step photos are scored on-device (Laplacian variance of the same centre area, 256 px grey copy); the sharpest goes to the same cheap spot detection Extreme uses. Spot found → text-only generation (no photo sent) with "A tiny area of {spot} under a light microscope at 100x magnification…" (admin key macro_microscope, default updated; an old saved prompt without {spot} falls back to the new default). No spot → the previous photo-based Microscope flow (old prompt kept as MACRO_MICROSCOPE_PHOTO_PROMPT / kMacroMicroscopePhotoPrompt).
- Text-only Microscope skips chroma clean-up and colour match (like Extreme). Server version 11.1.47.

## v11.48 (1.11.48+61)
- Night prompt general (app + server): "A natural night photograph of the last image: gently reduce noise, recover shadow detail and keep the real lighting and mood. …".
- Merges: Night/burst alignment adds a quarter-size coarse search and a per-quadrant check (tilt / local motion → frame dropped), per-pixel ghost rejection (|v − ref| > 48 left out); fewer than 2 good frames → sharpest frame alone. HDR: fine-level misalignment check, frames with > 30 % ghost pixels dropped, only the reference left → the 0 EV frame alone.
- HDR tone lighter: weight blur proxy/24 (was /96, halos), 35 % of the 0 EV frame kept everywhere (less contrast / saturation boost).
- Pro Night 4 frames (≤1 s hold); Normal Night unchanged (8–15).
- Pro AI: no HDR mode (strip + route → single capture). Normal: no Macro.
- Macro level chips collapsed (selected + arrow; arrow expands; pick collapses).
- Pro AI: no four-dot menu at all (no filters / styles / AI filters / timer there; Macro default HD). Normal keeps the menu minus Flash.
- Universal Flash button in the top bar (all modes, Off/Auto/On; Night cycles the Night flash). Tapping Flash turns the Macro torch off (no conflict).

## v11.49 (1.11.49+62)
- HDR removed from the app (Normal too); a saved/old HDR mode → Photo; no "Try HDR" tip. Night keeps its merge.
- Macro level chips never move the zoom (no start zoom, no Microscope 2x hint-photo zoom-out; 1x chip = no level, zoom stays). Only the macro max cap remains.
- Detect (Microscope / Extreme / Ultra): prompt asks for the common NAME of the object/material (≤6 words, not colour/texture); the widest step photo (≥1.5x wider) goes first as an overview + the sharpest centre-box patch (all three levels, tie → final); vague names (only look/colour words, isVagueDetect / is_vague_detect) = nothing found → photo fallback; result line "Detected: …" / "Not detected, used photo"; detect images 768 px (was 512).
