"""Prompt pieces — mirrors ai_camera/lib/services/prompt_builder.dart and
models/style_preset.dart. The LOCKED prompt wording must never change; all
extra instructions are appended as separate sentences."""
from __future__ import annotations

import math
import json
import re
from typing import Optional

# v11.58: ONE universal DSLR enhance prompt for every normal, zoom and
# low-light photo (replaces the old base + zoom emphasis / HIGH_ZOOM_CLARITY /
# ZOOM_CLEAN / night sentences). Mirrors kUniversalEnhancePrompt in Dart.
UNIVERSAL_ENHANCE_PROMPT = (
    'Enhance this photo so it looks like it was shot on a professional DSLR camera with a high-quality lens. Recover and sharpen all the real detail present in the photo, making everything crisp, clear and well-defined, with rich natural colours and clean contrast. Keep the same subject, shapes, framing, colours and light. Do not smooth, blur or give it a plastic look. Do not add new objects or change the scene. Keep the same people and faces exactly, with real skin and surface texture.'
)
# v11.58 Portrait variant (used INSTEAD of the universal prompt).
PORTRAIT_ENHANCE_PROMPT = (
    'Enhance this photo so it looks like a portrait shot on a professional DSLR camera with a fast prime lens at a wide aperture. Recover and sharpen all the real detail of the main subject, making it crisp, clear and well-defined, with rich natural colours and clean contrast. Keep the main subject 100% sharp, including hair strands, fingers, fabric edges and outlines, and blur only the background with smooth, natural, depth-graded lens bokeh, with out-of-focus lights as soft round bokeh. Keep the same subject, shapes, framing, colours and light. Do not smooth, blur or give the subject a plastic look. Do not add new objects or change the scene. Keep the same people and faces exactly, with real skin and surface texture.'
)
LOCKED_ENHANCE_PROMPT = UNIVERSAL_ENHANCE_PROMPT  # legacy name

CONTEXT_IMAGE_SENTENCE = (
    "Use the second image only to understand the scene; enhance and upscale "
    "only the first image, do not invent new content."
)

# v11.9: the 2nd image is a sharp low-zoom snapshot with the zoomed region boxed.
CONTEXT_BOXED_SENTENCE = (
    "The second image is a sharp, lower-zoom photo of the same scene taken just before; the red "
    "box marks exactly where the first image is. Use it only to understand what the subject "
    "really is; enhance and upscale only the first image, do not draw the box and do not "
    "invent new content."
)

# v11.9 high-zoom clarity rule (Pro AI zoom beyond the optical lens).
HIGH_ZOOM_CLARITY = (
    'Make what is already visible clear and clean, keeping every shape, letter and detail exactly as it is; leave parts that cannot be read as they are.'
)

MAX_CUSTOM_PROMPT_CHARS = 200

# AI filters (preview screen) — same ids/prompts as the app's kStylePresets.
FILTER_PROMPTS = {
    "studio": "Apply a clean professional studio portrait look: even soft lighting, "
    "neutral color grade, crisp detail, subtle contrast.",
    "cinematic": "Apply a cinematic color grade: slight teal-orange tone, deeper "
    "contrast, subtle filmic vignette feel, dramatic but natural.",
    "wedding": "Apply a warm romantic wedding look: soft highlights, gentle warm "
    "tones, flattering skin, elegant soft glow without changing faces.",
    "linkedin": "Apply a polished LinkedIn headshot look: clean professional "
    "lighting, natural skin, moderate contrast, trustworthy corporate "
    "finish.",
    "night": "Apply night/low-light recovery: lift shadows carefully, reduce "
    "noise, keep natural colors, slight cool ambient balance.",
    "soft_beauty": "Apply soft beauty polish: gentle skin smoothing that keeps "
    "pores/texture, soft light, slight brightness, natural colors — do "
    "not reshape face.",
}

# v11 Pro AI mode prompts — DEFAULTS. Hidden from users; the live text comes
# from the admin-editable store (mode_prompts.py, /admin/prompts). Mirrored in
# the app's lib/services/mode_prompts.dart for the test-key build only.
#
# Night (Pro AI): the phone already merged a burst and tone-mapped it to a
# NATURAL night look; the AI must keep it night and never invent structure
# (v10 test: a near-black shot came back with invented pillars / ground).
NIGHT_PROMPT = (  # v11.48: general, no scene-specific words
    "A natural night photograph of the last image: gently reduce noise, recover shadow detail and keep the real lighting and mood. Keep every object, light and colour as in the photo and do not add anything new. Photorealistic."
)

PORTRAIT_PROMPT = PORTRAIT_ENHANCE_PROMPT  # v11.58: admin key 'portrait' = the variant

