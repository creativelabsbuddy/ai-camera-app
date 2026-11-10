import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'live_policies.dart' show LiveFace;

import 'mode_prompts.dart' show matchKnownObject, cleanDetected, finalSpotText;
import 'scene_suggest.dart';
import 'zoom_info.dart';

/// v11 Macro (Pro AI only): distance guide, zoom chips per device, burst.
enum MacroGuideState { closer, tooClose, ready }

/// Guide thresholds (Laplacian variance on the ~640 px analysis frame).
const double kMacroSharpReady = 40;
const double kMacroSharpBlur = 12;

/// Centre / border sharpness ratio: ≥ ready → shallow depth of field
/// (close subject, blurred surround); ≤ far → everything equally sharp.
const double kMacroRatioReady = 2.2;
const double kMacroRatioFar = 1.5;

/// Instant guide decision from one frame (no history). Pure → tested.
///
/// * centre blurry → the subject is closer than the lens can focus
///   ("Too close · move back");
/// * centre sharp and surround much softer → macro distance ("Ready");
/// * centre sharp and surround just as sharp → still far ("Move closer").
MacroGuideState macroGuideFor({
  required double sharpness,
  required double edgeSharpness,
}) {
  if (sharpness < kMacroSharpBlur) return MacroGuideState.tooClose;
  final ratio = sharpness / math.max(1.0, edgeSharpness);
  if (sharpness >= kMacroSharpReady && ratio >= kMacroRatioReady) {
    return MacroGuideState.ready;
  }
  if (ratio <= kMacroRatioFar || sharpness < kMacroSharpReady) {
    return MacroGuideState.closer;
  }
  // In between: keep asking to get a little closer.
  return MacroGuideState.closer;
}

/// Hysteresis: a new state must repeat [needed] frames before it shows
/// (AF hunting / hand shake don't make the chip flicker).
class MacroGuide {
  MacroGuide({this.needed = 2});
  final int needed;
  MacroGuideState _shown = MacroGuideState.closer;
  MacroGuideState? _candidate;
  int _count = 0;

  MacroGuideState get state => _shown;

  MacroGuideState update({
    required double sharpness,
    required double edgeSharpness,
  }) {
    final s = macroGuideFor(sharpness: sharpness, edgeSharpness: edgeSharpness);
    if (s == _shown) {
      _candidate = null;
      _count = 0;
      return _shown;
    }
    if (s == _candidate) {
      _count++;
    } else {
      _candidate = s;
      _count = 1;
    }
    if (_count >= needed) {
      _shown = s;
      _candidate = null;
      _count = 0;
    }
    return _shown;
  }

  void reset() {
    _shown = MacroGuideState.closer;
    _candidate = null;
    _count = 0;
  }
}

/// Suggested working distance in cm (rounded to 5 cm, 5–20).
int macroTargetCm(double? minFocusCm) {
  final m = minFocusCm ?? 7;
  final t = (m * 1.4 / 5).round() * 5;
  return t.clamp(5, 20);
}

String macroGuideText(MacroGuideState s, {double? minFocusCm}) => switch (s) {
  MacroGuideState.closer => 'Move closer · ~${macroTargetCm(minFocusCm)} cm',
  MacroGuideState.tooClose => 'Too close · move back',
  MacroGuideState.ready => 'Ready',
};

// ---------------------------------------------------------------------------
// Zoom chips 2x … 10x, mapped per device (v11.1: up to 10x)
// ---------------------------------------------------------------------------

/// v11.20: after 5x only the level chips: 6x Close, 12x Micro, 21x
/// Extreme, 30x Ultra.
const kMacroChips = [
  1.0, 1.5, 2.0, 3.0, 4.0, 5.0, 6.0, 12.0, 21.0, 30.0, //
];
const double kMacroMinZoom = 1.0;
const double kMacroMaxZoom = 30.0;

/// Lens facts used for macro (back cameras).
class MacroLenses {
  const MacroLenses({
    this.mainMinFocusCm,
    this.ultraWideMinFocusCm,
    this.ultraWideZoom,
    this.teleMultiplier,
    this.minZoom = 1,
    this.maxCameraZoom = 8,
  });

  final double? mainMinFocusCm;
  final double? ultraWideMinFocusCm;

  /// Camera zoom ratio that selects the ultra-wide (e.g. 0.6).
  final double? ultraWideZoom;

  /// Optical tele multiplier (the logical camera switches to it here, and
  /// telephotos can't focus close).
  final double? teleMultiplier;
  final double minZoom;
  final double maxCameraZoom;

  static const unknown = MacroLenses();

  /// From the Camera2 probe: main = isMain (or 1x), ultra-wide = shortest
  /// equivalent focal below the main one.
  factory MacroLenses.fromInfo(
    NativeZoomInfo? info, {
    double minZoom = 1,
    double maxCameraZoom = 8,
  }) {
    if (info == null) {
      return MacroLenses(minZoom: minZoom, maxCameraZoom: maxCameraZoom);
    }
    final backs = info.backCameras.where((c) => c.eqFocalMm != null).toList();
    CameraLensInfo? main;
    for (final c in backs) {
      if (c.isMain) main = c;
    }
    main ??= backs.isEmpty
        ? null
        : backs.reduce(
            (a, b) => ((a.eqFocalMm! - 26).abs() <= (b.eqFocalMm! - 26).abs())
                ? a
                : b,
          );
    CameraLensInfo? uw;
    if (main != null) {
      for (final c in backs) {
        if (c.eqFocalMm! < main.eqFocalMm! * 0.8 &&
            (uw == null || c.eqFocalMm! < uw.eqFocalMm!)) {
          uw = c;
        }
      }
    }
    final uwZoom = (uw != null && main != null)
        ? uw.eqFocalMm! / main.eqFocalMm!
        : null;
    return MacroLenses(
      mainMinFocusCm: main?.minFocusCm,
      ultraWideMinFocusCm: uw?.minFocusCm,
      ultraWideZoom: uwZoom != null && uwZoom >= minZoom - 0.05
          ? math.max(minZoom, uwZoom)
          : null,
      teleMultiplier: info.teleMultiplier,
      minZoom: minZoom,
      maxCameraZoom: maxCameraZoom,
    );
  }
}

/// How a macro chip is produced: camera zoom (lens) × digital crop.
class MacroZoom {
  const MacroZoom({
    required this.chip,
    required this.cameraZoom,
    required this.digitalZoom,
    required this.ultraWide,
    required this.minFocusCm,
  });
  final double chip;
  final double cameraZoom;
  final double digitalZoom;
  final bool ultraWide;
  final double? minFocusCm;

  @override
  String toString() =>
      'MacroZoom(${chip}x = cam ${cameraZoom.toStringAsFixed(2)} × '
      'dig ${digitalZoom.toStringAsFixed(2)}${ultraWide ? ' UW' : ''})';
}

/// Maps a chip to lens + crop. Pure → unit tested.
///
/// * The camera zoom stays BELOW the telephoto switch point (telephotos
///   can't focus close) — the rest is a centre crop.
/// * Ultra-wide close focus is used for 2x only when it really focuses much
///   closer (≤ 5 cm) than a far-focusing main camera (≥ 12 cm).
MacroZoom planMacroZoom(double chip, MacroLenses l) {
  final uwZoom = l.ultraWideZoom;
  final uwMin = l.ultraWideMinFocusCm;
  final mainMin = l.mainMinFocusCm;
  if (chip <= 2.0 &&
      uwZoom != null &&
      uwMin != null &&
      uwMin <= 5 &&
      (mainMin ?? 10) >= 12) {
    return MacroZoom(
      chip: chip,
      cameraZoom: uwZoom,
      digitalZoom: chip / uwZoom,
      ultraWide: true,
      minFocusCm: uwMin,
    );
  }
  var cap = l.maxCameraZoom;
  final tele = l.teleMultiplier;
  if (tele != null && tele > 1.5) cap = math.min(cap, tele - 0.1);
  final cam = math.max(1.0, math.min(chip, cap));
  return MacroZoom(
    chip: chip,
    cameraZoom: cam,
    digitalZoom: chip / cam,
    ultraWide: false,
    minFocusCm: mainMin,
  );
}

/// Index of the sharpest frame (higher Laplacian variance wins).
int sharpestIndex(List<double> sharpness) {
  var best = 0;
  for (var i = 1; i < sharpness.length; i++) {
    if (sharpness[i] > sharpness[best]) best = i;
  }
  return best;
}

