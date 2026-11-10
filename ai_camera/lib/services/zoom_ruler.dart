import 'dart:math' as math;

/// Continuous Samsung-style zoom ruler: pure mapping between a ruler
/// position (0..1, logarithmic so 1x→2x takes as much room as 10x→20x) and
/// the user-facing zoom, plus quantisation and haptic tick detection.
///
/// Fine steps: 0.1x below 10x, 1x steps from 10x up (10, 11, … 100).
class ZoomRulerScale {
  ZoomRulerScale({required double min, required double max})
    : min = (min.isFinite && min > 0) ? min : 1.0,
      max = math.max(
        (min.isFinite && min > 0) ? min : 1.0,
        max.isFinite ? max : 1.0,
      );

  final double min;
  final double max;

  double get _lnMin => math.log(min);
  double get _span => math.log(max) - _lnMin;

  /// Ruler position (0 = min, 1 = max) of [zoom].
  double positionOf(double zoom) {
    if (_span <= 0) return 0;
    final z = zoom.clamp(min, max).toDouble();
    return ((math.log(z) - _lnMin) / _span).clamp(0.0, 1.0);
  }

  /// Raw (unquantised) zoom at ruler position [t].
  double zoomAt(double t) {
    if (_span <= 0) return min;
    return math.exp(_lnMin + _span * t.clamp(0.0, 1.0));
  }

  /// Quantised zoom at [t] (what the ruler label shows and the camera gets).
  double snappedAt(double t) => quantizeZoom(zoomAt(t), min: min, max: max);

  /// Horizontal scrub: moving the finger LEFT by [dx] (negative) zooms IN,
  /// like dragging a ruler under a fixed centre needle. [extent] = pixels
  /// for the whole min→max range.
  double scrub({
    required double from,
    required double dx,
    required double extent,
  }) {
    if (extent <= 0) return quantizeZoom(from, min: min, max: max);
    return snappedAt(positionOf(from) - dx / extent);
  }
}

/// 0.1x steps below 10x, 0.5x steps 10x–30x, 1x above; clamped to [min, max].
/// The exact min (e.g. 0.55 ultra-wide) and max stay reachable.
double quantizeZoom(double z, {required double min, required double max}) {
  if (!z.isFinite) return min;
  final c = z.clamp(min, max).toDouble();
  // v11.42: 0.5x steps from 10x to 30x (smoother high zoom), 1x above.
  final q = c < 10 - 0.05
      ? (c * 10).roundToDouble() / 10
      : c < 30 - 0.25
      ? (c * 2).roundToDouble() / 2
      : c.roundToDouble();
  // Keep the exact ends reachable (e.g. a 0.55x ultra-wide) when they are
  // closer than the nearest step.
  if (q <= min || (c - min).abs() < (q - c).abs()) return min;
  if (q >= max || (max - c).abs() < (q - c).abs()) return max;
  return q;
}

/// Big centred ruler label: "0.6x", "2.4x", "22.0x", "100.0x".
String formatRulerLabel(double z) => '${z.toStringAsFixed(1)}x';

/// Lens chips crossed (or landed on) moving from [from] to [to] — one
/// haptic tick each. Exclusive of [from] so holding still never re-ticks.
List<double> crossedTicks(double from, double to, Iterable<double> ticks) {
  if (from == to) return const [];
  final lo = math.min(from, to);
  final hi = math.max(from, to);
  const eps = 1e-6;
  return [
    for (final t in ticks)
      if (from < to
          ? (t > lo + eps && t <= hi + eps)
          : (t < hi - eps && t >= lo - eps))
        t,
  ];
}

enum RulerTickKind { minor, medium, major }

class RulerTick {
  const RulerTick(this.zoom, this.kind, [this.label]);

  final double zoom;
  final RulerTickKind kind;
  final String? label;

  @override
  String toString() =>
      'Tick($zoom ${kind.name}${label == null ? '' : ' "$label"'})';
}

String _tickLabel(double v) {
  final s = v == v.roundToDouble()
      ? v.toInt().toString()
      : v.toStringAsFixed(1);
  return (v < 1 && s.startsWith('0.')) ? s.substring(1) : s;
}

/// Ticks for the ruler painter: majors (labelled) at lens chips and the
/// 10/30/100 shortcuts, mediums at whole numbers below 10 and every 5x
/// above, minors every 0.5x below 10 and every 1x… thinned so they never
/// get closer than [minGap] in position units.
List<RulerTick> buildRulerTicks(
  ZoomRulerScale scale, {
  required Iterable<double> lensChips,
  Iterable<double> shortcuts = const [],
  double minGap = 0.006,
}) {
  final majors = <double>{
    for (final v in [...lensChips, ...shortcuts])
      if (v >= scale.min - 1e-9 && v <= scale.max + 1e-9) v,
  };
  final out = <RulerTick>[];
  final candidates = <(double, RulerTickKind)>[];
  for (
    var v = (scale.min * 2).ceil() / 2;
    v <= math.min(10, scale.max) + 1e-9;
    v += 0.5
  ) {
    candidates.add((
      v,
      v == v.roundToDouble() ? RulerTickKind.medium : RulerTickKind.minor,
    ));
  }
  for (var v = 11.0; v <= scale.max + 1e-9; v += 1) {
    candidates.add((
      v,
      v % 5 == 0 ? RulerTickKind.medium : RulerTickKind.minor,
    ));
  }
  for (final m in majors) {
    out.add(RulerTick(m, RulerTickKind.major, _tickLabel(m)));
  }
  var lastPos = -1.0;
  candidates.sort((a, b) => a.$1.compareTo(b.$1));
  for (final (v, k) in candidates) {
    if (majors.any((m) => (m - v).abs() < 1e-6)) continue;
    final pos = scale.positionOf(v);
    if (k == RulerTickKind.minor && pos - lastPos < minGap) continue;
    out.add(RulerTick(v, k));
    lastPos = pos;
  }
  out.sort((a, b) => a.zoom.compareTo(b.zoom));
  return out;
}
