import 'dart:math' as math;

import 'optical_profile.dart';
import 'zoom_range.dart';

/// Samsung-style zoom chips.
///
/// * [primary] – the device's real lens / optical-quality range, derived from
///   the detected lenses (nothing per-model): ultra-wide (if the camera goes
///   below 1x), 1x, 2x (in-sensor crop / quick zoom), every usable optical
///   lens factor (e.g. 3x, 5x) and finally ~2× the best optical lens as the
///   last "optical quality" chip (S24 Ultra 5x → 10x). Cheap phone without a
///   tele → just [.6,] 1, 2.
/// * [extended] – v9: no longer shown as chips. 10 / 30 / 100 (within the
///   display max) become labelled shortcut ticks on the continuous zoom
///   ruler (long-press / drag the pill).
///
/// Pinch and the ruler reach the full display range (100x on the back
/// camera); the last chip shows the live value beyond it (e.g. "22×").
class ZoomChipSet {
  const ZoomChipSet({required this.primary, required this.extended});

  static const ZoomChipSet single = ZoomChipSet(
    primary: [ZoomStop(1, '1')],
    extended: [],
  );

  final List<ZoomStop> primary;
  final List<ZoomStop> extended;

  /// Chips in the pill (v9: always just the lens chips).
  List<ZoomStop> visible(double zoom) => primary;

  /// Lens chip values → haptic ticks on the ruler.
  List<double> get lensValues => [for (final s in primary) s.value];

  /// Labelled shortcut ticks on the ruler (10 / 30 / 100 …).
  List<double> get shortcutValues => [for (final s in extended) s.value];

  /// Index into [visible] of the chip that shows the live zoom: the highest
  /// chip at or below [zoom] (first chip when below all of them).
  int activeIndex(double zoom) {
    final v = visible(zoom);
    var idx = 0;
    for (var i = 0; i < v.length; i++) {
      if (v[i].value <= zoom + 0.01) idx = i;
    }
    return idx;
  }

  @override
  String toString() => 'ZoomChipSet(primary=$primary, extended=$extended)';
}

/// Chip text: ".6" for ultra-wide (Samsung style), "1", "2.4", "10", "100".
String formatChipZoom(double z) {
  final s = formatZoom(z);
  return (z < 1 && s.startsWith('0.')) ? s.substring(1) : s;
}

const double _sameChip = 0.05;

List<ZoomStop> _dedupe(List<double> values) {
  values.sort();
  final out = <ZoomStop>[];
  for (final v in values) {
    if (out.isNotEmpty && (v - out.last.value).abs() / v < _sameChip) continue;
    out.add(ZoomStop(v, formatChipZoom(v)));
  }
  return out;
}

ZoomChipSet buildZoomChipSet(
  ZoomRange r, {
  OpticalProfile optical = OpticalProfile.fallback,
}) {
  final maxV = r.displayMax;
  if (maxV <= 1.0 + 0.01 && r.minZoom >= 0.99) return ZoomChipSet.single;

  bool fits(double v) => v.isFinite && v > 1.0 + 0.01 && v <= maxV * 1.001;

  final primaryValues = <double>[if (r.minZoom < 0.99) _round1(r.minZoom), 1.0];
  final tele = <double>[
    2.0,
    ...optical.usableFactors,
    optical.opticalLimit,
    2 * optical.bestOptical,
  ].where(fits).toList();
  primaryValues.addAll(tele);
  final primary = _dedupe(primaryValues);
  // Chip must hit the exact min zoom (e.g. 0.55 shown as ".6").
  if (r.minZoom < 0.99) {
    primary[0] = ZoomStop(r.minZoom, formatChipZoom(r.minZoom));
  }

  final last = primary.last.value;
  final ext = <double>[
    for (final v in const [10.0, 30.0, 100.0])
      if (v > last * 1.25 && v <= maxV * 1.001) v,
  ];
  // Short ranges (front camera 1–8x): one chip at the max.
  if (maxV > last * 1.25 && (ext.isEmpty || ext.last < maxV * 0.95)) {
    ext.add(maxV);
  }
  final extended = _dedupe(ext);
  return ZoomChipSet(primary: primary, extended: extended);
}

double _round1(double v) => math.max(0.1, (v * 10).roundToDouble() / 10);
