import 'dart:convert';

// ignore_for_file: constant_identifier_names
import 'zoom_range.dart' show formatZoom;
// v11 hidden Pro AI prompts — TEST-KEY BUILDS ONLY.
//
// Production (server) builds send only ids (mode / color_filter / subject);
// the server holds these prompts and they are editable at /admin/prompts.
// The embedded-key test build talks to OpenRouter directly, so it needs a
// copy. Mirrors enhance-server/prompts.py (parity test in test_server.py).
// Release builds (no key) never call these (guarded by AiConfig).

// v11.58: the Portrait variant of the universal DSLR prompt (= kPortraitEnhancePrompt).
const String kPortraitPrompt =
    'Enhance this photo so it looks like a portrait shot on a professional DSLR camera with a fast prime lens at a wide aperture. Recover and sharpen all the real detail of the main subject, making it crisp, clear and well-defined, with rich natural colours and clean contrast. Keep the main subject 100% sharp, including hair strands, fingers, fabric edges and outlines, and blur only the background with smooth, natural, depth-graded lens bokeh, with out-of-focus lights as soft round bokeh. Keep the same subject, shapes, framing, colours and light. Do not smooth, blur or give the subject a plastic look. Do not add new objects or change the scene. Keep the same people and faces exactly, with real skin and surface texture.';

/// v11.12 Macro level prompts (sent alone, one image call: the boxed
/// 2x / 3x / 4x step photos first, the zoomed crop last).
const String kMacroHintLine =
    'Detected: main subject {parent}; zoomed spot {part}.';
const String kMacroHintParentOnly = 'Detected: main subject {parent}.';
// v11.39 level prompts: short, positive, general (no {subject}, no detection).
/// v11.39: subject passed for Macro / Close / Microscope (no detection).
const String kMacroGeneralSubject = 'close-up';

/// v11.40: added when wider context photos are sent with a macro shot.
const String kMacroContextLine =
    'The earlier images only show the wider context, from the widest first; the last image is the final frame to enhance. Keep the final frame\'s composition and subject the same, and do not invent new objects.';

const String kMacroPrompt =
    'A natural close-up macro photograph of the last image: gently sharpen it and keep the soft, real fine texture that is already there, with a light, natural look that is clearly less intense than a microscope view. Keep the same framing, the same subject, the subject\'s own natural colours and soft natural light; do not add any new objects. Photorealistic.';
const String kMacroClosePrompt =
    'A real close-up macro photograph of this photo: keep the same framing and the same subject shape. Make it clearly sharp and crisp, remove blur and noise, and bring out the fine natural texture and tiny detail that is already there. Keep the subject\'s own natural colours and soft natural light. Photorealistic.';

/// v11.58 Microscope / Extreme / Ultra: material-aware (no hardcoded
/// "cells"). {spot} = the PART found at the shutter, {on_object} =
/// " on the <object locked at 1.5x>" (see [onObjectText]).
/// v11.47 Microscope: detect first, then TEXT ONLY at 100x ({spot}).
const String kMacroMicroscopePrompt =
    'A tiny area of {spot}{on_object} under a light microscope at 100x magnification, filling '
    'the frame. Show only the real fine structure of its own material up close, for example: '
    'painted metal shows paint grains, printing dots and light scratches; plastic shows fine '
    'moulding marks; fabric shows woven threads and fibres; paper shows pressed fibres; a '
    'leaf shows veins and tiny plant structure; skin shows pores and fine lines. Do not add '
    'anything this material would not really have. One single full-frame image, no text or '
    'labels. Photorealistic.';

/// v11.47: the old photo-based Microscope prompt (no spot detected).
const String kMacroMicroscopePhotoPrompt =
    'Based on the last photo: a real brightfield microscope photograph, strongly zoomed in on the centre of the frame, with a soft backlit glow, ultra-shallow depth of field with softly blurred edges, fine natural micro-structure and texture at high magnification, semi-transparent edges and the true colours of the subject. Keep the subject\'s own natural colours, and do not let the background colour tint the subject. Photorealistic.';

