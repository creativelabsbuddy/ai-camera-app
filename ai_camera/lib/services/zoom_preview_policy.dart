import 'dart:math' as math;

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

/// Each new reference must zoom at least this much further than the last.
const double kRefZoomStep = 1.5;

/// At most this many reference photos per zoom session.
const int kRefMax = 3;

/// The tracked view must have moved less than this between the last two
/// analysed frames (normalised units) to call the phone steady.
const double kRefMaxMotion = 0.02;

/// A full-resolution reference photo only when it can help: the zoom has
/// rested, the phone is steady and tracked, it is optically new (≥ 1.5×
/// the last reference, never above the camera's own max — a digital crop
/// adds no pixels), within the count, nothing busy, no flash. Pure.
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
}) {
  if (busy || !flashOff || !gyroSteady || !tracked) return false;
  if (motion > kRefMaxMotion) return false;
  if (zoomChangedAt != null && now.difference(zoomChangedAt) < kRefRest) {
    return false;
  }
  if (refZooms.length >= kRefMax) return false;
  final hw = hardwareMax.isFinite && hardwareMax >= 1 ? hardwareMax : 1.0;
  if (cameraZoom > hw + 0.01) return false;
  if (refZooms.isEmpty) return true;
  final last = refZooms.reduce(math.max);
  return cameraZoom >= last * kRefZoomStep - 0.01;
}