# v11.6 Macro + AI Microscope (two images). The app sends the FIRST image =
# a sharp crop, at real pixels, of the small region the user zoomed into
# (captured at the optical limit, never upscaled) and the SECOND image = the
# full sharp frame with that region outlined by a red box. Three
# admin-editable level prompts; each must contain {subject}; {level} and
# {zoom} (e.g. "20x") are optional.
MACRO_PREFIX = (
    "First study the photos in order (1.5x, 2x, 3x, 4x; the red box marks where the user is "
    "zooming) and work out exactly what the boxed spot is: what object, which part of it (e.g. "
    "skin of the back of the hand, eyelid, eyeball, cheek, phone screen, phone camera lens, "
    "fabric), and what is visible on it (hairs, pores, lines, pixels, scratches). Then show that "
    "exact spot, keeping it the same material and subject. "
)
MACRO_SUFFIX = (
    " Uneven, irregular natural texture and color variation, unretouched raw photo, "
    "high-frequency micro-detail. Photorealistic."
)
MACRO_HINT_LINE = "Detected: main subject {parent}; zoomed spot {part}."
MACRO_HINT_PARENT_ONLY = "Detected: main subject {parent}."
# v11.33 level prompts: the shutter box description goes in {subject}.
# Macro / Close get the crop; Microscope the crop LAST (+ an optional wider
# hint photo first). Depth rises by level.
MACRO_PROMPT = (
    "A natural close-up macro photograph of the last image: gently sharpen it and keep the soft, real fine texture that is already there, with a light, natural look that is clearly less intense than a microscope view. Keep the same framing, the same subject, the subject's own natural colours and soft natural light; do not add any new objects. Photorealistic."
)
MACRO_CLOSE_PROMPT = (
    "A real close-up macro photograph of this photo: keep the same framing and the same subject shape. Make it clearly sharp and crisp, remove blur and noise, and bring out the fine natural texture and tiny detail that is already there. Keep the subject's own natural colours and soft natural light. Photorealistic."
)
# v11.58 Microscope / Extreme / Ultra: material-aware (never hardcoded
# "cells"); {spot} = the PART detected at the shutter, {on_object} = " on the
# <object locked at 1.5x>" (empty when the part already names it).
# v11.47 Microscope: detect first, then TEXT ONLY at 100x (admin key
# macro_microscope). No spot → the photo prompt below (fallback).
MACRO_MICROSCOPE_PROMPT = (
    "A tiny area of {spot}{on_object} under a light microscope at 100x magnification, filling "
    "the frame. Show only the real fine structure of its own material up close, for example: "
    "painted metal shows paint grains, printing dots and light scratches; plastic shows fine "
    "moulding marks; fabric shows woven threads and fibres; paper shows pressed fibres; a "
    "leaf shows veins and tiny plant structure; skin shows pores and fine lines. Do not add "
    "anything this material would not really have. One single full-frame image, no text or "
    "labels. Photorealistic."
)
# v11.47: the old photo-based Microscope prompt, used only when no spot.
MACRO_MICROSCOPE_PHOTO_PROMPT = (
    'Based on the last photo: a real brightfield microscope photograph, strongly zoomed in on the centre of the frame, with a soft backlit glow, ultra-shallow depth of field with softly blurred edges, fine natural micro-structure and texture at high magnification, semi-transparent edges and the true colours of the subject. Keep the subject\'s own natural colours, and do not let the background colour tint the subject. Photorealistic.'
)

# v11.11 Extreme: a SIMPLE prompt, sent alone with only the centre spot
# (upscaled). {description} = one line from the cheap vision "describe" step
# (fallback: the label). No framing / truth / colour rules, no colour match.
# v11.18: Extreme is ONLY this line (no prefix / suffix / hint line).
MACRO_EXTREME_PROMPT = (
    "A tiny area of {spot}{on_object} under a light microscope at 1000x magnification, "
    "filling the frame. Show the very fine structure its own material would really have at "
    "this magnification, for example: painted metal shows paint pigment grains, printing dots "
    "and tiny scratches in the metal; plastic shows its fine surface grain; fabric shows "
    "single fibres; a leaf shows tiny plant structure. Do not add anything this material "
    "would not really have. One single full-frame image, no text or labels. Photorealistic."
)
# v11.20 Ultra (30x): electron microscope (may come out greyscale — intended).
MACRO_ULTRA_PROMPT = (
    "Close-up of {spot}{on_object} under a scanning electron microscope at 2000x "
    "magnification. Show the true surface structure of its own material, for example: painted "
    "metal shows paint grains, coating cracks and fine scratches; plastic shows its moulded "
    "surface; fabric shows single fibres. Do not add anything this material would not really "
    "have. One single full-frame image, no text or labels. Photorealistic."
)

_DESC_FALLBACK = {
    "skin": "human skin", "eye": "a human eye", "metal": "a metal surface", "fabric": "fabric",
    "plant": "a plant leaf", "paper": "paper", "wood": "wood", "hair": "human hair",
    "food": "food",
}


def fallback_description(subject: Optional[str]) -> str:
    """Label → plain description when the describe step fails."""
    k = _micro_id(subject)
    if k in _DESC_FALLBACK:
        return _DESC_FALLBACK[k]
    s = sanitize_subject(subject)
    return s if s != "the subject" else "this surface"


_MICRO_WORDS = {
    "skin": ("skin", "face", "cheek", "forehead", "nose", "chin", "lip", "smile", "hand", "finger",
             "palm", "arm", "leg", "neck", "ear", "person", "human", "selfie"),
    "eye": ("eye", "iris", "pupil", "eyelash", "lash"),
    # (v11.10 live labels: Face / Lips → skin, Eyebrow → hair)
    "metal": ("coin", "metal", "steel", "silver", "gold", "brass", "copper", "iron", "money",
              "currency", "jewelry", "jewellery", "ring"),
    "fabric": ("fabric", "cloth", "textile", "cotton", "wool", "denim", "silk", "bedsheet",
               "sheet", "shirt", "jeans", "linen", "thread", "knit", "towel", "carpet"),
    "plant": ("leaf", "plant", "flower", "petal", "grass", "tree", "moss", "herb", "vegetation"),
    "paper": ("paper", "document", "book", "page", "newspaper", "card", "notebook"),
    "wood": ("wood", "timber", "plank", "bark", "furniture", "table"),
    "hair": ("hair", "fur", "beard", "eyebrow"),
    "food": ("food", "bread", "fruit", "vegetable", "rice", "sugar", "salt", "cake", "dish"),
}