/// v11.18 Extreme: this line ALONE (no prefix / suffix / hint line).
const String kMacroExtremePrompt =
    'A tiny area of {spot}{on_object} under a light microscope at 1000x magnification, '
    'filling the frame. Show the very fine structure its own material would really have at '
    'this magnification, for example: painted metal shows paint pigment grains, printing dots '
    'and tiny scratches in the metal; plastic shows its fine surface grain; fabric shows '
    'single fibres; a leaf shows tiny plant structure. Do not add anything this material '
    'would not really have. One single full-frame image, no text or labels. Photorealistic.';

/// v11.20 Ultra (30x): electron microscope, whole prompt, crop only.
const String kMacroUltraPrompt =
    'Close-up of {spot}{on_object} under a scanning electron microscope at 2000x '
    'magnification. Show the true surface structure of its own material, for example: painted '
    'metal shows paint grains, coating cracks and fine scratches; plastic shows its moulded '
    'surface; fabric shows single fibres. Do not add anything this material would not really '
    'have. One single full-frame image, no text or labels. Photorealistic.';

const String kColorFilterTail =
    'Change only color and tone; keep faces, skin texture, shapes, '
    'content and composition exactly the same.';

const String kColorPrompt_vivid =
    'Apply an iPhone-style Vivid color look: natural but rich colors, '
    'slightly deeper contrast, clean whites, gently richer skies and '
    'foliage, and accurate natural skin tones; never oversaturated or '
    'neon.';

const String kColorPrompt_rich_contrast =
    'Apply a Rich Contrast look: deeper blacks, punchy but clean '
    'midtone contrast and rich natural color, with highlights kept '
    'intact.';

const String kColorPrompt_warm_gold =
    'Apply a Warm Gold look: golden-hour warmth, soft amber highlights, '
    'gently warm shadows and glowing but natural skin.';

const String kColorPrompt_cool_clean =
    'Apply a Cool Clean look: crisp neutral-cool white balance, clean '
    'whites, fresh blues and teals, and natural skin.';

const String kColorPrompt_cinematic =
    'Apply a Cinematic teal-orange grade: teal shadows and cool '
    'background tones, warm skin and highlights, filmic contrast with a '
    'soft highlight roll-off.';

const String kColorPrompt_film =
    'Apply a classic Film look: soft filmic contrast, slightly lifted '
    'blacks, a gentle warm-green cast and fine natural film grain.';

const String kColorPrompt_moody_dark =
    'Apply a Moody Dark look: darker exposure, deep shadows, muted '
    'desaturated colors and rich contrast, while keeping faces '
    'readable.';

const String kColorPrompt_soft_pastel =
    'Apply a Soft Pastel look: light airy exposure, low contrast and '
    'soft, desaturated pastel colors with gentle highlights.';

const String kColorPrompt_bright_airy =
    'Apply a Bright and Airy look: bright clean exposure, lifted '
    'shadows, soft whites and light fresh colors with natural skin.';

const String kColorPrompt_pro_bw =
    'Apply a professional black-and-white conversion: rich tonal range, '
    'deep blacks, clean whites, fine detail and natural skin tones in '
    'gray.';

const Map<String, String> kColorFilterPrompts = {
  'vivid': kColorPrompt_vivid,
  'rich_contrast': kColorPrompt_rich_contrast,
  'warm_gold': kColorPrompt_warm_gold,
  'cool_clean': kColorPrompt_cool_clean,
  'cinematic': kColorPrompt_cinematic,
  'film': kColorPrompt_film,
  'moody_dark': kColorPrompt_moody_dark,
  'soft_pastel': kColorPrompt_soft_pastel,
  'bright_airy': kColorPrompt_bright_airy,
  'pro_bw': kColorPrompt_pro_bw,
};