/// Variance of the 4-neighbour Laplacian over the centre 60 % of a grey
/// proxy (0..255 values) — the macro burst keeps the frame with the most.
double laplacianVariance(List<double> px, int w, int h) {
  if (w < 5 || h < 5 || px.length < w * h) return 0;
  final x0 = (w * 0.2).floor().clamp(1, w - 2);
  final x1 = (w * 0.8).ceil().clamp(2, w - 1);
  final y0 = (h * 0.2).floor().clamp(1, h - 2);
  final y1 = (h * 0.8).ceil().clamp(2, h - 1);
  var s = 0.0, s2 = 0.0;
  var n = 0;
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      final i = y * w + x;
      final l = px[i - 1] + px[i + 1] + px[i - w] + px[i + w] - 4 * px[i];
      s += l;
      s2 += l * l;
      n++;
    }
  }
  if (n == 0) return 0;
  final m = s / n;
  return s2 / n - m * m;
}

/// Labels too generic to name a macro subject.
const _kGenericLabels = {
  'pattern',
  'close-up',
  'macro photography',
  'room',
  'darkness',
  'sky',
  'textile',
  'event',
  'fun',
  'smile',
  'metal',
  'wood',
  'paper',
};

/// Live subject chip for Macro: the most confident on-device image label
/// (≥ 0.55), lower-case; generic labels ignored.
String? macroSubjectFrom(List<SceneLabel> labels) {
  SceneLabel? best;
  for (final l in labels) {
    final t = l.text.trim().toLowerCase();
    if (l.confidence < 0.55 || t.isEmpty || _kGenericLabels.contains(t)) {
      continue;
    }
    if (best == null || l.confidence > best.confidence) best = l;
  }
  return best?.text.trim().toLowerCase();
}

// ---------------------------------------------------------------------------
// v11.1 Macro + AI Microscope: depth level from zoom, subject lock, extras
// ---------------------------------------------------------------------------

/// Depth level, decided ONLY by the zoom at shutter time.
enum MacroLevel {
  macro('macro', 'Macro'),
  close('close', 'Close Macro'),
  microscope('microscope', 'Microscope 🔬'),
  extreme('extreme', 'Extreme Microscope 🔬'),
  ultra('ultra', 'Ultra Electron Microscope 🔬');

  /// Microscope or Extreme: AI-imagined depth (prompt sent alone, distance
  /// gate, disclaimer, "AI imagined" label).
  bool get isMicroscopic =>
      this == microscope || this == extreme || this == ultra;

  /// v11.20 Extreme / Ultra: whole prompt + zoomed crop only.
  bool get isDeep => this == extreme || this == ultra;

  const MacroLevel(this.id, this.label);

  /// Wire id sent to the server (`macro_level`).
  final String id;

  /// Live on-screen label.
  final String label;
}

/// 2x–5x Macro · 6x–11x Close Macro · 12x–20x Microscope (rounded to 0.1x).
/// v11.20: Macro ≤5x · Close 6x · Microscope 12x · Extreme 21x · Ultra 30x;
/// in between → nearest band (midpoints 5.5 / 9 / 16.5 / 25.5).
MacroLevel macroLevelFor(double zoom) {
  final z = (zoom * 10).round() / 10;
  if (z >= 25.5) return MacroLevel.ultra;
  if (z >= 16.5) return MacroLevel.extreme;
  if (z >= 9.0) return MacroLevel.microscope;
  if (z >= 5.5) return MacroLevel.close;
  return MacroLevel.macro;
}

/// v11.7 levels: 2–5x Macro · 6–11x Close Macro · 12–20x Microscope ·
/// 21–30x Extreme Microscope.
const double kCloseMacroFromZoom = 6.0;
const double kMicroscopeFromZoom = 12.0;
const double kExtremeFromZoom = 21.0;

const String kMicroscopeFirstTip =
    'AI will imagine the microscopic view of your subject.';
const String kMicroscopeDisclaimer =
    'Microscope level is AI imagined and can make mistakes.';
const String kExtremeFirstTip =
    'Extreme: AI will imagine one tiny feature of your subject, very close.';
const String kExtremeDisclaimer =
    'Extreme Microscope level is AI imagined and can make mistakes.';

/// v11.27: each level names itself (the old Microscope text said "Ultra").
const String kUltraDisclaimer =
    'Ultra Electron Microscope level is AI imagined and can make mistakes.';

/// One-time tip text when first reaching a level (null = none).
String? macroFirstTipFor(MacroLevel l) => switch (l) {
  MacroLevel.microscope => kMicroscopeFirstTip,
  MacroLevel.extreme || MacroLevel.ultra => kExtremeFirstTip,
  _ => null,
};

/// Pre-shutter disclaimer text for a zoom (null below 12x).
String? macroDisclaimerFor(double zoom) => switch (macroLevelFor(zoom)) {
  MacroLevel.microscope => kMicroscopeDisclaimer,
  MacroLevel.extreme => kExtremeDisclaimer,
  MacroLevel.ultra => kUltraDisclaimer,
  _ => null,
};
const String kAiImaginedLabel = 'AI imagined · can make mistakes';
const String kHoldSteadyHint = 'Hold steady';
const String kTurnOnTorchHint = 'Turn on torch';

/// Pre-shutter disclaimer at Microscope + Extreme (12x–30x).
bool showMicroscopeDisclaimer(double zoom) => macroLevelFor(zoom).isMicroscopic;

/// "Hold steady" from 6x up while the frame is moving.
bool showHoldSteady({required double zoom, required double motion}) =>
    zoom >= 5.95 && motion >= kShakeMotion;

/// Mean absolute luma difference (0..1) between two analysis thumbnails
/// above which the camera is moving (shake) …
const double kShakeMotion = 0.035;

/// … and above which, at low zoom, it is pointed at something else.
const double kSceneChangeDiff = 0.16;

/// Scene too dark for macro detail → "Turn on torch".
const double kMacroDarkLuma = 0.16;
bool macroTooDark(double luma, {required bool torchOn}) =>
    !torchOn && luma < kMacroDarkLuma;

/// Mean absolute difference of two equally sized 0..255 thumbnails (0..1).
double frameDiff(List<int>? a, List<int>? b) {
  if (a == null || b == null || a.isEmpty || a.length != b.length) return 0;
  var s = 0;
  for (var i = 0; i < a.length; i++) {
    s += (a[i] - b[i]).abs();
  }
  return s / a.length / 255.0;
}

/// Subjects offered when the user taps the chip to correct it.
const List<String> kMacroSubjectChoices = [
  'Coin',
  'Fabric',
  'Leaf',
  'Skin',
  'Eye',
  'Paper',
  'Wood',
  'Metal',
  'Flower',
  'Insect',
  'Hair',
  'Food',
];

/// Detected subjects only change while the whole subject is visible.
const double kSubjectDetectMaxZoom = 4.0;

/// Live subject chip ("🔍 Eye") with lock:
/// * detection runs only at low zoom (≤ 4x) where the subject is fully
///   visible; the first confident label locks it;
/// * zooming in keeps the lock (even at 10x where only texture shows);
/// * a big frame change at low zoom (camera moved to another object)
///   unlocks and re-detects;
/// * a manual pick (tap → list) wins until the scene changes.
/// v11.15 chip text while the cloud detection runs.
const String kDetectingLabel = 'Detecting…';

/// Cloud name is a face / person → face-landmark sub-part allowed.
bool isFaceName(String name) => RegExp(
  r'\b(face|person|selfie|portrait|man|woman|child|boy|girl)\b',
).hasMatch(name.toLowerCase());

/// v11.14: the parent label is only taken while the camera is at ~1x.
const double kParentLockMaxZoom = 1.55; // v11.16: 1.5x detect step

class SubjectLock {
  String? _subject;
  bool _manual = false;

  String? get subject => _subject;
  bool get locked => _subject != null;
  bool get manual => _manual;

  /// One analysis tick. Returns true when the shown subject changed.
  bool update({
    required double zoom,
    required String? detected,
    double frameChange = 0,
  }) {
    final before = _subject;
    final lowZoom = zoom <= kSubjectDetectMaxZoom + 0.01;
    if (lowZoom && frameChange >= kSceneChangeDiff) {
      _subject = null; // another object → unlock
      _manual = false;
    }
    if (_subject == null &&
        lowZoom &&
        detected != null &&
        detected.isNotEmpty) {
      _subject = _title(detected);
    }
    return before != _subject;
  }

  /// User correction from the list (or custom text). Empty → unlock.
  void setManual(String? text) {
    final t = (text ?? '').trim();
    if (t.isEmpty) {
      _subject = null;
      _manual = false;
      return;
    }
    _subject = _title(t.length > 30 ? t.substring(0, 30) : t);
    _manual = true;
  }

  /// v11.10 live, zoom-aware label: keeps updating while zooming (locked
  /// only at shutter). A user pick wins until [reset]. Null keeps the last.
  bool setLive(String? label) {
    if (_manual || label == null || label.trim().isEmpty) return false;
    final before = _subject;
    _subject = _title(label);
    return before != _subject;
  }