def _micro_id(subject: Optional[str]) -> str:
    s = (subject or "").lower()
    words = set(re.findall(r"[a-z]+", s))
    for k in ("eye", "hair", "skin", "metal", "fabric", "plant", "paper", "wood", "food"):
        if any(w in words or (w + "s") in words for w in _MICRO_WORDS[k]):
            return k
    return "default"


MACRO_LEVELS = {
    # level id → (admin prompt key, display name)
    "macro": ("macro", "Macro"),
    "close": ("macro_close", "Close Macro"),
    "microscope": ("macro_microscope", "Microscope"),
    "extreme": ("macro_extreme", "Extreme Microscope"),
    "ultra": ("macro_ultra", "Ultra Electron Microscope"),
}
# v11.20: crop only + whole-prompt levels.
MACRO_DEEP_LEVELS = ("extreme", "ultra")
# v11.47: levels that go text-only when a spot is detected.
MACRO_TEXT_LEVELS = ("microscope", "extreme", "ultra")


def macro_text_only(level, subject=None, part=None) -> bool:
    """v11.47: Extreme / Ultra with a spot or subject; Microscope only with
    a detected spot (part)."""
    if level == "microscope":
        p = sanitize_detected(part or "")
        return bool(p) and not is_vague_detect(p)
    d = sanitize_detected(part or subject or "")
    return level in MACRO_DEEP_LEVELS and bool(d) and not is_vague_detect(d)
# Levels whose prompt is sent alone (no locked enhance prompt in front).
MACRO_ALONE_LEVELS = ("macro", "close", "microscope", "extreme", "ultra")  # v11.12: all sent alone
MACRO_PROMPT_KEYS = tuple(k for k, _ in MACRO_LEVELS.values())


def macro_level_for_zoom(zoom: float) -> str:
    """Same as Dart macroLevelFor (v11.20): Macro ≤5x, Close 6x, Microscope
    12x, Extreme 21x, Ultra 30x; in between → nearest band (midpoints)."""
    z = round((zoom or 0) * 10) / 10
    if z >= 25.5:
        return "ultra"
    if z >= 16.5:
        return "extreme"
    if z >= 9.0:
        return "microscope"
    if z >= 5.5:
        return "close"
    return "macro"


# Premium color filters (Pro AI "AI final"). Free on-device LUT in Normal.
COLOR_FILTER_TAIL = (
    "Change only color and tone; keep faces, skin texture, shapes, content and composition "
    "exactly the same."
)
COLOR_FILTER_PROMPTS = {
    "vivid": "Apply an iPhone-style Vivid color look: natural but rich colors, slightly deeper "
    "contrast, clean whites, gently richer skies and foliage, and accurate natural skin tones; "
    "never oversaturated or neon.",
    "rich_contrast": "Apply a Rich Contrast look: deeper blacks, punchy but clean midtone "
    "contrast and rich natural color, with highlights kept intact.",
    "warm_gold": "Apply a Warm Gold look: golden-hour warmth, soft amber highlights, gently "
    "warm shadows and glowing but natural skin.",
    "cool_clean": "Apply a Cool Clean look: crisp neutral-cool white balance, clean whites, "
    "fresh blues and teals, and natural skin.",
    "cinematic": "Apply a Cinematic teal-orange grade: teal shadows and cool background tones, "
    "warm skin and highlights, filmic contrast with a soft highlight roll-off.",
    "film": "Apply a classic Film look: soft filmic contrast, slightly lifted blacks, a gentle "
    "warm-green cast and fine natural film grain.",
    "moody_dark": "Apply a Moody Dark look: darker exposure, deep shadows, muted desaturated "
    "colors and rich contrast, while keeping faces readable.",
    "soft_pastel": "Apply a Soft Pastel look: light airy exposure, low contrast and soft, "
    "desaturated pastel colors with gentle highlights.",
    "bright_airy": "Apply a Bright and Airy look: bright clean exposure, lifted shadows, soft "
    "whites and light fresh colors with natural skin.",
    "pro_bw": "Apply a professional black-and-white conversion: rich tonal range, deep blacks, "
    "clean whites, fine detail and natural skin tones in gray.",
}

MODES = ("photo", "portrait", "night", "macro")

# Admin-editable prompt keys → default text.
DEFAULT_MODE_PROMPTS = {
    "night": NIGHT_PROMPT,
    "portrait": PORTRAIT_PROMPT,
    "macro": MACRO_PROMPT,
    "macro_close": MACRO_CLOSE_PROMPT,
    "macro_microscope": MACRO_MICROSCOPE_PROMPT,
    "macro_extreme": MACRO_EXTREME_PROMPT,
    "macro_ultra": MACRO_ULTRA_PROMPT,
    **{f"filter:{k}": v for k, v in COLOR_FILTER_PROMPTS.items()},
}

_SUBJECT_RE = re.compile(r"[^a-z0-9 ,&'-]+")


def sanitize_subject(raw: Optional[str]) -> str:
    """Macro subject label from on-device image labeling → short, safe text."""
    s = _SUBJECT_RE.sub(" ", (raw or "").lower())
    s = re.sub(r"\s+", " ", s).strip()[:40]
    return s or "the subject"


