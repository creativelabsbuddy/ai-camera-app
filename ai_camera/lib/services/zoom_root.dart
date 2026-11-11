import 'dart:math' as math;

import 'ai_call.dart' show kNoSharpSourceMessage;

/// v11.61 ROOT reference + real-pixel gate (cheap phones, zoom ladder).
///
/// Quality comes only from detail the sensor really captured. Before the
/// user zooms deep, ONE sharp photo is kept at a LOW zoom (1x–2x, or the
/// device's true optical zoom): the root. Tracking locates the final framing
/// inside it; its region (ROI) is what the AI works from.
///
/// Camera zoom ratios above the true optical zoom are DIGITAL crops (the
/// camera's own ISP crop up to its hardware max included): they add no real
/// pixels. Every reference is labelled with its optical part vs its digital
/// crop, and the real pixel count of the ROI decides whether the result can
/// be clear ("Beyond clear range, AI-enhanced" past the per-device limit) or
/// must fail closed (ROI absurdly tiny: no AI call, nothing charged).

/// The root is taken at or below this camera zoom (or the true optical zoom
/// when that is higher, e.g. a real 3x telephoto).
const double kRootMaxZoom = 2.0;

/// Real pixels on the ROI's long side for a result to count as clear.
const int kClearRoiPx = 384;

/// Below this many real pixels on the ROI's long side → fail closed.
const int kRoiMinRealPx = 32;

/// Still long side assumed before the phone's own root still is known.
const int kDefaultStillLong = 4000;

/// SharedPreferences key: long side of the last root still (live label
/// before a root exists).
const String kRootStillLongKey = 'zoom_root_still_long_v1';

/// In-app labels (English).
const String kBeyondClearLabel = 'Beyond clear range, AI-enhanced';
const String kHoldLowerZoomFirst =
    'Hold steady at lower zoom first. No credits used.';
const String kRootMissingHint = 'Tap to capture a clear base photo first';
const String kRoiTooTinyMessage =
    'Zoomed too far for this phone to capture real detail. Zoom out a little. '
    'No credits used.';

/// Highest camera zoom a root may be taken at. Pure.
double rootMaxZoom(double opticalLimit) => math.max(
  kRootMaxZoom,
  opticalLimit.isFinite && opticalLimit >= 1 ? opticalLimit : 1.0,
);

/// Is [cameraZoom] low enough to be the root? Pure.
bool isRootZoom(double cameraZoom, double opticalLimit) =>
    cameraZoom.isFinite &&
    cameraZoom > 0 &&
    cameraZoom <= rootMaxZoom(opticalLimit) + 0.01;

/// A reference's REAL zoom: the optical part (lens factor or in-sensor
/// crop of a high-resolution main sensor) and the digital crop on top.
class RefZoomLabel {
  const RefZoomLabel(this.cameraZoom, this.optical);
  final double cameraZoom;

  /// Optical-quality part of [cameraZoom] (≥ 1).
  final double optical;

  /// Digital crop on top of the optical part (1 = none).
  double get digital => cameraZoom / optical;
  bool get isOptical => digital <= 1.01;

  /// Real sensor pixels per still pixel (≤ 1 for a digital crop).
  double get realScale => math.min(1.0, 1 / digital);

  /// "opt 1x" / "opt 1x + dig 4.0x".
  String get text {
    String z(double v) => v == v.roundToDouble()
        ? '${v.toStringAsFixed(0)}x'
        : '${v.toStringAsFixed(1)}x';
    return isOptical
        ? 'opt ${z(optical)}'
        : 'opt ${z(optical)} + dig ${digital.toStringAsFixed(1)}x';
  }
}

/// Splits a camera zoom into optical vs digital. [lensFactors] = usable
/// lens factors (1 = main), [sensorCrop] = in-sensor crop factor of the
/// main lens (2 on ≥40 MP sensors, else 1). A digital crop up to the
/// camera's hardware max is NOT optical. Pure.
RefZoomLabel refZoomLabel(
  double cameraZoom, {
  List<double> lensFactors = const [1.0],
  double sensorCrop = 1.0,
}) {
  final cam = cameraZoom.isFinite && cameraZoom > 0 ? cameraZoom : 1.0;
  var opt = 1.0;
  for (final f in lensFactors) {
    if (f >= 1 && f <= cam + 0.01 && f > opt) opt = f;
  }
  if (sensorCrop > 1) opt = math.max(opt, math.min(cam, sensorCrop));
  return RefZoomLabel(cam, math.min(opt, math.max(1.0, cam)));
}

/// Real pixels on the long side of the final framing inside a reference
/// still of long side [stillLong] taken with [label], final zoom
/// [finalZoom]. Pure.
double realRoiPx({
  required int stillLong,
  required RefZoomLabel label,
  required double finalZoom,
}) {
  if (stillLong <= 0 || !finalZoom.isFinite || finalZoom <= 0) return 0;
  final frac = math.min(1.0, label.cameraZoom / finalZoom);
  return stillLong * frac * label.realScale;
}

/// Per-device clear limit: the zoom where the root's real ROI falls below
/// [kClearRoiPx] (never below the optical limit). Pure.
double pixelClearLimit({
  required int stillLong,
  required double rootOptical,
  double opticalLimit = 1,
}) {
  final long = stillLong > 0 ? stillLong : kDefaultStillLong;
  final opt = rootOptical.isFinite && rootOptical >= 1 ? rootOptical : 1.0;
  return math.max(
    opticalLimit.isFinite && opticalLimit >= 1 ? opticalLimit : 1.0,
    long * opt / kClearRoiPx,
  );
}

/// Zoom past the clear limit → label "Beyond clear range, AI-enhanced". Pure.
bool beyondClearRange(double zoom, double clearLimit) =>
    zoom.isFinite && clearLimit.isFinite && zoom > clearLimit + 0.01;

/// ROI too small to hold real detail → fail closed. Pure.
bool roiTooTiny(double realPx) => !(realPx >= kRoiMinRealPx);

/// The live note while zooming (null = none). Pure.
String? liveZoomNote({
  required bool ladderMode,
  required double zoom,
  required double opticalLimit,
  required bool hasRoot,
  required double clearLimit,
}) {
  if (!ladderMode) return null;
  if (!hasRoot && zoom > rootMaxZoom(opticalLimit) + 0.01) {
    return kRootMissingHint;
  }
  if (beyondClearRange(zoom, clearLimit)) return kBeyondClearLabel;
  return null;
}

/// v11.61 shutter verdict (ladder): fail closed — no AI call, nothing
/// charged — when a sharp source is needed and none was usable, or the
/// root's region is absurdly tiny. There is no "final is sharp enough"
/// exemption any more. Pure.
bool zoomFailClosed({
  required bool ok,
  required bool need,
  required bool tiny,
}) => tiny || (need && !ok);

/// The message shown when the shot fails closed. Pure.
String zoomFailMessage({required bool tiny, required bool hasRoot}) => tiny
    ? kRoiTooTinyMessage
    : hasRoot
    ? kNoSharpSourceMessage
    : kHoldLowerZoomFirst;