  void reset() {
    _subject = null;
    _manual = false;
    clearParent();
  }

  // ---- v11.14 parent label locked at 1x ----------------------------------
  String? _parent;
  bool _parentIsFace = false;
  String? _part;

  /// Parent label locked from the 1x detection (e.g. "Mobile phone").
  String? get parent => _parent;
  bool get parentIsFace => _parentIsFace;

  /// Face sub-part from landmarks only (Eye/Skin/Lips/Hair/Eyebrow).
  String? get facePart => _part;

  /// Unlock (Macro entered / subject re-check started).
  void clearParent() {
    _others = const [];
    drifting = false;
    _cloudPart = null;
    _stepPart = null;
    _stepPartZoom = -1;
    _cloudFailed = false;
    _gen++;
    _detecting = false;
    _parent = null;
    _parentIsFace = false;
    _part = null;
  }

  /// One analysis tick. Locks the parent only while the camera is at ~1x
  /// and nothing is locked yet; after that labeler output is ignored.
  /// Returns true when the shown text may have changed.
  bool lockParent({
    required double cameraZoom,
    required bool face,
    String? sceneLabel,
  }) {
    if (_parent != null || cameraZoom > kParentLockMaxZoom) return false;
    if (face) {
      _parent = 'Face';
      _parentIsFace = true;
      return true;
    }
    final t = (sceneLabel ?? '').trim();
    if (t.isEmpty) return false;
    _parent = _title(t);
    return true;
  }

  /// Face parent only: sub-part from the face detector. Ignored otherwise.
  bool setFacePart(String? part) {
    if (!_parentIsFace) return false;
    final p = (part == null || part == 'Face') ? null : part;
    if (p == _part) return false;
    _part = p;
    return true;
  }

  // ---- v11.15 cloud detection ------------------------------------------
  int _gen = 0;
  bool _detecting = false;
  bool _cloudFailed = false;
  String? _cloudPart;

  /// v11.27 last part found by a 2x–5x step check (spot fallback).
  String? _stepPart;
  double _stepPartZoom = -1;
  String? get stepPart => _stepPart;

  /// v11.29 keep the best step part = the one from the closest zoom.
  void recordStepPart(double chip, String? part) {
    final p = (part ?? '').trim();
    if (p.isEmpty || chip < _stepPartZoom - 0.01) return;
    _stepPart = p;
    _stepPartZoom = chip;
  }

  bool get detecting => _detecting;

  /// The cloud call failed and nothing is locked → face fallback allowed.
  bool get cloudFailed => _cloudFailed;
  String? get cloudPart => _cloudPart;

  /// A 1x detection call starts: shows "Detecting…" (if nothing locked).
  int beginDetect() {
    _detecting = true;
    return ++_gen;
  }

  /// Result of call [gen]; stale results are ignored. Null = failure:
  /// the previous label is kept (none → "Subject", no hint).
  bool completeDetect(int gen, String? name, {List<String> others = const []}) {
    if (gen != _gen) return false;
    _detecting = false;
    final t = (name ?? '').trim();
    if (t.isEmpty) {
      _cloudFailed = _parent == null;
      return true;
    }
    _parent = _title(t);
    _parentIsFace = isFaceName(t);
    _part = null;
    _cloudPart = null;
    _stepPart = null;
    _stepPartZoom = -1;
    _cloudFailed = false;
    _others = [
      for (final o in others)
        if (o.trim().isNotEmpty && o.trim().toLowerCase() != t.toLowerCase())
          o.trim(),
    ];
    drifting = false;
    return true;
  }

  // ---- v11.22 multiple objects + drift-and-return ----------------------
  List<String> _others = const [];

  /// Other visible objects from the 1.5x detection.
  List<String> get others => List.unmodifiable(_others);

  /// While drifting the chip shows the subject only (no mixed part).
  bool drifting = false;

  /// Part check said the red box is on [object] (+ [part]). A known other
  /// object → switch the subject to it (old main becomes an "other"),
  /// no reset. Unknown / same object → just the part. True if changed.
  bool applyObjectPart(String? object, String? part) {
    if (_parent == null) return false;
    final sp = (part ?? '').trim();
    if (sp.isNotEmpty && _stepPart == null) _stepPart = sp;
    final known = matchKnownObject(object, _others);
    final isMain = matchKnownObject(object, [_parent!]) != null;
    if (known != null && !isMain) {
      final old = _parent!.toLowerCase();
      _others = [
        for (final o in _others)
          if (o != known) o,
        old,
      ];
      _parent = _title(known);
      _parentIsFace = isFaceName(known);
      _part = null;
      _cloudPart = null;
      final p = (part ?? '').trim();
      if (p.isNotEmpty) _cloudPart = p;
      return true;
    }
    return setCloudPart(part);
  }

  /// Step-photo check result: the boxed part (kept on failure).
  bool setCloudPart(String? part) {
    final p = (part ?? '').trim();
    if (p.isEmpty || _parent == null || p == _cloudPart) return false;
    _cloudPart = p;
    return true;
  }

  /// Invalidate any pending call (leaving Macro).
  void cancelDetect() {
    _gen++;
    _detecting = false;
  }

  String? get _shownPart =>
      _cloudPart ?? (_parentIsFace ? _part?.toLowerCase() : null);

  /// Text shown on screen. User pick wins; "Detecting…" while the first
  /// call runs; then "parent · part"; no parent → null ("Subject").
  String? display(double zoom) {
    if (_manual) return _subject;
    if (_parent == null) return _detecting ? kDetectingLabel : null;
    if (drifting) return _parent; // v11.22: subject only while drifting
    final part = _shownPart;
    // v11.27: short live label = just the zoomed part (e.g. brown iris).
    if (part != null) return part;
    return _parent;
  }

  /// Parent sent in the prompt hint (user pick or detected); null → none.
  String? get hint => _manual ? _subject : _parent;

  /// Zoomed spot sent in the prompt hint (cloud part; face part fallback).
  String? get partHint => _manual ? null : _shownPart;

  static String _title(String s) {
    final t = s.trim();
    return t.isEmpty ? t : t[0].toUpperCase() + t.substring(1);
  }
}

/// Macro credit rules (v11.1): retry is a normal paid run; only technical
/// failures are free; no subject-change refund check in Macro.
String macroRetryLabel(int tierCredits) => 'Try again · 🪙$tierCredits';

/// v11.27: Macro "Try again" costs the level's credits (2 / 5), never the
/// quality tier's.
int macroRetryCredits(
  MacroLevel? level,
  int tierCredits, {
  String quality = 'hd',
}) => level == null ? tierCredits : macroCreditsFor(level.id, quality: quality);

/// v11.27 PreviewScreen result when the user taps X (close).
const String kPreviewClosed = 'closed';

/// v11.5: highest camera zoom used in Macro = the device's optical-quality
/// limit (never the HAL's own digital zoom), at least 1x.
double macroCameraCap({
  required double hardwareMax,
  required double opticalLimit,
}) {
  final o = opticalLimit.isFinite && opticalLimit >= 1 ? opticalLimit : 1.0;
  return math.max(1.0, math.min(hardwareMax, o));
}

// ---------------------------------------------------------------------------
// v11.8: sharp preview, chip lock, tips, burst size, blur step-down
// ---------------------------------------------------------------------------

/// Gentle Macro tip (no distance gate any more; the shutter always works).
const String kMacroTip = 'Keep ~10 cm away, zoom with chips; tap to focus.';

/// Fixed-focus main lens (min focus distance reported as 0).
const String kFixedFocusTip = 'Hold ~10 cm away';

/// v11.20 step unlock: 1x+1.5x → (1.5x photo + subject detected) 2x →
/// 3x → 4x → 5x (a photo at each) → 6x Close, 12x Micro, 21x Extreme,
/// 30x Ultra. Stage = number of step chips done (0..5).
const List<double> kMacroStepZooms = [1.5, 2.0, 3.0, 4.0, 5.0];
const double kMacroDetectZoom = 1.5;
const double kMacroUnlockZoom = 5.0;

/// Chips visible at [stage] (0: 1x 1.5x; then one more per step; 5: all).
List<double> visibleMacroChips(int stage) => stage >= kMacroStepZooms.length
    ? kMacroChips
    : [1.0, ...kMacroStepZooms.take(stage + 1)];

/// Stage after [chip]'s step is done (only the next step chip advances).
int macroStageAfter(int stage, double chip) {
  final i = kMacroStepZooms.indexWhere((z) => (z - chip).abs() < 0.01);
  if (i < 0 || i > stage) return stage; // never skip a step
  return i + 1 > stage ? i + 1 : stage;
}

/// Is [chip] a step chip whose photo should be captured?
bool isMacroStepZoom(double chip) =>
    kMacroStepZooms.any((z) => (z - chip).abs() < 0.01);