def macro_zoom_text(zoom: Optional[float]) -> str:
    """"to 20x" style text for {zoom}; "" when unknown."""
    if zoom is None or not math.isfinite(zoom) or zoom < 1.5:
        return "very close"
    return f"to {format_zoom(zoom)}x"


def sanitize_detected(raw: Optional[str]) -> str:
    """v11.15 cloud-detected text (≤8 words) → short safe text; '' if none."""
    s = _SUBJECT_RE.sub(" ", (raw or "").lower())
    words = re.sub(r"\s+", " ", s).strip().split(" ")
    return " ".join(w for w in words[:8] if w)[:80].strip()


def macro_hint(parent: Optional[str], part: Optional[str] = None) -> str:
    """v11.15 hint line; '' when no parent was detected."""
    p = sanitize_detected(parent)
    if not p or p == "the subject":
        return ""
    q = sanitize_detected(part)
    if q:
        return MACRO_HINT_LINE.replace("{parent}", p).replace("{part}", q)
    return MACRO_HINT_PARENT_ONLY.replace("{parent}", p)


def deep_prompt(template: str, subject: Optional[str] = None,
                part: Optional[str] = None) -> str:
    """v11.20 Extreme / Ultra whole prompt. {spot} = shutter spot (colour +
    part); no spot → subject; neither → "This". The broad subject is NOT
    added when a spot exists. Optional admin {subject}."""
    subj = sanitize_detected(subject)
    if subj == "the subject":
        subj = ""
    spot = sanitize_detected(part) or subj or "this"
    if template.lstrip().startswith("{spot}"):  # v11.28: capital only at the start
        spot = spot[0].upper() + spot[1:]
    t = template.replace("{subject}", subj or "this")
    t = t.replace("{on_object}", on_object_text(subj, spot))
    return t.replace("{spot}", spot).strip()


def on_object_text(obj: Optional[str], spot: Optional[str]) -> str:
    """v11.58: " on the <locked object>" after the part, or "" when there is
    no object, it is the general "close-up" or the part already names it."""
    o = sanitize_detected(obj)
    sp = sanitize_detected(spot)
    if not o or o in ("the subject", "close-up", "this") or o == sp or o in sp:
        return ""
    return f" on the {o}"


def macro_prompt(template: str, subject: Optional[str] = None, level: str = "macro",
                 zoom: Optional[float] = None, part: Optional[str] = None,
                 **_ignored) -> str:
    """v11.15: level prompt (sent alone) + the "Detected: ..." line from the
    cloud detection (parent at 1x, part at the step photos)."""
    if level in MACRO_DEEP_LEVELS:
        return deep_prompt(template, subject, part)
    if level == "microscope":
        # v11.47: spot → 100x text prompt; none → the photo prompt.
        if macro_text_only(level, subject, part):
            if "{spot}" not in (template or ""):
                template = MACRO_MICROSCOPE_PROMPT  # old saved photo prompt
            return deep_prompt(template, subject, part)  # v11.58: + locked object
        template = MACRO_MICROSCOPE_PHOTO_PROMPT
    name = MACRO_LEVELS.get(level, MACRO_LEVELS["macro"])[1]
    desc = sanitize_detected(subject)  # v11.33: the box description as is
    if not desc or desc == "the subject":
        desc = fallback_description(subject)
    t = (template.replace("{subject}", desc)
         .replace("{description}", desc)
         .replace("{level}", name).replace("{zoom}", macro_zoom_text(zoom)))
    # v11.39: Macro / Close / Microscope prompts are general — no detected
    # subject and no "Detected:" line (an admin {subject} is still filled).
    return t


# v11.15: Macro subject detection (cheap cloud vision, free for the user).
DETECT_MODEL = "google/gemini-2.5-flash-lite"
# v11.27: the shutter spot check uses the stronger flash model.
DETECT_SPOT_MODEL = "google/gemini-2.5-flash"
DETECT_SPOT_MAX_TOKENS = 200  # v11.29 (thinking off)
# v11.22: never describe what a screen shows (all detection prompts).
DETECT_DEVICE_RULE = (
    "If the object is a phone, tablet, laptop, monitor or TV, name the device itself "
    "(e.g. black mobile phone screen), never what is shown on its screen (people, "
    "clothes, images, text)."
)
# v11.32: describe the box (whole object / several parts / one part) +
# how much of the frame the object fills (level unlock).
DETECT_SUBJECT_PROMPT = "Name the object at the CENTER of this photo: colour + object (+ material or visible side), at most 8 plain words (e.g. brown human eye, white styrofoam, black mobile phone back with camera). Also list the other clearly visible objects (colour + object, at most 5). Also give fill: how much of the photo the centre object fills, from 0 to 1 (1 = fills or overflows it), and whole: true if the whole object is visible. If the object is a phone, tablet, laptop, monitor or TV, name the device itself (e.g. black mobile phone screen), never what is shown on its screen (people, clothes, images, text). Reply only as JSON {\"main\": \"...\", \"others\": [\"...\"], \"fill\": 0.5, \"whole\": true}."
DETECT_PART_PROMPT = "Photo 1 is a wider view; main object: {parent}; objects in it: {objects}. Photo 2 is zoomed; the red box marks where the user is zooming. Describe what is in the red box: the whole object if all of it is visible (e.g. eye); several parts if several are visible (e.g. eye, iris and eyelashes); one part only if that part alone fills the box (e.g. iris). Include its colour. Also give fill: how much of photo 2 the main object fills, from 0 to 1 (1 = fills or overflows it), and whole: true if the whole object is visible in photo 2. If the object is a phone, tablet, laptop, monitor or TV, name the device itself (e.g. black mobile phone screen), never what is shown on its screen (people, clothes, images, text). Reply only as JSON {\"object\": \"<one of the objects, or a new one>\", \"part\": \"<at most 8 words: colour + what is in the box>\", \"fill\": 0.5, \"whole\": true, \"in_scene\": true}. in_scene is false only if photo 2 shows a completely different place than photo 1."
DETECT_SPOT_PROMPT = "Photo 1 is the overview; main object: {subject}; objects in it: {objects}. Photo 2 is a closer view; the small red box marks exactly where the camera is zoomed. Describe what is in the red box: the whole object if all of it is visible (e.g. eye); several parts if several are visible (e.g. eye, iris and eyelashes); one part only if that part alone fills the box (e.g. iris). Include its colour. If the object is a phone, tablet, laptop, monitor or TV, name the device itself (e.g. black mobile phone screen), never what is shown on its screen (people, clothes, images, text). Reply only as JSON {\"object\": \"...\", \"part\": \"<at most 8 words: colour + what is in the box>\", \"in_scene\": true/false}."


