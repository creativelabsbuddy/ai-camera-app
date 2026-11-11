import 'dart:math' as math;

import 'zoom_root.dart' show isRootZoom;

/// v11.60 live preview while zooming (cheap phones): pure, unit-tested
/// policies. Continuous AF is left in charge; the app only nudges a centre
/// AF pass when the camera itself reports it is out of focus after the
/// zoom has rested, at most once per cooldown, never over a user tap/lock.

/// Zoom must rest this long before any AF nudge.
const Duration kZoomAfRest = Duration(milliseconds: 1200);

/// At most one nudge per this interval.
const Duration kZoomAfCooldown = Duration(seconds: 5);

/// After a nudge, hand focus back to continuous AF after this.
const Duration kZoomAfRelease = Duration(milliseconds: 2500);

/// Camera2 CONTROL_AF_STATE values that mean "not in focus".
const int kAfNotFocusedLocked = 5;
const int kAfPassiveUnfocused = 6;

/// Should the app nudge a centre AF pass now? Only with real evidence (the
/// camera's own AF state) — no state → no nudge. Pure.
bool zoomAfNudgeDue({
  required bool lowEnd,
  required bool backLens,
  required double zoom,
  required DateTime now,
  required DateTime? zoomChangedAt,
  required DateTime? lastNudgeAt,
  required int? afState,
  required bool userFocus,
  required bool busy,
}) {
  if (!lowEnd || !backLens || zoom < 2.0 || userFocus || busy) return false;
  if (zoomChangedAt == null || now.difference(zoomChangedAt) < kZoomAfRest) {
    return false;
  }
  if (lastNudgeAt != null && now.difference(lastNudgeAt) < kZoomAfCooldown) {
    return false;
  }
  return afState == kAfNotFocusedLocked || afState == kAfPassiveUnfocused;
}

/// AF/AE metering region size (fraction of the CAMERA frame) at
/// [digitalZoom]. The region follows the visible area but never shrinks
/// below 10 % (a tiny region makes cheap AF hunt). Pure.
double meteringSizeForZoom(double digitalZoom) {
  final dz = digitalZoom.isFinite && digitalZoom > 1 ? digitalZoom : 1.0;
  return (0.5 / dz).clamp(0.10, 0.15).toDouble();
}

/// Zoom must rest this long before a reference photo.
const Duration kRefRest = Duration(milliseconds: 700);

/// After a device rotation / lens switch: wait this long (and for a steady
/// phone) before rooting a new tracking chain.
const Duration kTrackSettle = Duration(milliseconds: 600);

/// Each new reference must zoom at least this much further than the last.
const double kRefZoomStep = 1.5;

/// v11.61: at most this many reference photos per zoom session (the low-zoom
/// ROOT + up to 3 tracked steps).
const int kRefMax = 4;

/// The tracked view must have moved less than this between the last two
/// analysed frames (normalised units) to call the phone steady.
const double kRefMaxMotion = 0.02;

/// A full-resolution reference photo only when it can help: the zoom has
/// rested, the phone is steady and tracked, within the count, nothing busy,
/// no flash.
///
/// v11.61 fix: the FIRST reference is the ROOT and must be taken at a low
/// zoom (1x–2x, or the device's true optical zoom: [opticalLimit]); deep
/// zoom without a root takes no reference at all (the shot then fails
/// closed unless the user captures the base photo). Later references must
/// be ≥ 1.5× the last one and never above the camera's own max. NOTE: a
/// camera zoom above the optical limit — including the camera's own ISP
/// crop up to its hardware max — is a DIGITAL crop (no new real pixels);
/// such references help tracking / focus only and are labelled digital
/// ([refZoomLabel]). Pure.
bool shouldCaptureReference({
  required double cameraZoom,
  required double hardwareMax,
  required List<double> refZooms,
  required DateTime now,
  required DateTime? zoomChangedAt,
  required bool gyroSteady,
  required bool tracked,
  required double motion,
  required bool busy,
  required bool flashOff,
  double opticalLimit = 1.0,
}) {
  if (busy || !flashOff || !gyroSteady || !tracked) return false;
  if (motion > kRefMaxMotion) return false;
  if (zoomChangedAt != null && now.difference(zoomChangedAt) < kRefRest) {
    return false;
  }
  if (refZooms.length >= kRefMax) return false;
  final hw = hardwareMax.isFinite && hardwareMax >= 1 ? hardwareMax : 1.0;
  if (cameraZoom > hw + 0.01) return false;
  if (refZooms.isEmpty) return isRootZoom(cameraZoom, opticalLimit);
  final last = refZooms.reduce(math.max);
  return cameraZoom >= last * kRefZoomStep - 0.01;
}