/// Camera zoom for the LIVE preview: the camera's own hardware zoom (sharp,
/// like Photo mode); on-screen scaling only beyond the hardware max.
({double camera, double digital}) macroPreviewZoom({
  required double chip,
  required double minZoom,
  required double hardwareMax,
}) {
  final hi = math.max(minZoom, hardwareMax);
  final cam = chip.clamp(minZoom, hi).toDouble();
  return (camera: cam, digital: math.max(1.0, chip / cam));
}

/// Camera zoom at the SHUTTER: never past the optical limit (real pixels);
/// the crop factor makes up the rest of the user's zoom.
({double camera, double crop}) macroCaptureZoom({
  required double chip,
  required double previewCamera,
  required double opticalCap,
}) {
  final cam = math.max(1.0, math.min(previewCamera, opticalCap));
  return (camera: cam, crop: math.max(1.0, chip / cam));
}

/// Fixed-focus lens: min focus distance reported as 0 cm.
bool isFixedFocus(double? minFocusCm) => minFocusCm != null && minFocusCm <= 0;

/// Sharpest-of burst size: 7 on low-end devices, else 4.
/// v11.29: 4 frames on every phone (was 7 on low-end) → shorter hold.
int macroBurstCount({required bool lowEnd}) => 4;

/// Low-end heuristic: small preview stream (< 1080p long side) or a single
/// back camera without tele / ultra-wide and a small hardware zoom range.
bool isLowEndCamera({
  required int previewLongSide,
  required int backCameras,
  required double hardwareMax,
}) =>
    previewLongSide > 0 && previewLongSide < 1600 ||
    (backCameras <= 1 && hardwareMax <= 4.01);

/// v11.36 generic phone class for the zoom flows (no model names).
/// Strong signals: a telephoto lens (any back lens ≥ 1.8x), or a high-res
/// main sensor (in-sensor 2x crop) with a full-HD+ preview. Many back
/// lenses alone means little (cheap phones add 2 MP macro / depth lenses);
/// preview size is only a weak signal. [reason] shows in the debug overlay.
({bool lowEnd, String reason}) classifyCamera({
  required List<double> backFactors,
  required double sensorCropFactor,
  required int previewLongSide,
  required double hardwareMax,
}) {
  final tele = backFactors.isEmpty ? 1.0 : backFactors.reduce(math.max);
  final n = backFactors.length;
  if (tele >= 1.8) {
    return (
      lowEnd: false,
      reason: 'flagship: telephoto ${tele.toStringAsFixed(1)}x · $n lenses',
    );
  }
  if (sensorCropFactor >= 2 && previewLongSide >= 1440) {
    return (
      lowEnd: false,
      reason:
          'flagship: high-res main (${sensorCropFactor.toStringAsFixed(1)}x crop)',
    );
  }
  final why = previewLongSide > 0 && previewLongSide < 1280
      ? 'low preview $previewLongSide'
      : 'no telephoto';
  return (
    lowEnd: true,
    reason: 'cheap: $why · $n lenses · hw ${hardwareMax.toStringAsFixed(1)}x',
  );
}

/// v11.11 result screen: the level actually sent (always the zoom's).
String macroLevelSentLabel(MacroLevel l, {String? spot, String? source}) =>
    'Level sent: ${macroLevelName(l)}${macroSpotSuffix(spot, source)}';

/// Level name in result texts (v11.28: name the microscope type).
String macroLevelName(MacroLevel l) => switch (l) {
  MacroLevel.extreme => 'Extreme Microscope (1000x light)',
  MacroLevel.ultra => 'Ultra Electron Microscope',
  _ => l.label,
};

/// v11.29 ' · spot: brown iris (check)' ('' without a spot).
String macroSpotSuffix(String? spot, [String? source]) {
  final s = (spot ?? '').trim();
  if (s.isEmpty) return '';
  final src = (source ?? '').trim();
  return ' · spot: $s${src.isEmpty ? '' : ' ($src)'}';
}

/// v11.49 result line for Microscope / Extreme / Ultra: "Detected: …" or
/// "Not detected, used photo"; other levels: none.
String macroDetectNote(MacroLevel? level, String? spot) {
  if (level == null || !level.isMicroscopic) return '';
  final s = (spot ?? '').trim();
  return s.isEmpty ? ' · Not detected, used photo' : ' · Detected: $s';
}

/// v11.29 where the sent spot came from.
enum SpotSource { check, step, fallback }