# v11.33: ONE shutter check on the box area (describe, not one forced part).
# v11.49: the NAME of the object / material (not its look).
DETECT_BOX_PROMPT = (
    "Name what is in this photo: give the common name of the object or material, with its part or kind if you can tell (for example: leaf vein, cotton fabric, sugar crystals, human skin, tree bark). Give the name only, not its colour, texture or look. " + DETECT_DEVICE_RULE +
    ' Reply only as JSON {"part": "<at most 6 words: common name of the object or material>", "clear": true}. clear is false if the photo is too blurry or unclear to tell what it is.'
)
# v11.49: one line in front when a wider view goes first (2 images).
DETECT_BOX_WIDE_LINE = "The first image is a wider view, the second is the zoomed centre; name what is in the second image. "

VAGUE_DETECT_WORDS = {
    "surface", "texture", "textured", "pattern", "patterned", "circles",
    "circle", "dots", "dot", "shapes", "shape", "spots", "spot", "background",
    "lines", "line", "lots", "many", "small", "tiny", "large", "big", "some",
    "of", "with", "and", "a", "an", "the", "in", "on", "area", "close-up",
    "closeup", "detail", "details", "object", "thing", "material", "image",
    "photo", "picture", "blurry", "blur", "unclear", "unknown", "light",
    "dark", "bright", "shiny", "smooth", "rough", "round", "grainy", "abstract",
    "white", "black", "gray", "grey", "red", "green", "blue", "yellow",
    "orange", "purple", "pink", "brown", "beige", "silver", "gold",
    "golden", "colorful", "colourful", "multicolored", "transparent", "clear",
}


def is_vague_detect(name) -> bool:
    """v11.49 (= Dart isVagueDetect): empty, or only appearance / colour
    words (no object or material name) → treat as nothing found."""
    words = [w for w in re.split(r"[^a-z0-9'-]+", (name or "").lower()) if w]
    return not words or all(w in VAGUE_DETECT_WORDS for w in words)


def parse_box_reply(text: Optional[str]) -> tuple[str, bool]:
    """v11.33 {"part", "clear"} → (description, clear). Plain text →
    (cleaned text, True when not empty)."""
    j = _json_obj(text)
    if j is None:
        d = clean_detected(text)
        return d, bool(d)
    part = j.get("part")
    d = clean_detected(part if isinstance(part, str) else "")
    clear = j.get("clear")
    return d, bool(d) and clear is not False


DETECT_MAX_WORDS = 10  # v11.21: cap (never reject) long replies
DETECT_MAX_TOKENS = 120  # v11.22: JSON with objects (v11.21: 60)


def clean_detected(text: Optional[str], max_words: int = DETECT_MAX_WORDS) -> str:
    """Model reply → first non-empty line, quotes/markdown stripped, at most
    [max_words] plain words; '' only when nothing usable."""
    lines = [l.strip() for l in re.split(r"[\r\n]+", text or "") if l.strip()]
    if not lines:
        return ""
    t = re.sub(r"^(answer|subject|spot|part)\s*:\s*", "", lines[0], flags=re.I)
    t = re.sub(r"[^A-Za-z0-9 ,&'-]+", " ", t)
    words = t.split()[:max_words]
    return " ".join(words).strip(" ,-'&").lower()[:80].strip()


def parse_part_reply(text: Optional[str]) -> tuple[Optional[bool], str]:
    """{"same_subject": bool, "part": str} (code fences tolerated)."""
    t = (text or "").strip()
    m = re.search(r"\{.*\}", t, re.S)
    if not m:
        return None, ""
    try:
        j = json.loads(m.group(0))
    except Exception:  # noqa: BLE001
        return None, ""
    same = j.get("same_subject")
    same = same if isinstance(same, bool) else None
    part = j.get("part")
    return same, clean_detected(part if isinstance(part, str) else "")


def _json_obj(text: Optional[str]):
    m = re.search(r"\{.*\}", (text or "").strip(), re.S)
    if not m:
        return None
    try:
        j = json.loads(m.group(0))
    except Exception:  # noqa: BLE001
        return None
    return j if isinstance(j, dict) else None


