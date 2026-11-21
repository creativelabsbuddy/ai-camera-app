import 'dart:math' as math;

import 'macro.dart' show MacroLevel;
import 'macro_box.dart' show macroLevelMaxZoom;

// v11.66 stepwise macro zoom: the zoom STOPS at fixed gates, the phone
// focuses and takes a photo there (Microscope / Extreme / Ultra also name
// the object in the centre box), and only then the next zoom range opens.
// At the shutter the gate photos (lowest first) + the final frame go to the
// AI. Pure helpers (tested); the camera work lives in the home screen.

/// Microscope / Extreme / Ultra reach 15x (clamped to the device max).
const double kMicroLevelMaxZoom = 15;

/// Microscope / Extreme / Ultra gates: object named at 1.5x, subject + part
/// checked again at 5x.
const List<double> kMicroGateZooms = [1.5, 5.0];

/// Focus settle after the centre AF pass at a gate, before the photo.
const Duration kMacroGateFocusWait = Duration(milliseconds: 450);

/// Laplacian variance (256 px grey copy of the user's region) below which
/// the final frame counts as FULLY blurry → no AI call, nothing charged.
/// Deliberately low: only a frame with no usable detail is refused.
const double kMicroFinalBlur = 8;

/// v11.66 fail-closed messages (no AI call, nothing charged).
const String kMicroTooBlurry =
    'Too close or blurry. Move back and zoom in instead.';
const String kMacroGateBusy = 'Hold steady · taking the zoom photo';
const String kMicroZoomFirst =
    'Zoom in to 1.5x first so the AI can see the object. No credits used.';

/// Max zoom for a level: Microscope / Extreme / Ultra 15x, the others 10x
/// (both clamped to the device max, never below 1x).
double macroLevelZoomMax(MacroLevel? level, double deviceMax) =>
    level != null && level.isMicroscopic
    ? math.max(1.0, math.min(kMicroLevelMaxZoom, deviceMax))
    : macroLevelMaxZoom(deviceMax);

/// Gate zooms of [level] that are reachable on this device (lowest first).
List<double> macroGateZooms(MacroLevel? level, double deviceMax) {
  if (level == null) return const [];
  final m = macroLevelZoomMax(level, deviceMax);
  final gates = level.isMicroscopic ? kMicroGateZooms : const <double>[];
  return [
    for (final z in gates)
      if (z < m - 0.01) z,
  ];
}

/// Highest zoom the user may reach now: the first gate not done yet, else
/// the level max.
double macroGateCap(MacroLevel? level, double deviceMax, Set<double> done) {
  for (final g in macroGateZooms(level, deviceMax)) {
    if (!done.contains(g)) return g;
  }
  return macroLevelZoomMax(level, deviceMax);
}

/// The gate to run now: the first gate not done, once the zoom reached it.
double? macroGateDue(
  MacroLevel? level,
  double deviceMax,
  Set<double> done,
  double zoom,
) {
  for (final g in macroGateZooms(level, deviceMax)) {
    if (done.contains(g)) continue;
    return zoom >= g - 0.01 ? g : null;
  }
  return null;
}

/// Gates to forget after zooming back out below them (they re-run on the
/// way in again — a new subject gets a new photo / name).
List<double> macroGatesToDrop(Iterable<double> done, double zoom) => [
  for (final g in done)
    if (zoom < g - 0.05) g,
];

/// Debug-line text for a gate result, e.g. "1.5x: white paper napkin ·
/// surface" / "5x: … · new subject".
String macroGateDebug(
  double gate,
  String? name,
  String part, {
  bool? newSubject,
}) {
  final z = gate == gate.roundToDouble()
      ? gate.toStringAsFixed(0)
      : gate.toStringAsFixed(1);
  final n = name == null
      ? 'detect failed'
      : (name.isEmpty ? '(vague)' : name);
  return [
    '${z}x: $n',
    if (part.isNotEmpty) part,
    if (newSubject == true) 'new subject',
  ].join(' · ');
}

/// The final frame is fully blurry (no usable detail).
bool microFinalTooBlurry(double sharpness) => sharpness < kMicroFinalBlur;

/// Lock from the gate results: the highest gate that produced one.
({String name, String part})? macroGateLock(
  Map<double, ({String name, String part})> info,
) {
  if (info.isEmpty) return null;
  final top = info.keys.reduce(math.max);
  return info[top];
}