/// v11.29 debug text of the shutter spot check.
String spotDebugText({
  required String reason,
  String spot = '',
  Duration? took,
  String model = '',
}) {
  final t = took == null
      ? ''
      : ' ${(took.inMilliseconds / 1000).toStringAsFixed(1)}s';
  final m = model == 'lite' ? ' (lite)' : '';
  if (reason == 'ok' && spot.isNotEmpty) return 'spot: ok $spot$t$m';
  if (reason == 'timeout') return 'spot: timeout$t';
  return 'spot: ${reason.replaceAll(' (', '(')}$t$m';
}

/// v11.29 spot sent to the image prompt + where it came from: the spot
/// check's own part → the best 2x–5x / 1.5x part → "<object> surface detail".
(String, SpotSource) pickSpot({
  String? object,
  String? part,
  required String parent,
  String? lastPart,
}) {
  final o = cleanDetected(object).isEmpty ? parent : object!;
  final p = cleanDetected(part);
  if (p.isNotEmpty && p != cleanDetected(o)) {
    return (
      finalSpotText(object: o, part: p, parent: parent),
      SpotSource.check,
    );
  }
  if (cleanDetected(lastPart).isNotEmpty) {
    return (
      finalSpotText(object: o, fallbackPart: lastPart, parent: parent),
      SpotSource.step,
    );
  }
  return (finalSpotText(object: o, parent: parent), SpotSource.fallback);
}

/// v11.29 debug: '2x ok brown iris · 3x fail(timeout) · 5x skip blur'.
String stepDebugText(Map<double, String> steps) {
  final keys = steps.keys.toList()..sort();
  return 'steps: ${[for (final k in keys) '${_chipText(k)}x ${steps[k]}'].join(' · ')}';
}

String _chipText(double z) =>
    z == z.roundToDouble() ? z.toStringAsFixed(0) : z.toString();

/// v11.29 5x part check only on a sharp frame (vs the 4x photo).
bool fiveXCheckAllowed(double sharp, double ref4x) =>
    ref4x > 0 && isClearPhoto(sharp, ref4x);

/// v11.29 shown after the frames are captured while the AI runs.
const String kProcessingMoveNow = 'Processing… you can move now';

/// Analysis in Macro: needed only at low zoom (detection / scene change) or
/// while no subject is locked. Once locked and zoomed past 3x the stream is
/// stopped (prevents preview downgrade on cheap phones).
bool macroNeedsAnalysis({required bool subjectLocked, required double chip}) =>
    !subjectLocked || chip <= kMacroUnlockZoom + 0.01;

/// Laplacian variance of the centre 1/[crop] of a grey proxy (the user's
/// zoomed region inside a still taken at the optical limit).
double regionSharpness(List<double> px, int w, int h, double crop) {
  final f = crop <= 1 ? 1.0 : 1 / crop;
  final rw = math.max(5, (w * f).round()), rh = math.max(5, (h * f).round());
  if (rw >= w || rh >= h) return laplacianVariance(px, w, h);
  final x0 = (w - rw) ~/ 2, y0 = (h - rh) ~/ 2;
  final sub = List<double>.filled(rw * rh, 0);
  for (var y = 0; y < rh; y++) {
    for (var x = 0; x < rw; x++) {
      sub[y * rw + x] = px[(y0 + y) * w + x0 + x];
    }
  }
  return laplacianVariance(sub, rw, rh);
}

// ---------------------------------------------------------------------------
// v11.10 zoom-aware Macro label (face → Face, then the part at the centre)
// ---------------------------------------------------------------------------

/// The face counts as a whole "Face" while this share of it is inside the
/// zoom region.
const double kWholeFaceShare = 0.6;

/// Face memory (from low zoom) is used this long once the face is too
/// zoomed-in to detect.
const Duration kFaceMemory = Duration(seconds: 20);

/// Part of [f] at normalised point [c] (same frame as f.box); null when the
/// point is clearly outside the head.
String? facePartAt(Offset c, LiveFace f) {
  final b = f.box;
  if (b.width <= 0 || b.height <= 0) return null;
  final u = (c.dx - b.left) / b.width, v = (c.dy - b.top) / b.height;
  if (u < -0.25 || u > 1.25 || v < -0.6 || v > 1.3) return null;
  if (v < 0) return 'Hair'; // above the face box
  if (u < 0 || u > 1) return v < 0.6 ? 'Hair' : 'Skin';
  Offset at(String k, double du, double dv) =>
      f.parts[k] ?? Offset(b.left + du * b.width, b.top + dv * b.height);
  final w = b.width, h = b.height;
  for (final eye in [at('leftEye', 0.32, 0.40), at('rightEye', 0.68, 0.40)]) {
    final dx = (c.dx - eye.dx).abs(), dy = c.dy - eye.dy;
    // v11.13: the whole eye opening (lids included), not just the pupil.
    if (dx < 0.15 * w && dy.abs() < 0.075 * h) return 'Eye';
    if (dx < 0.16 * w && dy < -0.07 * h && dy > -0.17 * h) return 'Eyebrow';
  }
  final m = at('mouth', 0.5, 0.80);
  final mouthCentre = Offset(m.dx, m.dy - 0.03 * h);
  if ((c.dx - mouthCentre.dx).abs() < 0.17 * w &&
      (c.dy - mouthCentre.dy).abs() < 0.07 * h) {
    return 'Lips';
  }
  return 'Skin'; // cheek, forehead, nose, chin
}

/// Label for the centred zoom region covering [regionScale] of the frame
/// side: whole face → "Face"; zoomed into a face → that part; no face →
/// [sceneLabel] (ML Kit on the analysis frame).
String? zoomAwareLabel({
  required List<LiveFace> faces,
  required double regionScale,
  String? sceneLabel,
}) {
  if (faces.isEmpty) return sceneLabel;
  final f = faces.reduce((a, b) => a.area >= b.area ? a : b);
  final s = regionScale.clamp(0.0, 1.0);
  final region = Rect.fromCenter(
    center: const Offset(0.5, 0.5),
    width: s,
    height: s,
  );
  final inter = region.intersect(f.box);
  final share = inter.width <= 0 || inter.height <= 0 || f.area <= 0
      ? 0.0
      : inter.width * inter.height / f.area;
  if (share >= kWholeFaceShare) return 'Face';
  return facePartAt(const Offset(0.5, 0.5), f) ?? sceneLabel;
}

/// Region of the current zoom inside a frame taken at [frameCameraZoom]
/// (side fraction): user zoom [zoom] → frameCameraZoom / zoom.
double regionScaleIn(double frameCameraZoom, double zoom) =>
    zoom <= 0 ? 1 : (frameCameraZoom / zoom).clamp(0.0, 1.0);

// ---------------------------------------------------------------------------
// v11.13: 1x context photo, subject-change re-check, eye-aware label
// ---------------------------------------------------------------------------

/// Context photos sent to the AI (boxed): 1.5x, 2x, 3x, 4x.
const List<double> kMacroContextZooms = [1.5, 2.0, 3.0, 4.0]; // v11.16

bool isMacroContextZoom(double chip) =>
    kMacroContextZooms.any((z) => (z - chip).abs() < 0.01);

/// Re-check hint shown while the context photos are retaken.
const String kRecheckingSubject = 'Re-checking subject…';

/// Detects that the user moved to a different subject: [driftMetric] of the
/// live thumb vs the baseline (taken when the zoom settled) says drift on
/// [needed] consecutive checks [interval] apart. Blurry frames are skipped.
class SubjectChangeWatch {
  SubjectChangeWatch({
    this.threshold = kDriftDiffThreshold,
    this.colorThreshold = kDriftColorThreshold,
    this.needed = kDriftChecksNeeded,
    this.interval = kDriftCheckInterval,
    this.cooldown = kDriftCooldown,
    this.minZoom = kMacroDetectZoom,
  });

  /// Watch only at/above this zoom (v11.16: from 1.5x, once locked).
  final double minZoom;

  final double threshold;
  final double colorThreshold;
  final int needed;
  final Duration interval;
  final Duration cooldown;

  List<int>? _baseline;
  double _refSharp = 0;
  int _streak = 0;
  DateTime? _lastCheck;
  DateTime? _lastTrigger;

  /// Last metric (debug line), blur state, the baseline left when drift
  /// fired (return reference) and its sharpness.
  DriftMetric? last;
  bool blurry = false;
  List<int>? triggeredFrom;
  double triggeredSharp = 0;
  List<int>? get baseline => _baseline;
  double get refSharpness => _refSharp;

  /// v11.23 compat: last structure score.
  double? get lastScore => last?.s;

  /// New zoom / fresh context photos: start over from the next frame.
  void reset() {
    _baseline = null;
    _refSharp = 0;
    _streak = 0;
    blurry = false;
  }

  /// One analysis frame. Returns true when drift is confirmed.
  bool update({
    required List<int>? thumb,
    required double zoom,
    required DateTime now,
    bool busy = false,
    double? threshold,
    double? colorThreshold,
    int? needed,
    double? sharpness,
  }) {
    if (thumb == null || zoom < minZoom - 0.01 || busy) {
      if (zoom < minZoom - 0.01) reset();
      return false;
    }
    if (_baseline == null) {
      _baseline = List<int>.of(thumb);
      _refSharp = sharpness ?? 0;
      _lastCheck = now;
      return false;
    }
    // v11.26: zoom / focus blur → skip entirely, resume when sharp.
    blurry = driftFrameBlurry(sharpness, _refSharp);
    if (blurry) return false;
    if (sharpness != null && sharpness > _refSharp) _refSharp = sharpness;
    if (_lastCheck != null && now.difference(_lastCheck!) < interval) {
      return false;
    }
    _lastCheck = now;
    final m = driftMetric(_baseline, thumb);
    if (m == null) {
      _baseline = List<int>.of(thumb); // size changed: new baseline
      return false;
    }
    last = m;
    final drift =
        m.s >= (threshold ?? this.threshold) &&
        m.c >= (colorThreshold ?? this.colorThreshold);
    _streak = drift ? _streak + 1 : 0;
    if (_streak < (needed ?? this.needed)) return false;
    if (_lastTrigger != null && now.difference(_lastTrigger!) < cooldown) {
      return false;
    }
    _lastTrigger = now;
    triggeredFrom = _baseline;
    triggeredSharp = _refSharp;
    reset();
    return true;
  }
}

/// Eye-related on-device labels (any confidence ≥ 0.4) win at Macro zoom.
const Set<String> _kEyeWords = {'eye', 'eyelash', 'iris', 'eyebrow', 'pupil'};

String? eyeFromLabels(List<SceneLabel> labels) {
  for (final l in labels) {
    final t = l.text.trim().toLowerCase();
    if (l.confidence >= 0.4 && _kEyeWords.contains(t)) {
      return t == 'eyebrow' ? 'Eyebrow' : 'Eye';
    }
  }
  return null;
}

/// v11.15 debounce for re-checks triggered by the cloud "same_subject":
/// false answer (at most one per [gap]).
class RecheckDebounce {
  RecheckDebounce({this.gap = const Duration(seconds: 8)});
  final Duration gap;
  DateTime? _last;

  bool allow(DateTime now) {
    if (_last != null && now.difference(_last!) < gap) return false;
    _last = now;
    return true;
  }
}

final RecheckDebounce kCloudRecheck = RecheckDebounce();

// ---------------------------------------------------------------------------
// v11.16 guided chip flow (Hinglish guide text) + drift thresholds
// ---------------------------------------------------------------------------

/// Drift = [driftScore] of the live preview vs the baseline (taken when the
/// zoom settled) at least [kDriftDiffThreshold] on [kDriftChecksNeeded]
/// consecutive checks [kDriftCheckInterval] apart.
///
/// v11.23: the score is 1 − correlation of 12×16 grayscale blocks
/// (exposure-normalised), 0 = same view, ~1 = unrelated place. The old
/// RGBA mean-abs-diff could not reach 0.30 (alpha is constant; even two
/// random images only score ~0.25), so drift never fired.
///
/// v11.26: drift needs BOTH a structure change (best match over small
/// shifts / scales, [driftMetric].s) AND a colour change (hue/sat
/// histogram, [driftMetric].c), sustained for 2 s (4 checks) up to 5x.
const double kDriftDiffThreshold = 0.65;
const double kDriftColorThreshold = 0.45;
const int kDriftChecksNeeded = 4;
const Duration kDriftCheckInterval = Duration(milliseconds: 500);
const Duration kDriftCooldown = Duration(seconds: 2);

/// Past [kDriftDeepZoom] hand shake moves the view a lot: stricter, 3 s.
const double kDriftDeepZoom = 6.0;
const double kDriftDeepThreshold = 0.75;
const double kDriftDeepColorThreshold = 0.50;
const int kDriftDeepChecksNeeded = 6;

/// v11.26: no drift check while the live frame is blurry (sharpness below
/// this share of the sharpness seen at the reference) — zoom blur never
/// triggers the popup.
const double kDriftBlurRatio = 0.5;

/// Shift-tolerant match: ±25 % of the frame in x / y, three scales.
const double kDriftMaxShift = 0.25;
const List<double> kDriftScales = [0.9, 1.0, 1.1];

/// Below this block std (0..255) a view counts as flat (no texture).
const double kDriftFlatStd = 6.0;

/// Drift threshold / checks needed at [chip].
double driftThresholdFor(double chip) =>
    chip >= kDriftDeepZoom - 0.01 ? kDriftDeepThreshold : kDriftDiffThreshold;
int driftChecksFor(double chip) =>
    chip >= kDriftDeepZoom - 0.01 ? kDriftDeepChecksNeeded : kDriftChecksNeeded;
double driftColorThresholdFor(double chip) => chip >= kDriftDeepZoom - 0.01
    ? kDriftDeepColorThreshold
    : kDriftColorThreshold;

/// v11.26 drift metric: [s] structure (0 = same view, 1 = unrelated) as the
/// BEST match over shifts / scales; [c] colour histogram difference (0..1).
class DriftMetric {
  const DriftMetric(this.s, this.c);
  final double s;
  final double c;

  /// Clearly a different subject at [chip] (both must agree).
  bool driftAt(double chip) =>
      s >= driftThresholdFor(chip) && c >= driftColorThresholdFor(chip);

  /// Back on the subject.
  bool get matches => s < kDriftReturnDiff || c < kDriftReturnColor;

  @override
  String toString() => 's${s.toStringAsFixed(2)} c${c.toStringAsFixed(2)}';
}

const int _kTw = 48, _kTh = 64; // FrameStats thumb (RGBA)
const int kDriftGridW = 24, kDriftGridH = 32;

/// 48×64 RGBA thumb → blurred 24×32 grayscale grid (2×2 average + 3×3 box).
List<double> driftGrid(List<int> t) {
  const w = kDriftGridW, h = kDriftGridH;
  final g = List<double>.filled(w * h, 0);
  for (var y = 0; y < _kTh; y++) {
    for (var x = 0; x < _kTw; x++) {
      final o = (y * _kTw + x) * 4;
      g[(y >> 1) * w + (x >> 1)] +=
          (0.299 * t[o] + 0.587 * t[o + 1] + 0.114 * t[o + 2]) / 4;
    }
  }
  final out = List<double>.filled(w * h, 0);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var sum = 0.0, n = 0;
      for (var dy = -1; dy <= 1; dy++) {
        final yy = y + dy;
        if (yy < 0 || yy >= h) continue;
        for (var dx = -1; dx <= 1; dx++) {
          final xx = x + dx;
          if (xx < 0 || xx >= w) continue;
          sum += g[yy * w + xx];
          n++;
        }
      }
      out[y * w + x] = sum / n;
    }
  }
  return out;
}