def parse_subject_reply(text: Optional[str]) -> tuple[str, list[str]]:
    """v11.22 {"main": str, "others": [str]} → (main, others); plain text →
    (cleaned first line, [])."""
    j = _json_obj(text)
    if j is None:
        t = (text or "").strip()
        if t.startswith("{"):
            # Truncated JSON: take the "main" value if present.
            m = re.search(r'"main"\s*:\s*"([^"]*)', t)
            return (clean_detected(m.group(1)) if m else ""), []
        return clean_detected(text), []
    main = j.get("main") or j.get("name") or j.get("subject")
    main = clean_detected(main if isinstance(main, str) else "")
    others: list[str] = []
    raw = j.get("others")
    if isinstance(raw, list):
        for o in raw:
            c = clean_detected(o if isinstance(o, str) else "")
            if c and c != main and c not in others:
                others.append(c)
    return main, others[:DETECT_MAX_OTHERS]


DETECT_MAX_OTHERS = 5


def parse_object_part_reply(text: Optional[str]) -> tuple[str, str, Optional[bool]]:
    """v11.22 {"object", "part", "in_scene"} → (object, part, in_scene);
    legacy same_subject accepted as in_scene; plain text → ("", part, None)."""
    j = _json_obj(text)
    if j is None:
        return "", clean_detected(text), None
    obj = j.get("object")
    part = j.get("part")
    ins = j.get("in_scene", j.get("same_subject"))
    return (clean_detected(obj if isinstance(obj, str) else ""),
            clean_detected(part if isinstance(part, str) else ""),
            ins if isinstance(ins, bool) else None)


def objects_text(main: Optional[str], others: Optional[list]) -> str:
    """Known objects for the prompt: "main; other; other"."""
    out: list[str] = []
    for o in [main or ""] + list(others or []):
        c = sanitize_detected(o)
        if c and c != "the subject" and c not in out:
            out.append(c)
    return "; ".join(out) or "the subject"


def match_known_object(obj: Optional[str], known: list) -> Optional[str]:
    """The known object [obj] names (exact or word-contained), else None."""
    o = (obj or "").strip().lower()
    if not o:
        return None
    for k in known:
        kk = (k or "").strip().lower()
        if kk and (kk == o or kk in o or o in kk):
            return k
    return None


def spot_text(obj: Optional[str], part: Optional[str]) -> str:
    """Spot used in prompts = object + part (no repeated object)."""
    o = clean_detected(obj)
    p = clean_detected(part)
    if not o:
        return p
    if not p or p.startswith(o) or o in p:
        return p or o
    return clean_detected(f"{o} {p}", max_words=DETECT_MAX_WORDS + 6)


# AI looks (v9 style library + "Describe a change…"). NOT the enhance prompt:
# looks deliberately change clothes / backdrop, so they get their own
# identity-preserving wrapper. Mirrors lib/services/prompt_builder.dart.
LOOK_IDENTITY_PROMPT = (
    "Edit this real photo of the person or people in the first image. Keep "
    "every person's face, identity, facial features, skin tone, age, body "
    "shape, hair and expression exactly the same; the result must clearly be "
    "the same real people, photorealistic, never a cartoon, painting or "
    "different person."
)
LOOK_REFERENCE_SENTENCE = (
    "Use the additional reference image(s) only as a guide for the requested "
    "look (outfit, place, style); never copy faces or identity from them."
)
LOOK_TAIL_SENTENCE = (
    "Change only what the request asks for, match lighting and perspective "
    "so the result looks like a real photo, and keep hands and body natural."
)


def format_zoom(z: float) -> str:
    """Same as Dart formatZoom: >=10 → integer, else 1 decimal without .0."""
    if z >= 10:
        return str(int(math.floor(z + 0.5)))
    s = f"{z:.1f}"
    return s[:-2] if s.endswith(".0") else s


def zoom_emphasis_level(over: float) -> int:
    if not math.isfinite(over) or over <= 1.05:
        return 0
    if over <= 2.0:
        return 1
    if over <= 4.0:
        return 2
    return 3


def zoom_sentence(zoom: float, optical_limit: float) -> str:
    limit = max(1.0, optical_limit)
    over = zoom / limit if (math.isfinite(zoom) and zoom > 0) else 1.0
    z, o = format_zoom(zoom), format_zoom(over)
    lvl = zoom_emphasis_level(over)
    if lvl == 0:
        return ""
    if lvl == 1:
        return (f"The first image is a {z}x zoom, about {o}x beyond the phone's "
                "optical lens; gently recover fine detail softened by digital zoom.")
    if lvl == 2:
        return (f"The first image is a {z}x zoom, about {o}x beyond the phone's "
                "optical lens; carefully recover fine detail, edges and textures "
                "lost to digital zoom while staying faithful to what is visible.")
    return (f"The first image is a heavy {z}x digital zoom, about {o}x "
            "beyond the phone's optical lens; recover as much real detail as "
            "possible (edges, textures, text) strictly from what is visible, "
            "and prefer a clean natural result over invented detail.")


def high_zoom_clarity(zoom: float, optical_limit: float) -> bool:
    """Clarity rule from >2x beyond the optical lens (zoom emphasis ≥ 2)."""
    limit = max(1.0, optical_limit or 1.0)
    over = zoom / limit if (math.isfinite(zoom) and zoom > 0) else 1.0
    return zoom_emphasis_level(over) >= 2


