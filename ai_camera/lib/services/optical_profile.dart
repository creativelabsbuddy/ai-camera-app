import 'dart:math' as math;

import 'zoom_info.dart';
import 'zoom_range.dart';

/// Above `opticalLimit × aiRecoverableMultiple` the AI can no longer
/// genuinely recover detail — results become the model's guess. Zoom is still
/// allowed; the badge just shows a warning.
const double aiRecoverableMultiple = 7.0;

/// A main sensor at or above this many megapixels gives a clean 2x in-sensor
/// crop ("optical quality" 2x on many cheap 50MP phones).
const double highResSensorMp = 40.0;

const double _eps = 0.02;

/// Per-device optical zoom facts derived from the Camera2 probe. Nothing is
/// hardcoded per phone model.
///
/// * [usableFactors] – optical factors of lenses the app can actually reach
///   through the camera CameraX opens (logical camera + its physical lenses,
///   within the zoom-ratio range it exposes). E.g. S24 Ultra → [0.6, 1, 3, 5].
/// * [allFactors] – every back lens seen (including ones hidden from
///   third-party apps).
/// * [bestOptical] – the "best available lens": highest usable factor ≥ 1.
/// * [opticalLimit] – optical-quality zoom: max(bestOptical, 2x in-sensor crop
///   on a ≥40MP main sensor). Free users get AI enhance up to here.
class OpticalProfile {
  const OpticalProfile({
    required this.usableFactors,
    required this.allFactors,
    required this.bestOptical,
    required this.sensorCropFactor,
    required this.opticalLimit,
    required this.appMaxZoom,
    required this.fromCamera2,
  });

  /// Used when the native probe is unavailable (front camera, gallery, web,
  /// probe failure): plain 1x main lens, conservative.
  static const OpticalProfile fallback = OpticalProfile(
    usableFactors: [1.0],
    allFactors: [1.0],
    bestOptical: 1.0,
    sensorCropFactor: 1.0,
    opticalLimit: 1.0,
    appMaxZoom: null,
    fromCamera2: false,
  );

  final List<double> usableFactors;
  final List<double> allFactors;
  final double bestOptical;
  final double sensorCropFactor;
  final double opticalLimit;

  /// Max zoom ratio the primary back camera exposes to third-party apps.
  final double? appMaxZoom;
  final bool fromCamera2;

  /// A longer tele exists on the phone but is not reachable by this app
  /// (e.g. some Samsung models hide it from third-party apps).
  bool get teleNotExposed {
    final maxAll = allFactors.isEmpty ? 1.0 : allFactors.reduce(math.max);
    return maxAll > bestOptical + _eps;
  }

  /// ~7× the optical limit: beyond this results are mostly AI guesswork.
  double get aiRecoverableLimit => opticalLimit * aiRecoverableMultiple;

  /// True when [zoom] is past optical quality (free users: AI is Pro only).
  bool isAboveOptical(double zoom) =>
      zoom.isFinite && zoom > opticalLimit * (1 + _eps);

  /// True when [zoom] is past the AI-recoverable limit (warning badge).
  bool isBeyondRecoverable(double zoom) =>
      zoom.isFinite && zoom > aiRecoverableLimit * (1 + _eps / 2);

  /// zoom / opticalLimit, never below 1.
  double overOptical(double zoom) =>
      (!zoom.isFinite || zoom <= 0) ? 1.0 : math.max(1.0, zoom / opticalLimit);

  @override
  String toString() =>
      'OpticalProfile(usable=$usableFactors, all=$allFactors, best=$bestOptical, '
      'crop=$sensorCropFactor, limit=$opticalLimit, appMax=$appMaxZoom, '
      'camera2=$fromCamera2)';
}

double _round2(double v) => (v * 100).roundToDouble() / 100;

/// Snaps a measured multiplier (4.83 → 5, 2.9 → 3, 0.55 stays 0.55).
double _snap(double m) => _round2(nominalMultiplier(m));

/// Builds the [OpticalProfile] from the native probe.
///
/// Usable lenses = the primary back camera (the one CameraX opens) and, for a
/// logical multi-camera, its physical sub-lenses whose factor is within the
/// zoom ratio range the camera exposes ([controllerMax] / probe max). Hidden
/// ids or separately listed lenses CameraX never switches to are ignored.
OpticalProfile computeOpticalProfile(
  NativeZoomInfo? info, {
  double? controllerMax,
}) {
  if (info == null) return OpticalProfile.fallback;
  final back = info.backCameras;
  if (back.isEmpty) return OpticalProfile.fallback;

  CameraLensInfo? primary;
  for (final c in back) {
    if (c.id == info.primaryBackId) primary = c;
  }
  primary ??= back.first;

  final appMax =
      <double?>[
            primary.zoomRatioMax,
            primary.reportedMaxZoom,
            info.reportedMaxZoom,
            controllerMax,
          ]
          .whereType<double>()
          .where((v) => v.isFinite && v > 0)
          .fold<double?>(null, (a, b) => a == null ? b : math.max(a, b));

  final reachableIds = <String>{primary.id, ...primary.physicalIds};
  final lenses = back.where((c) => !c.isLogical).toList();

  final all = <double>{};
  for (final c in lenses) {
    final m = c.opticalMultiplier;
    if (m != null && m.isFinite && m > 0) all.add(_snap(m));
  }

  final usable = <double>{};
  for (final c in lenses) {
    if (!reachableIds.contains(c.id)) continue;
    final m = c.opticalMultiplier;
    if (m == null || !m.isFinite || m <= 0) continue;
    final s = _snap(m);
    // Lens needs a zoom ratio the camera actually lets us request.
    if (appMax != null && s > appMax * 1.05) continue;
    usable.add(s);
  }
  // Non-logical primary (single lens) without its own multiplier = main 1x.
  if (usable.isEmpty) usable.add(1.0);
  if (!usable.any((f) => (f - 1.0).abs() < 0.05)) usable.add(1.0);
  if (all.isEmpty) all.addAll(usable);

  final usableSorted = usable.toList()..sort();
  final allSorted = all.toList()..sort();
  final best = math.max(1.0, usableSorted.last);

  // Main lens megapixels → in-sensor 2x crop counts as optical quality.
  CameraLensInfo? main;
  for (final c in back) {
    if (c.isMain) main = c;
  }
  main ??= primary;
  final mp = main.megapixels ?? 0;
  final crop = mp >= highResSensorMp ? 2.0 : 1.0;

  return OpticalProfile(
    usableFactors: usableSorted,
    allFactors: allSorted,
    bestOptical: best,
    sensorCropFactor: crop,
    opticalLimit: math.max(best, crop),
    appMaxZoom: appMax,
    fromCamera2: true,
  );
}