double _std(List<double> v) {
  var m = 0.0;
  for (final x in v) {
    m += x;
  }
  m /= v.length;
  var s = 0.0;
  for (final x in v) {
    s += (x - m) * (x - m);
  }
  return math.sqrt(s / v.length);
}

/// Structure score: 1 − best Pearson correlation of [live] against [ref]
/// over shifts up to ±[kDriftMaxShift] and [kDriftScales] (grid coords).
double driftStructure(List<double> ref, List<double> live) {
  const w = kDriftGridW, h = kDriftGridH;
  final sr = _std(ref), sl = _std(live);
  if (sr < kDriftFlatStd || sl < kDriftFlatStd) {
    var mr = 0.0, ml = 0.0;
    for (var i = 0; i < ref.length; i++) {
      mr += ref[i];
      ml += live[i];
    }
    mr /= ref.length;
    ml /= ref.length;
    final tex = math.max(sr, sl) < kDriftFlatStd
        ? 0.0
        : (sr - sl).abs() / math.max(math.max(sr, sl), 1.0);
    return math.max(tex, (mr - ml).abs() / 64.0).clamp(0.0, 1.0).toDouble();
  }
  final mx = (w * kDriftMaxShift).round(), my = (h * kDriftMaxShift).round();
  const cx = (w - 1) / 2, cy = (h - 1) / 2;
  final minN = (w * h) ~/ 2;
  var best = -1.0;
  for (final sc in kDriftScales) {
    for (var dy = -my; dy <= my; dy++) {
      for (var dx = -mx; dx <= mx; dx++) {
        var n = 0;
        var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0;
        for (var y = 0; y < h; y++) {
          final ly = (cy + (y - cy) * sc + dy).round();
          if (ly < 0 || ly >= h) continue;
          for (var x = 0; x < w; x++) {
            final lx = (cx + (x - cx) * sc + dx).round();
            if (lx < 0 || lx >= w) continue;
            final a = ref[y * w + x], b = live[ly * w + lx];
            sa += a;
            sb += b;
            saa += a * a;
            sbb += b * b;
            sab += a * b;
            n++;
          }
        }
        if (n < minN) continue;
        final va = saa - sa * sa / n, vb = sbb - sb * sb / n;
        if (va <= 1e-6 || vb <= 1e-6) continue;
        final r = (sab - sa * sb / n) / math.sqrt(va * vb);
        if (r > best) best = r;
      }
    }
  }
  return (1 - best).clamp(0.0, 1.0).toDouble();
}

/// Hue/saturation histogram (16 hue × 4 sat bins for coloured pixels, plus
/// 8 brightness bins for grey pixels), normalised to sum 1.
List<double> hueSatHist(List<int> t) {
  final h = List<double>.filled(16 * 4 + 8, 0);
  var n = 0;
  for (var o = 0; o + 3 < t.length; o += 4) {
    final r = t[o] / 255, g = t[o + 1] / 255, b = t[o + 2] / 255;
    final mx = math.max(r, math.max(g, b)), mn = math.min(r, math.min(g, b));
    final d = mx - mn;
    final sat = mx <= 0 ? 0.0 : d / mx;
    if (sat < 0.12 || d < 0.04) {
      h[64 + math.min(7, (mx * 8).floor())] += 1;
    } else {
      double hue;
      if (mx == r) {
        hue = ((g - b) / d) % 6;
      } else if (mx == g) {
        hue = (b - r) / d + 2;
      } else {
        hue = (r - g) / d + 4;
      }
      final hb = math.min(15, (hue / 6 * 16).floor()).clamp(0, 15);
      final sb = math.min(3, ((sat - 0.12) / 0.88 * 4).floor()).clamp(0, 3);
      h[hb * 4 + sb] += 1;
    }
    n++;
  }
  if (n > 0) {
    for (var i = 0; i < h.length; i++) {
      h[i] /= n;
    }
  }
  return h;
}

/// 1 − histogram intersection (0 = same colours, 1 = none shared).
double colorDistance(List<double> a, List<double> b) {
  var s = 0.0;
  for (var i = 0; i < a.length; i++) {
    s += math.min(a[i], b[i]);
  }
  return (1 - s).clamp(0.0, 1.0).toDouble();
}

/// v11.26 drift metric of two thumbs; null when not comparable. Non-thumb
/// vectors (tests / other sizes) fall back to [driftScore] for both parts.
DriftMetric? driftMetric(List<int>? a, List<int>? b) {
  if (a == null || b == null || a.isEmpty || a.length != b.length) {
    return null;
  }
  if (a.length != _kTw * _kTh * 4) {
    final d = driftScore(a, b);
    return d == null ? null : DriftMetric(d, d);
  }
  return DriftMetric(
    driftStructure(driftGrid(a), driftGrid(b)),
    colorDistance(hueSatHist(a), hueSatHist(b)),
  );
}

/// v11.26: is [sharpness] blurry vs [reference] (skip drift checks)?
bool driftFrameBlurry(double? sharpness, double reference) =>
    sharpness != null &&
    reference > 0 &&
    sharpness < kDriftBlurRatio * reference;

/// Thumb → grayscale vector: the 48×64 RGBA preview thumb → 12×16 blocks
/// (4×4 average); other RGBA sizes → per-pixel gray; else raw values.
List<double> driftGray(List<int> t) {
  const w = 48, h = 64, b = 4;
  if (t.length == w * h * 4) {
    final out = List<double>.filled((w ~/ b) * (h ~/ b), 0);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final o = (y * w + x) * 4;
        final g = 0.299 * t[o] + 0.587 * t[o + 1] + 0.114 * t[o + 2];
        out[(y ~/ b) * (w ~/ b) + x ~/ b] += g / (b * b);
      }
    }
    return out;
  }
  if (t.length % 4 == 0 && t.length >= 16) {
    return [
      for (var i = 0; i < t.length; i += 4)
        0.299 * t[i] + 0.587 * t[i + 1] + 0.114 * t[i + 2],
    ];
  }
  return [for (final v in t) v.toDouble()];
}