QUALITY_SENTENCES = {
    "hd": "",
    "full_hd": "Target a crisp Full HD result with clean fine detail.",
    "ultra_hd": "Target a very detailed Ultra HD result with crisp fine texture.",
    "4k": "Target a maximum-detail 4K result with crisp fine texture throughout.",
}


# Tiny safety list for custom "Describe a change…" prompts (v9.1). No
# relevance checks — users may type anything; the model's own refusals cover
# the rest. Mirrors the app's custom_prompt_policy.dart.
BLOCKED_CUSTOM_PATTERNS = [
    r"\b(nude|nudes|naked|nudity|topless|bottomless|undress\w*|unclothed|strip(ped|ping)?\s+(off|naked|down))\b",
    r"\b(without|no|remove|take off|taking off)\s+(her |his |my |the |their )?(clothes|clothing|dress|shirt|top|bra|underwear)\b",
    r"\b(sex|sexual|sexy|porn\w*|nsfw|erotic|explicit|lingerie|seductive)\b",
    r"\b(face\s*-?\s*swap\w*|swap\w*\s+(my |his |her |the |their )?faces?|deep\s*-?\s*fake\w*|replace\s+(my |his |her |the |their )?face)\b",
    r"\b(gore|gory|decapitat\w*|behead\w*|dismember\w*|mutilat\w*|corpse|dead body|blood\s*(splatter|soaked|bath)|bloody wound)\b",
]
_BLOCKED_RE = [re.compile(p) for p in BLOCKED_CUSTOM_PATTERNS]


def blocked_custom_prompt(raw: Optional[str]) -> bool:
    s = (raw or "").lower()
    return any(r.search(s) for r in _BLOCKED_RE)


_REFUSAL_RE = re.compile(
    r"moderation|safety|content[_ ]policy|policy_violation|refus|not allowed to|cannot help|can.t help"
    r"|unable to (create|generate|edit)", re.I)


# v10: custom "Describe a change" text that only asks for a generic quality
# boost. Mirrors the app's isEnhanceOnlyPrompt (enhance_policy.dart).
_ENHANCE_CORE = {
    "enhance", "enhanced", "enhancement", "enhancer", "clear", "clearer", "clarity", "hd", "fullhd",
    "uhd", "sharp", "sharper", "sharpen", "sharpness", "quality", "improve", "improved", "upscale",
    "upscaled", "upscaling", "4k", "8k", "2k", "deblur", "unblur", "crisp", "crisper", "resolution",
    "highres", "hq", "detail", "details", "detailed", "focus", "denoise", "retouch", "blurry", "blurred",
}
_ENHANCE_FILLER = {
    "make", "it", "the", "photo", "image", "picture", "pic", "pics", "more", "please", "pls", "plz",
    "this", "a", "an", "and", "look", "looks", "fix", "blur", "remove", "reduce",
    "noise", "better", "high", "higher", "definition", "super", "very", "ultra", "full", "in", "to",
    "of", "my", "me", "bit", "little", "lot", "add", "increase", "quality", "version", "best", "good",
    "nice", "clean", "cleaner", "up", "with", "less", "bright", "brighter", "brightness", "colors",
    "colours", "color", "colour", "pixel", "pixels", "convert", "into", "k", "x", "mode", "res",
}


def enhance_only_custom_prompt(raw: Optional[str]) -> bool:
    s = (raw or "").lower()
    s = re.sub(r"full\s*hd", "fullhd", s)
    s = re.sub(r"high[\s-]*res(olution)?", "highres", s)
    words = [w for w in re.split(r"[^a-z0-9]+", s) if w]
    if not words:
        return False
    core = False
    for w in words:
        if w in _ENHANCE_CORE:
            core = True
        elif w not in _ENHANCE_FILLER:
            return False
    return core


def looks_like_refusal(text: str) -> bool:
    return bool(_REFUSAL_RE.search(text or ""))


def sanitize_custom_prompt(raw: Optional[str]) -> str:
    s = re.sub(r"\s+", " ", raw or "").strip()
    return s[:MAX_CUSTOM_PROMPT_CHARS]


def build_prompt(
    *,
    has_context: bool = False,
    zoom: float = 1.0,
    optical_limit: float = 1.0,
    tier: str = "hd",
    style_prompt: Optional[str] = None,
    custom_prompt: Optional[str] = None,
    night: bool = False,
    mode_prompt: Optional[str] = None,
    color_prompt: Optional[str] = None,
    context_boxed: bool = False,
    portrait_prompt: Optional[str] = None,
) -> str:
    """v11.58: universal DSLR prompt (or the Portrait variant given as
    ``portrait_prompt``, used INSTEAD of the base) + optional mode sentence
    (Macro levels) + context, quality, AI-filter style, colour look, user
    request. ``zoom`` / ``optical_limit`` / ``night`` no longer change the
    text (one prompt for normal, zoom and low-light photos)."""
    pp = (portrait_prompt or "").strip()
    parts = [pp or UNIVERSAL_ENHANCE_PROMPT]
    mp = (mode_prompt or "").strip()
    if mp:
        parts.append(mp)
    if has_context:
        parts.append(CONTEXT_BOXED_SENTENCE if context_boxed else CONTEXT_IMAGE_SENTENCE)
    qs = QUALITY_SENTENCES.get(tier, "")
    if qs:
        parts.append(qs)
    st = (style_prompt or "").strip()
    if st:
        parts.append(f"Style: {st}")
    cl = (color_prompt or "").strip()
    if cl:
        parts.append(f"Color look: {cl} {COLOR_FILTER_TAIL}")
    cp = sanitize_custom_prompt(custom_prompt)
    if cp:
        parts.append(
            "Additional user request (apply only while keeping every face, "
            f"identity and the real scene intact): {cp}"
        )
    return " ".join(parts)