/// Same as prompts.sanitize_subject on the server.
String sanitizeSubject(String? raw) {
  var s = (raw ?? '').toLowerCase().replaceAll(RegExp(r"[^a-z0-9 ,&'-]+"), ' ');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.length > 40) s = s.substring(0, 40);
  return s.isEmpty ? 'the subject' : s;
}

/// Same as prompts.macro_zoom_text on the server.
String macroZoomText(double? zoom) {
  if (zoom == null || !zoom.isFinite || zoom < 1.5) return 'very close';
  return 'to ${formatZoom(zoom)}x';
}

const Map<String, List<String>> _kMicroWords = {
  'skin': [
    'skin',
    'face',
    'cheek',
    'forehead',
    'nose',
    'chin',
    'lip',
    'smile',
    'hand',
    'finger',
    'palm',
    'arm',
    'leg',
    'neck',
    'ear',
    'person',
    'human',
    'selfie',
  ],
  'eye': ['eye', 'iris', 'pupil', 'eyelash', 'lash'],
  'metal': [
    'coin',
    'metal',
    'steel',
    'silver',
    'gold',
    'brass',
    'copper',
    'iron',
    'money',
    'currency',
    'jewelry',
    'jewellery',
    'ring',
  ],
  'fabric': [
    'fabric',
    'cloth',
    'textile',
    'cotton',
    'wool',
    'denim',
    'silk',
    'bedsheet',
    'sheet',
    'shirt',
    'jeans',
    'linen',
    'thread',
    'knit',
    'towel',
    'carpet',
  ],
  'plant': [
    'leaf',
    'plant',
    'flower',
    'petal',
    'grass',
    'tree',
    'moss',
    'herb',
    'vegetation',
  ],
  'paper': [
    'paper',
    'document',
    'book',
    'page',
    'newspaper',
    'card',
    'notebook',
  ],
  'wood': ['wood', 'timber', 'plank', 'bark', 'furniture', 'table'],
  'hair': ['hair', 'fur', 'beard', 'eyebrow'],
  'food': [
    'food',
    'bread',
    'fruit',
    'vegetable',
    'rice',
    'sugar',
    'salt',
    'cake',
    'dish',
  ],
};

const Map<String, String> _kDescFallback = {
  'skin': 'human skin',
  'eye': 'a human eye',
  'metal': 'a metal surface',
  'fabric': 'fabric',
  'plant': 'a plant leaf',
  'paper': 'paper',
  'wood': 'wood',
  'hair': 'human hair',
  'food': 'food',
};

/// Same as prompts.fallback_description.
String fallbackDescription(String? subject) {
  final k = microKeyFor(subject);
  final f = _kDescFallback[k];
  if (f != null) return f;
  final s = sanitizeSubject(subject);
  return s == 'the subject' ? 'this surface' : s;
}

/// Same as prompts.micro_key_for: label → micro id (eye before skin).
String microKeyFor(String? subject) {
  final words = RegExp(
    r'[a-z]+',
  ).allMatches((subject ?? '').toLowerCase()).map((m) => m.group(0)!).toSet();
  for (final k in const [
    'eye',
    'hair',
    'skin',
    'metal',
    'fabric',
    'plant',
    'paper',
    'wood',
    'food',
  ]) {
    if (_kMicroWords[k]!.any(
      (w) => words.contains(w) || words.contains('${w}s'),
    )) {
      return k;
    }
  }
  return 'default';
}

/// A clear label: user pick, or a label that maps to a known subject.
bool isClearSubject(String? subject, {bool manual = false}) =>
    (subject ?? '').trim().isNotEmpty &&
    (manual || microKeyFor(subject) != 'default');