/// v11.23 drift metric (0..1): 1 − Pearson correlation of [driftGray]
/// vectors; flat views compare mean + texture instead. Null when the
/// thumbs can't be compared.
double? driftScore(List<int>? a, List<int>? b) {
  if (a == null || b == null || a.isEmpty || a.length != b.length) {
    return null;
  }
  final x = driftGray(a), y = driftGray(b);
  final n = x.length;
  var mx = 0.0, my = 0.0;
  for (var i = 0; i < n; i++) {
    mx += x[i];
    my += y[i];
  }
  mx /= n;
  my /= n;
  var sxx = 0.0, syy = 0.0, sxy = 0.0;
  for (var i = 0; i < n; i++) {
    final dx = x[i] - mx, dy = y[i] - my;
    sxx += dx * dx;
    syy += dy * dy;
    sxy += dx * dy;
  }
  final sx = math.sqrt(sxx / n), sy = math.sqrt(syy / n);
  if (sx < kDriftFlatStd || sy < kDriftFlatStd) {
    final tex = (sx - sy).abs() / math.max(math.max(sx, sy), 1.0);
    final lum = (mx - my).abs() / 64.0;
    return math
        .max(tex * (math.max(sx, sy) < kDriftFlatStd ? 0 : 1), lum)
        .clamp(0.0, 1.0)
        .toDouble();
  }
  final r = sxy / n / (sx * sy);
  return (1 - r).clamp(0.0, 1.0).toDouble();
}

const String kGuideStart = 'Point at what you want to shoot, then tap 1.5x';
const String kGuideDetecting =
    'Detecting… hold still and keep it in focus — no need to get closer';
const String kGuideDetectFailed = 'Couldn\'t identify — tap 1.5x again';

/// v11.24 retry button under the failure guide (new photo + detect).
const String kDetectRetryLabel = 'Try again';
const String kGuideAt2x = 'Hold steady and focus… now tap 3x';
const String kGuideAt3x = 'Focus… now tap 4x';
const String kGuideAt4x = 'Focus… now tap 5x';
const String kGuideAt4xWait = 'Focusing…';
const String kGuideDone = 'Done ✓ Zoom as much as you like and take the photo';

/// v11.22 drift: first ask to come back, reset only after the grace time.
String guideDriftBack(String? subject) {
  final s = (subject ?? '').trim();
  return 'Moved off subject — return to ${s.isEmpty ? 'the subject' : s}';
}

/// v11.26 shown while the zoom changes.
const String kGuideZooming = 'Hold steady while zooming';

/// How long after a chip tap the zoom guide stays.
const Duration kZoomGuideTime = Duration(milliseconds: 1200);

const String kGuideDriftReset = 'New subject? Tap 1.5x';
const String kGuideDrift =
    'Subject changed — point at what you want to shoot and tap 1.5x';

String guideFound(String label) => 'Found $label ✓ now tap 2x';

/// Guide line for the Macro hint area. Pure.
String macroFlowGuide({
  required double chip,
  required int stage,
  required bool detecting,
  String? label,
  bool drifted = false,
  bool driftWaiting = false,
  bool failed = false,
  bool zooming = false,
}) {
  if (detecting) return kGuideDetecting;
  if (zooming && !driftWaiting) return kGuideZooming; // v11.26
  if (driftWaiting) return guideDriftBack(label);
  if (chip < kMacroDetectZoom - 0.01) {
    return drifted ? kGuideDriftReset : kGuideStart;
  }
  if (stage >= kMacroStepZooms.length) return kGuideDone;
  if (chip < 1.99) {
    final l = (label ?? '').trim();
    if (stage >= 1 && l.isNotEmpty) return guideFound(l);
    // v11.24: failure text only after a real failure, else "Detecting…".
    return failed ? kGuideDetectFailed : kGuideDetecting;
  }
  if (chip < 2.99) return kGuideAt2x;
  if (chip < 3.99) return kGuideAt3x;
  if (chip < 4.99) return kGuideAt4x;
  return kGuideAt4xWait;
}

// ---------------------------------------------------------------------------
// v11.19 last clear photo beyond 4x (free, on-device sharpness only)
// ---------------------------------------------------------------------------

/// A photo beyond 4x is "clear" while its sharpness is at least this share
/// of the 4x step photo's sharpness; below it capturing stops.
const double kClearSharpnessRatio = 0.35;

/// Clear photos are taken from this zoom up (after the 4x unlock).
const double kClearMinZoom = 5.5; // v11.20: past the 5x step

bool isClearPhoto(double sharpness, double ref4x) =>
    ref4x <= 0 ? sharpness > 0 : sharpness >= ref4x * kClearSharpnessRatio;

/// Should a clear photo be taken at [chip] (camera zoom [cam])?
bool wantClearPhoto({
  required int stage,
  required double chip,
  required double cam,
  required bool stopped,
  double? lastClearCam,
  double? fourXCam,
}) {
  if (stage < kMacroStepZooms.length ||
      stopped ||
      chip < kClearMinZoom - 0.01) {
    return false;
  }
  final base = lastClearCam ?? fourXCam ?? 0;
  return cam > base + 0.05; // camera can't zoom further → same photo
}

// ---------------------------------------------------------------------------
// v11.22 5x unlock (no step photo at 5x) + drift-and-return
// ---------------------------------------------------------------------------

/// v11.22: a step chip always completes within this time, even when its
/// photo / check never finishes (the 5x chips could stay hidden).
const Duration kMacroStepTimeout = Duration(seconds: 6);

/// A step chip without a step photo (5x: clear photos take over there)
/// completes right after the zoom settles.
bool stepCompletesWithoutPhoto(double chip) =>
    isMacroStepZoom(chip) && !isMacroContextZoom(chip);

/// Drift grace: the user may come back to the subject within this time.
const Duration kDriftReturnTimeout = Duration(seconds: 5); // v11.25

/// v11.26 "back on the subject": structure below this OR colour below
/// [kDriftReturnColor] on [kDriftReturnFrames] frames.
const double kDriftReturnDiff = 0.35;
const double kDriftReturnColor = 0.25;

/// v11.26: once shown, the popup stays at least this long.
const Duration kDriftPopupMin = Duration(milliseconds: 1500);

/// Consecutive matching frames needed to restore the lock.
const int kDriftReturnFrames = 2;

enum DriftState { none, waiting, returned, expired }

/// v11.22: after a drift, compare the live preview (free, on-device) with
/// the reference thumb. Back → restore the lock silently (never before
/// [minShow]); not back within [timeout] → reset to 1x.
class DriftReturn {
  DriftReturn({
    this.timeout = kDriftReturnTimeout,
    this.matchDiff = kDriftReturnDiff,
    this.matchColor = kDriftReturnColor,
    this.frames = kDriftReturnFrames,
    this.minShow = kDriftPopupMin,
  });

  final Duration timeout;
  final double matchDiff;
  final double matchColor;
  final int frames;
  final Duration minShow;

  List<int>? _ref;
  double _refSharp = 0;
  DateTime? _since;
  int _hits = 0;

  /// Last live metric vs the reference (debug line).
  DriftMetric? last;
  bool blurry = false;

  /// v11.23 compat.
  double? get lastScore => last?.s;
  set lastScore(double? v) =>
      last = v == null ? null : DriftMetric(v, last?.c ?? v);

  bool get waiting => _since != null;

  /// v11.25 countdown: whole seconds left in the return window (5…1).
  int secondsLeft(DateTime now) {
    final since = _since;
    if (since == null) return 0;
    final left = timeout - now.difference(since);
    if (left <= Duration.zero) return 0;
    return (left.inMilliseconds / 1000).ceil();
  }

  /// Drift detected: start the grace period against [reference].
  void start(List<int>? reference, DateTime now, {double refSharpness = 0}) {
    _ref = reference == null ? null : List<int>.of(reference);
    _refSharp = refSharpness;
    _since = now;
    _hits = 0;
    blurry = false;
  }

  void cancel() {
    _ref = null;
    _since = null;
    _hits = 0;
  }

  /// One live frame (or a timer tick with [thumb] null).
  DriftState update(List<int>? thumb, DateTime now, {double? sharpness}) {
    final since = _since;
    if (since == null) return DriftState.none;
    blurry = thumb != null && driftFrameBlurry(sharpness, _refSharp);
    final m = blurry ? null : driftMetric(_ref, thumb);
    if (m != null) {
      last = m;
      _hits = (m.s < matchDiff || m.c < matchColor) ? _hits + 1 : 0;
    }
    final age = now.difference(since);
    if (_hits >= frames && age >= minShow) {
      cancel();
      return DriftState.returned;
    }
    if (age >= timeout) {
      cancel();
      return DriftState.expired;
    }
    return DriftState.waiting;
  }
}