def build_look_prompt(*, style_prompt: Optional[str] = None,
                      custom_prompt: Optional[str] = None,
                      has_references: bool = False) -> str:
    """Prompt for a style apply (hidden admin prompt) or a custom change."""
    parts = [LOOK_IDENTITY_PROMPT]
    if has_references:
        parts.append(LOOK_REFERENCE_SENTENCE)
    st = (style_prompt or "").strip()
    if st:
        parts.append(f"Requested look: {st}")
    cp = sanitize_custom_prompt(custom_prompt)
    if cp:
        parts.append(f"Requested change: {cp}")
    parts.append(LOOK_TAIL_SENTENCE)
    return " ".join(parts)


# v11.26 cost cut: credits per Macro level (mirrors kMacroLevelCredits in Dart).
# v11.33: credits by Macro quality + level (admin /admin/macro-credits can
# override; mirrors kMacroCredits in Dart). 2K is shown locked ("Coming
# soon"): its credits are kept here but it can't be bought yet.
MACRO_QUALITIES = ("hd", "full_hd", "2k")
MACRO_LOCKED_QUALITIES = ("2k",)
DEFAULT_MACRO_CREDITS = {
    "hd": {"macro": 4, "close": 4, "microscope": 5, "extreme": 2, "ultra": 2},
    "full_hd": {"macro": 5, "close": 5, "microscope": 6, "extreme": 3, "ultra": 3},
    "2k": {"macro": 13, "close": 13, "microscope": 14, "extreme": 10, "ultra": 10},
}
MACRO_LEVEL_CREDITS = DEFAULT_MACRO_CREDITS["hd"]  # legacy name (HD row)
MACRO_CROP_LONG = 1536
MACRO_STEP_LONG = 768


def merge_macro_credits(override=None) -> dict:
    """Defaults + an admin override {quality: {level: credits}} (bad
    values ignored)."""
    out = {q: dict(v) for q, v in DEFAULT_MACRO_CREDITS.items()}
    for q, row in (override or {}).items():
        if q not in out or not isinstance(row, dict):
            continue
        for lvl, c in row.items():
            if lvl in MACRO_LEVELS and isinstance(c, int) and not isinstance(c, bool) and 0 < c <= 100:
                out[q][lvl] = c
    return out


def macro_credits_for(level, quality="hd", table=None):
    t = table or DEFAULT_MACRO_CREDITS
    row = t.get(quality) or t["hd"]
    return row.get(level, row["macro"])


def macro_input_plan(level):
    """(max step photos, crop long side or None = unchanged)."""
    if level == "microscope":
        return 1, MACRO_CROP_LONG  # v11.33: crop + ONE hint photo
    if level in ("extreme", "ultra"):
        return 2, None  # v11.40: ≤2 wider context photos when no spot text
    return 2, MACRO_CROP_LONG  # v11.40: crop + ≤2 wider context photos


# v11.40: added when wider context photos are sent with a macro shot.
MACRO_CONTEXT_LINE = (
    "The earlier images only show the wider context, from the widest first; the last image is the final frame to enhance. Keep the final frame's composition and subject the same, and do not invent new objects."
)


# v11.30 100x zoom ladder (cheap phones): boxed lower-zoom reference photos
# first, the final photo (to enhance) last. Hidden; the app sends only a flag.
# v11.34 high zoom (2x+, all phones): keep the photo, raise its own detail.
ZOOM_CLEAN_PROMPT = UNIVERSAL_ENHANCE_PROMPT  # v11.58: zoom uses the universal prompt
# Cheap phones with matching checkpoint photos: final photo first, then refs.
ZOOM_LADDER_REFS_LINE = (
    "The other images are clearer close-up views of the same area; use them for detail."
)
ZOOM_LADDER_PROMPT = ZOOM_CLEAN_PROMPT + " " + ZOOM_LADDER_REFS_LINE
ZOOM_LADDER_MAX_REFS = 3
ZOOM_LADDER_LONG = 768        # reference crops
ZOOM_LADDER_MAIN_LONG = 1536  # v11.31: the final photo (or native if smaller)


def zoom_ladder_prompt(style_prompt: str | None = None, color_prompt: str | None = None,
                       refs: bool = True) -> str:
    parts = [ZOOM_LADDER_PROMPT if refs else ZOOM_CLEAN_PROMPT]
    if style_prompt and style_prompt.strip():
        parts.append(f"Style: {style_prompt.strip()}")
    if color_prompt and color_prompt.strip():
        parts.append(f"Color look: {color_prompt.strip()} {COLOR_FILTER_TAIL}")
    return " ".join(parts)


def parse_fill(text: Optional[str]) -> tuple[Optional[float], Optional[bool]]:
    """v11.32 {"fill": 0..1, "whole": bool} from a detection reply."""
    j = _json_obj(text)
    if not isinstance(j, dict):
        return None, None
    f, w = j.get("fill"), j.get("whole")
    try:
        fill = None if f is None or isinstance(f, bool) else max(0.0, min(1.0, float(f)))
    except (TypeError, ValueError):
        fill = None
    return fill, (w if isinstance(w, bool) else None)