/// Level id → its prompt (sent alone); optional admin placeholders
/// {subject} {description} {level} {zoom} are filled. Same as the server.
String macroPrompt(
  String? subject, {
  String level = 'macro',
  double? zoom,
  String? part,
}) {
  if (level == 'extreme') {
    return deepPrompt(kMacroExtremePrompt, subject, part);
  }
  if (level == 'ultra') return deepPrompt(kMacroUltraPrompt, subject, part);
  if (level == 'microscope') {
    // v11.47: spot → 100x text prompt; none → the photo prompt.
    if (macroTextOnly(level, subject, part)) {
      return deepPrompt(kMacroMicroscopePrompt, subject, part); // v11.58 + object
    }
  }
  final (t, name) = switch (level) {
    'close' => (kMacroClosePrompt, 'Close Macro'),
    'microscope' => (kMacroMicroscopePhotoPrompt, 'Microscope'),
    'extreme' => (kMacroExtremePrompt, 'Extreme Microscope'),
    _ => (kMacroPrompt, 'Macro'),
  };
  var d = sanitizeDetected(subject); // v11.33: the box description as is
  if (d.isEmpty || d == 'the subject') d = fallbackDescription(subject);
  final body = t
      .replaceAll('{subject}', d)
      .replaceAll('{description}', d)
      .replaceAll('{level}', name)
      .replaceAll('{zoom}', macroZoomText(zoom));
  // v11.39: Macro / Close / Microscope prompts are general (no detected
  // subject, no "Detected:" line); an admin {subject} is still filled.
  return body;
}

/// v11.47 (same as prompts.macro_text_only): Extreme / Ultra with a spot or
/// subject; Microscope only with a detected spot ([part]).
bool macroTextOnly(String? level, String? subject, String? part) {
  // v11.49: a vague name (only look / colour words) is not a spot.
  if (level == 'microscope') {
    final p = sanitizeDetected(part);
    return p.isNotEmpty && !isVagueDetect(p);
  }
  final d = sanitizeDetected(part ?? subject);
  return (level == 'extreme' || level == 'ultra') &&
      d.isNotEmpty &&
      !isVagueDetect(d);
}

/// v11.15 cloud-detected text (≤8 words) → short safe text ('' if none).
String sanitizeDetected(String? raw) {
  final s = (raw ?? '').toLowerCase().replaceAll(
    RegExp(r"[^a-z0-9 ,&'-]+"),
    ' ',
  );
  final words = s.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  var out = words.take(8).join(' ');
  if (out.length > 80) out = out.substring(0, 80);
  return out.trim();
}

/// Same as prompts.macro_hint on the server.
String macroHint(String? parent, [String? part]) {
  final p = sanitizeDetected(parent);
  if (p.isEmpty || p == 'the subject') return '';
  final q = sanitizeDetected(part);
  if (q.isNotEmpty) {
    return kMacroHintLine.replaceAll('{parent}', p).replaceAll('{part}', q);
  }
  return kMacroHintParentOnly.replaceAll('{parent}', p);
}

const String kDetectModel = 'google/gemini-2.5-flash-lite';

/// v11.27: the shutter spot check uses the stronger flash model (the 1.5x
/// subject and step part checks stay on flash-lite).
const String kDetectSpotModel = 'google/gemini-2.5-flash';

/// v11.29: spot call budget (thinking off) and the overall shutter limit.
const int kDetectSpotMaxTokens = 200;
const Duration kSpotTimeout = Duration(seconds: 10);

/// v11.27 last-resort part when no check found one (never the object alone).
const String kSpotDefaultPart = 'surface detail';

/// v11.22: never describe what a screen shows (all detection prompts).
const String kDetectDeviceRule =
    'If the object is a phone, tablet, laptop, monitor or TV, name '
    'the device itself (e.g. black mobile phone screen), never what'
    ' is shown on its screen (people, clothes, images, text).';

/// v11.22: centre object + other visible objects (JSON).
const String kDetectSubjectPrompt =
    'Name the object at the CENTER of this photo: colour + object (+ material or visible side), at most 8 plain words (e.g. brown human eye, white styrofoam, black mobile phone back with camera). Also list the other clearly visible objects (colour + object, at most 5). Also give fill: how much of the photo the centre object fills, from 0 to 1 (1 = fills or overflows it), and whole: true if the whole object is visible. If the object is a phone, tablet, laptop, monitor or TV, name the device itself (e.g. black mobile phone screen), never what is shown on its screen (people, clothes, images, text). Reply only as JSON {"main": "...", "others": ["..."], "fill": 0.5, "whole": true}.';

