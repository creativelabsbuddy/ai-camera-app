import 'dart:math' as math;

/// Pure-Dart zoom range logic (no Flutter / platform imports) so it can be
/// unit tested.
///
/// Terms:
/// * **controllerMax** – what `CameraController.getMaxZoomLevel()` reports
///   (CameraX → Camera2 `CONTROL_ZOOM_RATIO_RANGE.upper`). This is the most
///   that can be passed to `setZoomLevel`.
/// * **deviceMax** – max(controllerMax, native reportedMaxZoom). The phone's
///   real processing limit; never raised.
/// * **displayMax** – range shown on chips / pinch. Back camera: 100x for
///   every user and every phone (no Pro gate). Anything above the camera's
///   own max is a centre digital crop of the preview + the full-res still.
///
/// AI gating (optical limit, Pro, credits) lives in optical_profile.dart and
/// entitlements.dart — zoom itself is never limited by it.

const double _eps = 0.01;

/// Max user zoom on the back camera (all users, all phones).
const double kMaxUserZoom = 100.0;

/// Common marketing multipliers. Measured ratios (35mm-eq focal / main) are
/// a bit off (S24 Ultra 5x ≈ 111/23 = 4.83, 3x ≈ 2.9), so snap to these
/// when within [_nominalTolerance].
const List<double> _nominalMultipliers = [2, 3, 4, 5, 6, 10];
const double _nominalTolerance = 0.10;

/// Snaps a measured optical multiplier to the nearest nominal value
/// (2/3/4/5/6/10x) when within 10%, else returns it unchanged.
double nominalMultiplier(double measured) {
  if (!measured.isFinite || measured <= 0) return measured;
  for (final n in _nominalMultipliers) {
    if ((measured - n).abs() / n <= _nominalTolerance) return n;
  }
  return measured;
}

/// Largest snapped multiplier >= 1.5 from [multipliers], or null.
double? teleMultiplierFrom(Iterable<double> multipliers) {
  double? best;
  for (final m in multipliers) {
    if (!m.isFinite) continue;
    final n = nominalMultiplier(m);
    if (n < 1.5) continue;
    if (best == null || n > best) best = n;
  }
  return best;
}

/// deviceMax = max(controllerMax, nativeReportedMax). Invalid values ignored.
double computeDeviceMax({
  required double controllerMax,
  double? nativeReportedMax,
}) {
  var m = (controllerMax.isFinite && controllerMax > 0) ? controllerMax : 1.0;
  final n = nativeReportedMax;
  if (n != null && n.isFinite && n > m) m = n;
  return m;
}

/// displayMax = max(deviceMax, [target]). Back camera passes
/// [kMaxUserZoom] (100x for everyone); front camera passes null → deviceMax.
double computeDisplayMax({required double deviceMax, double? target}) {
  if (target == null || !target.isFinite || target <= deviceMax) {
    return deviceMax;
  }
  return target;
}

class ZoomRange {
  const ZoomRange({
    required this.minZoom,
    required this.controllerMax,
    required this.deviceMax,
    required this.displayMax,
    this.nativeReportedMax,
    this.teleMultiplier,
  });

  /// Single-zoom fallback (camera without zoom).
  static const ZoomRange none = ZoomRange(
    minZoom: 1,
    controllerMax: 1,
    deviceMax: 1,
    displayMax: 1,
  );

  final double minZoom;
  final double controllerMax;
  final double deviceMax;
  final double displayMax;
  final double? nativeReportedMax;
  final double? teleMultiplier;

  /// True when chips/pinch go past the device's own max (digital-crop zone).
  bool get extended => displayMax > deviceMax + _eps;

  /// Max zoom value actually sent to the camera.
  double get hardwareMax => math.min(controllerMax, deviceMax);

  @override
  String toString() =>
      'ZoomRange(min=$minZoom, controller=$controllerMax, native=$nativeReportedMax, '
      'tele=$teleMultiplier, device=$deviceMax, display=$displayMax)';
}

ZoomRange computeZoomRange({
  required double controllerMin,
  required double controllerMax,
  double? nativeReportedMax,
  double? teleMultiplier,
  double? displayTarget = kMaxUserZoom,
}) {
  var minZoom = (controllerMin.isFinite && controllerMin > 0)
      ? controllerMin
      : 1.0;
  var cMax = (controllerMax.isFinite && controllerMax > 0)
      ? controllerMax
      : 1.0;
  if (cMax < minZoom) cMax = minZoom;
  final deviceMax = computeDeviceMax(
    controllerMax: cMax,
    nativeReportedMax: nativeReportedMax,
  );
  final displayMax = computeDisplayMax(
    deviceMax: deviceMax,
    target: displayTarget,
  );
  if (minZoom > displayMax) minZoom = 1.0;
  return ZoomRange(
    minZoom: minZoom,
    controllerMax: cMax,
    deviceMax: deviceMax,
    displayMax: displayMax,
    nativeReportedMax: nativeReportedMax,
    teleMultiplier: teleMultiplier,
  );
}