/// Reference thumb for [chip]: its own step thumb, else the nearest step.
List<int>? driftReference(Map<double, List<int>> thumbs, double chip) {
  if (thumbs.isEmpty) return null;
  final keys = thumbs.keys.toList()
    ..sort((a, b) => (a - chip).abs().compareTo((b - chip).abs()));
  return thumbs[keys.first];
}

// ---------------------------------------------------------------------------
// v11.23 continuous drift monitor (the home screen's only drift path)
// ---------------------------------------------------------------------------

enum DriftEvent { none, started, returned, reset }

/// Every preview frame goes through [onFrame] from the moment the subject
/// is locked (1.5x detected) through all zoom steps; ~every 0.5 s a cheap
/// on-device [driftMetric] vs the baseline (blurry frames skipped). Drift →
/// [DriftEvent.started] (popup + 5 s return window); back →
/// [DriftEvent.returned]; not back → [DriftEvent.reset] (to 1x). [tick]
/// drives the timeout without frames.
class MacroDriftMonitor {
  MacroDriftMonitor({SubjectChangeWatch? watch, DriftReturn? ret})
    : watch = watch ?? SubjectChangeWatch(),
      ret = ret ?? DriftReturn();

  final SubjectChangeWatch watch;
  final DriftReturn ret;

  /// How the last window ended ('back' / 'reset'; '' = none yet).
  String lastEnd = '';

  bool get waiting => ret.waiting;

  /// Live metric for the debug line; null = not watching.
  DriftMetric? get metric => ret.waiting ? ret.last : watch.last;
  bool get blurry => ret.waiting ? ret.blurry : watch.blurry;

  /// v11.23 compat: structure part.
  double? get score => metric?.s;

  DriftEvent onFrame({
    required List<int>? thumb,
    required double chip,
    required DateTime now,
    required bool locked,
    bool busy = false,
    double? sharpness,
    Map<double, List<int>> refs = const {},
  }) {
    if (ret.waiting) {
      return _map(ret.update(thumb, now, sharpness: sharpness));
    }
    if (!locked) {
      watch.reset();
      watch.last = null;
      return DriftEvent.none;
    }
    final fired = watch.update(
      thumb: thumb,
      zoom: chip,
      now: now,
      busy: busy,
      threshold: driftThresholdFor(chip),
      colorThreshold: driftColorThresholdFor(chip),
      needed: driftChecksFor(chip),
      sharpness: sharpness,
    );
    if (!fired) return DriftEvent.none;
    begin(now, chip: chip, refs: refs);
    return DriftEvent.started;
  }

  /// Start the return window (also from a part check saying in_scene
  /// false). Reference: the baseline at this zoom, else nearest step.
  void begin(
    DateTime now, {
    required double chip,
    Map<double, List<int>> refs = const {},
  }) {
    final fromTrigger = watch.triggeredFrom != null;
    final ref =
        watch.triggeredFrom ?? watch.baseline ?? driftReference(refs, chip);
    final sharp = fromTrigger ? watch.triggeredSharp : watch.refSharpness;
    watch.triggeredFrom = null;
    ret.start(ref, now, refSharpness: sharp);
    ret.last = watch.last;
  }

  /// Timer tick (no frame): only the timeout can happen.
  DriftEvent tick(DateTime now) => _map(ret.update(null, now));

  void cancel() {
    ret.cancel();
    watch.reset();
  }

  /// v11.27 fresh start (X on the result): no window, metric or end note.
  void clear() {
    cancel();
    watch.last = null;
    ret.last = null;
    lastEnd = '';
  }

  DriftEvent _map(DriftState s) {
    switch (s) {
      case DriftState.returned:
        lastEnd = 'back';
        return DriftEvent.returned;
      case DriftState.expired:
        lastEnd = 'reset';
        return DriftEvent.reset;
      default:
        return DriftEvent.none;
    }
  }
}

/// v11.26 key-build debug line: 'drift: s0.xx c0.xx' (+ blur / back / reset).
String driftDebugText(DriftMetric? m, {String end = '', bool blurry = false}) {
  final parts = <String>[
    m == null ? 'drift: –' : 'drift: $m',
    if (blurry) 'blur',
    if (end.isNotEmpty) end,
  ];
  return parts.join(' · ');
}

// ---------------------------------------------------------------------------
// v11.25 keep the lock when returning to 1x / 1.5x
// ---------------------------------------------------------------------------

enum ChipReturnAction {
  /// Old behaviour: 1x resets, 1.5x photo + detection when not locked.
  normal,

  /// Locked and the view still matches: keep lock, label, chips; no call.
  keepLock,

  /// Locked at 1.5x but the view clearly differs: reset + re-detect.
  redetect,

  /// Locked at 1x but the view clearly differs: drift popup + window.
  driftWindow,
}

/// Is [chip] a "return" chip (1x / 1.5x) that must not reset a lock?
bool isLockReturnChip(double chip) => chip < kMacroDetectZoom + 0.01;

/// After tapping 1x / 1.5x with a subject locked, the free on-device
/// [score] (live view vs the lock-time reference; null = no data) decides.
ChipReturnAction chipReturnAction({
  required bool locked,
  required double chip,
  double? score,
  DriftMetric? metric,
  bool drift = false,
}) {
  if (drift || !locked || !isLockReturnChip(chip)) {
    return ChipReturnAction.normal;
  }
  // v11.26: 1x with a lock does nothing (no check, popup or detection).
  if (chip < kMacroDetectZoom - 0.01) return ChipReturnAction.keepLock;
  final mismatch = metric != null
      ? metric.driftAt(chip)
      : (score != null && score >= driftThresholdFor(chip));
  return mismatch ? ChipReturnAction.redetect : ChipReturnAction.keepLock;
}

/// v11.25 drift popup button + reset toast.
const String kDriftNewSubjectLabel = 'New subject';

// ---------------------------------------------------------------------------
// v11.26 Macro credits + AI input photos per level (same as server)
// ---------------------------------------------------------------------------

/// v11.33 credits per Macro photo by quality + level (charged only on
/// success). Config: change here or on the server admin page
/// /admin/macro-credits (GET /v1/macro/credits). 2K is shown locked
/// ("Coming soon"): kept here but can't be bought yet. No 4K.
const Map<String, Map<String, int>> kMacroCredits = {
  'hd': {'macro': 4, 'close': 4, 'microscope': 5, 'extreme': 2, 'ultra': 2},
  'full_hd': {
    'macro': 5,
    'close': 5,
    'microscope': 6,
    'extreme': 3,
    'ultra': 3,
  },
  '2k': {
    'macro': 13,
    'close': 13,
    'microscope': 14,
    'extreme': 10,
    'ultra': 10,
  },
};

/// Macro qualities shown in the picker (id, label, image quality).
const List<(String, String, String)> kMacroQualities = [
  ('hd', 'HD', 'low'),
  ('full_hd', 'Full HD', 'medium'),
  ('2k', '2K', 'high'),
];
const Set<String> kMacroLockedQualities = {'2k'};
const String kComingSoonLabel = 'Coming soon';

/// Legacy name: the HD row.
const Map<String, int> kMacroLevelCredits = {
  'macro': 4,
  'close': 4,
  'microscope': 5,
  'extreme': 2,
  'ultra': 2,
};

int macroCreditsFor(String? level, {String quality = 'hd'}) {
  final row = kMacroCredits[quality] ?? kMacroCredits['hd']!;
  return row[level] ?? row['macro']!;
}

/// Long side of the zoomed crop sent to the image model (Macro / Close /
/// Microscope); Extreme / Ultra unchanged.
const int kMacroCropLongSide = 1536;
const int kMacroStepLongSide = 768;

/// AI inputs per level: step photos sent (max) + crop long side (null =
/// the normal enhance size). The detection label always goes in the prompt.
({int maxSteps, int? cropLong, int stepLong}) macroInputPlan(String? level) =>
    switch (level) {
      'microscope' => (
        maxSteps: 1, // v11.33: crop + one 1x–2x hint photo
        cropLong: kMacroCropLongSide,
        stepLong: kMacroStepLongSide,
      ),
      // v11.40: ≤2 wider context photos (used only when no spot text).
      'extreme' ||
      'ultra' => (maxSteps: 2, cropLong: null, stepLong: kMacroStepLongSide),
      _ => (
        maxSteps: 2, // v11.40: crop + ≤2 wider context photos
        cropLong: kMacroCropLongSide,
        stepLong: kMacroStepLongSide,
      ),
    };

/// Level chip / note text with its cost, e.g. "Extreme Microscope · 🪙5".
String macroLevelCostLabel(
  String label,
  String level, {
  String quality = 'hd',
}) => '$label · 🪙${macroCreditsFor(level, quality: quality)}';