/// v11.22: which known object + part is boxed, still in the scene?
const String kDetectPartPrompt =
    'Photo 1 is a wider view; main object: {parent}; objects in it: {objects}. Photo 2 is zoomed; the red box marks where the user is zooming. Describe what is in the red box: the whole object if all of it is visible (e.g. eye); several parts if several are visible (e.g. eye, iris and eyelashes); one part only if that part alone fills the box (e.g. iris). Include its colour. Also give fill: how much of photo 2 the main object fills, from 0 to 1 (1 = fills or overflows it), and whole: true if the whole object is visible in photo 2. If the object is a phone, tablet, laptop, monitor or TV, name the device itself (e.g. black mobile phone screen), never what is shown on its screen (people, clothes, images, text). Reply only as JSON {"object": "<one of the objects, or a new one>", "part": "<at most 8 words: colour + what is in the box>", "fill": 0.5, "whole": true, "in_scene": true}. in_scene is false only if photo 2 shows a completely different place than photo 1.';

/// v11.22 shutter spot check (object + part).
const String kDetectSpotPrompt =
    'Photo 1 is the overview; main object: {subject}; objects in it: {objects}. Photo 2 is a closer view; the small red box marks exactly where the camera is zoomed. Describe what is in the red box: the whole object if all of it is visible (e.g. eye); several parts if several are visible (e.g. eye, iris and eyelashes); one part only if that part alone fills the box (e.g. iris). Include its colour. If the object is a phone, tablet, laptop, monitor or TV, name the device itself (e.g. black mobile phone screen), never what is shown on its screen (people, clothes, images, text). Reply only as JSON {"object": "...", "part": "<at most 8 words: colour + what is in the box>", "in_scene": true/false}.';

/// v11.33 shutter: ONE check on the box area (= server DETECT_BOX_PROMPT).
/// v11.49: the NAME of the object / material (not its look). Same text as
/// prompts.DETECT_BOX_PROMPT.
const String kDetectBoxPrompt =
    'Name what is in this photo: give the common name of the object or material, with its part or kind if you can tell (for example: leaf vein, cotton fabric, sugar crystals, human skin, tree bark). Give the name only, not its colour, texture or look. If the object is a phone, tablet, laptop, monitor or TV, name the device itself (e.g. black mobile phone screen), never what is shown on its screen (people, clothes, images, text). Reply only as JSON {"part": "<at most 6 words: common name of the object or material>", "clear": true}. clear is false if the photo is too blurry or unclear to tell what it is.';

/// v11.49: one line in front when a wider view goes first (2 images).
const String kDetectBoxWideLine =
    'The first image is a wider view, the second is the zoomed centre; name what is in the second image. ';

/// v11.49: appearance-only words (a name made only of these is vague).
const Set<String> kVagueDetectWords = {
  'surface',
  'texture',
  'textured',
  'pattern',
  'patterned',
  'circles',
  'circle',
  'dots',
  'dot',
  'shapes',
  'shape',
  'spots',
  'spot',
  'background',
  'lines',
  'line',
  'lots',
  'many',
  'small',
  'tiny',
  'large',
  'big',
  'some',
  'of',
  'with',
  'and',
  'a',
  'an',
  'the',
  'in',
  'on',
  'area',
  'close-up',
  'closeup',
  'detail',
  'details',
  'object',
  'thing',
  'material',
  'image',
  'photo',
  'picture',
  'blurry',
  'blur',
  'unclear',
  'unknown',
  'light',
  'dark',
  'bright',
  'shiny',
  'smooth',
  'rough',
  'round',
  'grainy',
  'abstract',
  'white',
  'black',
  'gray',
  'grey',
  'red',
  'green',
  'blue',
  'yellow',
  'orange',
  'purple',
  'pink',
  'brown',
  'beige',
  'silver',
  'gold',
  'golden',
  'colorful',
  'colourful',
  'multicolored',
  'transparent',
  'clear',
};