class ZoomStop {
  const ZoomStop(this.value, this.label);

  /// Selected (user-facing) zoom value.
  final double value;

  /// Chip text without the trailing "x".
  final String label;

  @override
  String toString() => '${label}x@$value';
}

String formatZoom(double z) {
  if (z >= 10) return z.round().toString();
  final s = z.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/// Chips: [min if < 1], 1x, 2, 3, 5, 10, 30, 100 (within displayMax), plus
/// displayMax rounded and any extra [opticalFactors] (real lens factors such
/// as 3.5x) not already near a chip. When the range is extended past
/// deviceMax, a chip sits exactly at deviceMax (last zoom with no digital
/// crop).
List<ZoomStop> buildZoomStops(
  ZoomRange r, {
  Iterable<double> opticalFactors = const [],
}) {
  final stops = <ZoomStop>[];
  final maxV = r.displayMax;
  if (r.minZoom < 1.0 - _eps) {
    stops.add(ZoomStop(r.minZoom, formatZoom(r.minZoom)));
  }
  stops.add(ZoomStop(1.0.clamp(r.minZoom, maxV).toDouble(), '1'));
  final values = <double>[2.0, 3.0, 5.0, 10.0, 30.0, 100.0];
  for (final f in opticalFactors) {
    if (!f.isFinite || f <= 1.0 + _eps || f > maxV + _eps) continue;
    if (values.any((v) => (v - f).abs() / v < 0.05)) continue;
    values.add(f);
  }
  values.sort();
  for (final v in values) {
    if (v <= maxV + _eps) stops.add(ZoomStop(v, formatZoom(v)));
  }

  if (r.extended && r.deviceMax > 1.0 + _eps) {
    final d = r.deviceMax;
    final near = stops.indexWhere((s) => (s.value - d).abs() / d < 0.05);
    if (near >= 0) {
      stops[near] = ZoomStop(d, stops[near].label);
    } else {
      final at = stops.indexWhere((s) => s.value > d);
      final chip = ZoomStop(d, formatZoom(d));
      if (at < 0) {
        stops.add(chip);
      } else {
        stops.insert(at, chip);
      }
    }
  }

  if (maxV > 1.0 + _eps) {
    final last = stops.last;
    if (maxV / last.value > 1.05) {
      stops.add(ZoomStop(maxV, formatZoom(maxV)));
    } else if (last.value != maxV) {
      // e.g. max 10.2 -> keep "10" label but let the chip reach the true max.
      stops[stops.length - 1] = ZoomStop(maxV, last.label);
    }
  }
  return stops;
}

/// How a requested zoom is realised.
class ZoomPlan {
  const ZoomPlan({
    required this.selected,
    required this.cameraZoom,
    required this.digitalZoom,
  });

  /// Effective user-facing zoom (what the chip label shows).
  final double selected;

  /// Value passed to `CameraController.setZoomLevel`.
  final double cameraZoom;

  /// Extra centre crop on top of the camera zoom (preview Transform.scale +
  /// capture crop). 1.0 = none.
  final double digitalZoom;

  /// True field of view vs the main lens' 1x (full 4:3 frame):
  /// CameraX zoomRatio × digital crop. Always equals [selected].
  double get effectiveZoom => cameraZoom * digitalZoom;
}

/// Zoom calibration (same convention as the stock camera):
/// * 1x = the main wide lens' full frame. CameraX/Camera2 `zoomRatio` is
///   defined relative to exactly that FOV (0.6 = ultra-wide), so the camera
///   part needs no extra factor.
/// * Displayed N× = cameraZoom × digitalZoom. The digital crop is a centre
///   crop of the frame the camera delivers at [ZoomPlan.cameraZoom], applied
///   identically to the preview (Transform.scale) and the full-res still
///   (computeCaptureCrop), so at 100x the saved photo spans 1/100 of the 1x
///   frame on both axes.
/// * The frame ratio never changes the zoom: 9:16 keeps the full height and
///   crops the width (like Samsung's 9:16), so a 9:16 view looks ~1.33×
///   tighter horizontally than 4:3 at the same N×. Compare zoom with the
///   stock camera in the SAME ratio.

/// Selection is clamped to [minZoom, displayMax] for everyone (no Pro gate).
/// The camera itself is clamped to [ZoomRange.hardwareMax]; anything above is
/// a centre digital crop = selected / cameraZoom (e.g. S24 Ultra 100x =
/// camera 10x × digital 10x).
ZoomPlan planZoom({required double requested, required ZoomRange range}) {
  final req = requested.isFinite ? requested : 1.0;
  final selected = req
      .clamp(range.minZoom, math.max(range.displayMax, range.minZoom))
      .toDouble();
  final camera = selected
      .clamp(range.minZoom, math.max(range.hardwareMax, range.minZoom))
      .toDouble();
  final digital = camera > 0 ? math.max(1.0, selected / camera) : 1.0;
  return ZoomPlan(selected: selected, cameraZoom: camera, digitalZoom: digital);
}