/// v11.49 (= prompts.is_vague_detect): empty, or only appearance / colour
/// words (no object or material name) → treat as "nothing found".
bool isVagueDetect(String? name) {
  final words = (name ?? '')
      .toLowerCase()
      .split(RegExp(r"[^a-z0-9'-]+"))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return true;
  return words.every(kVagueDetectWords.contains);
}

/// {"part", "clear"} → (description, clear) (= server parse_box_reply).
(String, bool) parseBoxReply(String? text) {
  final j = _jsonObj(text);
  if (j == null) {
    final d = cleanDetected(text);
    return (d, d.isNotEmpty);
  }
  final p = j['part'];
  final d = cleanDetected(p is String ? p : '');
  return (d, d.isNotEmpty && j['clear'] != false);
}

/// Same as prompts.clean_detected: reply → at most [maxWords] plain words.
String cleanDetected(String? text, {int maxWords = kDetectMaxWords}) {
  final lines = (text ?? '')
      .split(RegExp(r'[\r\n]+'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty);
  if (lines.isEmpty) return '';
  var t = lines.first.replaceFirst(
    RegExp(r'^(answer|subject|spot|part)\s*:\s*', caseSensitive: false),
    '',
  );
  t = t.replaceAll(RegExp(r"[^A-Za-z0-9 ,&'-]+"), ' ');
  var out = t
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .take(maxWords)
      .join(' ');
  out = out.replaceAll(RegExp(r"^[ ,\-'&]+|[ ,\-'&]+$"), '').toLowerCase();
  if (out.length > 80) out = out.substring(0, 80).trim();
  return out;
}

/// v11.21: accept and trim long replies (cap, never reject).
const int kDetectMaxWords = 10;

/// Same as prompts.parse_part_reply: (sameSubject or null, part).
(bool?, String) parsePartReply(String? text) {
  final m = RegExp(r'\{.*\}', dotAll: true).firstMatch(text ?? '');
  if (m == null) return (null, '');
  try {
    final j = jsonDecode(m.group(0)!);
    if (j is! Map) return (null, '');
    final same = j['same_subject'];
    final part = j['part'];
    return (
      same is bool ? same : null,
      cleanDetected(part is String ? part : ''),
    );
  } catch (_) {
    return (null, '');
  }
}

/// v11.20 Extreme / Ultra whole prompt (same as prompts.deep_prompt):
/// {spot} = shutter spot (colour + part); no spot → subject; neither →
/// "This". The broad subject is NOT added when a spot exists.
String deepPrompt(String template, String? subject, String? part) {
  var subj = sanitizeDetected(subject);
  if (subj == 'the subject') subj = '';
  var spot = sanitizeDetected(part);
  if (spot.isEmpty) spot = subj.isEmpty ? 'this' : subj;
  // v11.28: capital only when the spot starts the sentence.
  if (template.trimLeft().startsWith('{spot}')) {
    spot = spot[0].toUpperCase() + spot.substring(1);
  }
  return template
      .replaceAll('{subject}', subj.isEmpty ? 'this' : subj)
      .replaceAll('{on_object}', onObjectText(subj, spot))
      .replaceAll('{spot}', spot)
      .trim();
}

/// v11.58 (same as prompts.on_object_text): " on the locked object" after
/// the part, or '' when there is no object, it is the general "close-up" or
/// the part already names it.
String onObjectText(String? object, String? spot) {
  final o = sanitizeDetected(object);
  final sp = sanitizeDetected(spot);
  if (o.isEmpty || o == 'the subject' || o == kMacroGeneralSubject || o == 'this' || o == sp || sp.contains(o)) {
    return '';
  }
  return ' on the $o';
}

// ---------------------------------------------------------------------------
// v11.22 multiple objects (same as prompts.py parse_subject_reply & co.)
// ---------------------------------------------------------------------------

/// At most this many "other" objects are kept from the 1.5x reply.
const int kDetectMaxOthers = 5;

/// v11.22: room for the JSON with other objects (v11.21: 60).
const int kDetectJsonMaxTokens = 120;

Map<dynamic, dynamic>? _jsonObj(String? text) {
  final m = RegExp(r'\{.*\}', dotAll: true).firstMatch((text ?? '').trim());
  if (m == null) return null;
  try {
    final j = jsonDecode(m.group(0)!);
    return j is Map ? j : null;
  } catch (_) {
    return null;
  }
}

/// {"main": str, "others": [str]} → (main, others); plain text → (main, []).
(String, List<String>) parseSubjectReply(String? text) {
  final j = _jsonObj(text);
  if (j == null) {
    final t = (text ?? '').trim();
    if (t.startsWith('{')) {
      // Truncated JSON: take the "main" value if present.
      final m = RegExp(r'"main"\s*:\s*"([^"]*)').firstMatch(t);
      return (m == null ? '' : cleanDetected(m.group(1)), <String>[]);
    }
    return (cleanDetected(text), <String>[]);
  }
  final raw = j['main'] ?? j['name'] ?? j['subject'];
  final main = cleanDetected(raw is String ? raw : '');
  final others = <String>[];
  final list = j['others'];
  if (list is List) {
    for (final o in list) {
      final c = cleanDetected(o is String ? o : '');
      if (c.isNotEmpty && c != main && !others.contains(c)) others.add(c);
    }
  }
  return (main, others.take(kDetectMaxOthers).toList());
}

/// {"object", "part", "in_scene"} → (object, part, inScene); legacy
/// same_subject accepted as inScene; plain text → ('', part, null).
(String, String, bool?) parseObjectPartReply(String? text) {
  final j = _jsonObj(text);
  if (j == null) return ('', cleanDetected(text), null);
  final o = j['object'], p = j['part'];
  final ins = j.containsKey('in_scene') ? j['in_scene'] : j['same_subject'];
  return (
    cleanDetected(o is String ? o : ''),
    cleanDetected(p is String ? p : ''),
    ins is bool ? ins : null,
  );
}

/// Known objects for the prompt: "main; other; other".
String objectsText(String? main, List<String> others) {
  final out = <String>[];
  for (final o in [main ?? '', ...others]) {
    final c = sanitizeDetected(o);
    if (c.isNotEmpty && c != 'the subject' && !out.contains(c)) out.add(c);
  }
  return out.isEmpty ? 'the subject' : out.join('; ');
}

/// The known object [obj] names (exact or contained), else null.
String? matchKnownObject(String? obj, List<String> known) {
  final o = (obj ?? '').trim().toLowerCase();
  if (o.isEmpty) return null;
  for (final k in known) {
    final kk = k.trim().toLowerCase();
    if (kk.isNotEmpty && (kk == o || o.contains(kk) || kk.contains(o))) {
      return k;
    }
  }
  return null;
}

/// Spot used in prompts = object + part (object not repeated).
/// v11.27 spot sent to the image prompt: always object + part. A spot
/// without a part falls back to the last 2x–5x step part; no object →
/// the locked main subject.
String finalSpotText({
  String? object,
  String? part,
  String? fallbackPart,
  String? parent,
}) {
  var p = cleanDetected(part);
  if (p.isEmpty) p = cleanDetected(fallbackPart);
  var o = cleanDetected(object);
  if (o.isEmpty) o = cleanDetected(parent);
  if (p.isEmpty || p == o) p = kSpotDefaultPart;
  return spotText(o, p);
}

String spotText(String? obj, String? part) {
  final o = cleanDetected(obj), p = cleanDetected(part);
  if (o.isEmpty) return p;
  if (p.isEmpty || p.startsWith(o) || p.contains(o)) return p.isEmpty ? o : p;
  return cleanDetected('$o $p', maxWords: kDetectMaxWords + 6);
}
