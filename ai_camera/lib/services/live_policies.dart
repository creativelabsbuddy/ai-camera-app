import 'dart:math' as math;
import 'dart:ui';

import '../models/shoot_mode.dart';

/// A face from the live stream, in FRAME-normalised display coordinates.
class LiveFace {
  const LiveFace({
    required this.box,
    this.smiling,
    this.trackingId,
    this.parts = const {},
  });
  final Rect box;

  /// v11.10 landmarks, normalised like [box]: leftEye, rightEye, mouth,
  /// nose (missing → typical face proportions are used).
  final Map<String, Offset> parts;
  final double? smiling;
  final int? trackingId;
  Offset get center => box.center;
  double get area => box.width * box.height;
}

/// Smile shot: auto-capture when someone smiles (≥ [threshold]) in
/// [needed] consecutive analyses; then [cooldown] before the next one.
class SmileTrigger {
  SmileTrigger({
    this.threshold = 0.8,
    this.needed = 2,
    this.cooldown = const Duration(seconds: 4),
  });

  final double threshold;
  final int needed;
  final Duration cooldown;
  int _streak = 0;
  DateTime? _last;

  bool update(List<LiveFace> faces, DateTime now) {
    final smiling = faces.any((f) => (f.smiling ?? 0) >= threshold);
    _streak = smiling ? _streak + 1 : 0;
    if (_streak < needed) return false;
    if (_last != null && now.difference(_last!) < cooldown) return false;
    _last = now;
    _streak = 0;
    return true;
  }
}

/// Face-priority focus: meter on the largest face when the user hasn't
/// tapped. Re-meters only when the face moved/grew noticeably or after
/// [refresh] (avoids AF "breathing").
class FaceFocusPolicy {
  FaceFocusPolicy({
    this.minInterval = const Duration(milliseconds: 1500),
    this.refresh = const Duration(seconds: 6),
    this.moveThreshold = 0.08,
  });

  final Duration minInterval;
  final Duration refresh;
  final double moveThreshold;
  Offset? _lastPoint;
  double? _lastArea;
  DateTime? _lastAt;

  /// The point to meter (frame-normalised), or null = leave focus alone.
  Offset? decide(
    List<LiveFace> faces,
    DateTime now, {
    required bool userFocusActive,
  }) {
    if (userFocusActive || faces.isEmpty) {
      if (faces.isEmpty) {
        _lastPoint = null;
        _lastArea = null;
      }
      return null;
    }
    final f = faces.reduce((a, b) => a.area >= b.area ? a : b);
    if (f.area < 0.004) return null; // tiny / far faces: continuous AF
    final at = _lastAt;
    if (at != null && now.difference(at) < minInterval) return null;
    final lp = _lastPoint;
    final moved =
        lp == null ||
        (f.center - lp).distance > moveThreshold ||
        ((_lastArea ?? 0) > 0 && (f.area / _lastArea! - 1).abs() > 0.35);
    final stale = at == null || now.difference(at) >= refresh;
    if (!moved && !stale) return null;
    _lastPoint = f.center;
    _lastArea = f.area;
    _lastAt = now;
    return f.center;
  }

  /// Best AF point for the shutter when no tap: largest face, else null.
  static Offset? captureFocusPoint(List<LiveFace> faces) {
    if (faces.isEmpty) return null;
    return faces.reduce((a, b) => a.area >= b.area ? a : b).center;
  }
}

/// Per-analyzer minimum intervals; one frame is processed at a time and
/// frames arriving while busy are dropped.
class AnalyzerScheduler {
  AnalyzerScheduler({Map<LiveAnalyzer, Duration>? intervals})
    : intervals = intervals ?? kAnalyzerIntervals;

  final Map<LiveAnalyzer, Duration> intervals;
  final Map<LiveAnalyzer, DateTime> _last = {};
  bool busy = false;

  /// Analyzers due now among [active] (marks them as run).
  Set<LiveAnalyzer> due(Set<LiveAnalyzer> active, DateTime now) {
    if (busy) return const {};
    final out = <LiveAnalyzer>{};
    for (final a in active) {
      final l = _last[a];
      if (l == null || now.difference(l) >= intervals[a]!) {
        out.add(a);
        _last[a] = now;
      }
    }
    return out;
  }

  void reset() => _last.clear();
}

const kAnalyzerIntervals = <LiveAnalyzer, Duration>{
  LiveAnalyzer.frameStats: Duration(milliseconds: 250),
  LiveAnalyzer.faces: Duration(milliseconds: 200),
  LiveAnalyzer.barcodes: Duration(milliseconds: 450),
  LiveAnalyzer.labels: Duration(milliseconds: 1500),
};

/// Device roll (degrees, + = clockwise) from an accelerometer sample in a
/// portrait-locked app. 0 = level.
double rollDegrees(double ax, double ay) {
  if (ax.abs() < 1e-6 && ay.abs() < 1e-6) return 0;
  return math.atan2(ax, ay) * 180 / math.pi;
}

/// Phone flat (pointing down / up)? Then the level line is hidden.
bool isFlat(double ax, double ay, double az) =>
    az.abs() > 0.85 * math.sqrt(ax * ax + ay * ay + az * az);

bool isLevel(double roll, {double tolerance = 1.0}) => roll.abs() <= tolerance;

/// Low-pass for jittery sensor angles.
double smoothAngle(double previous, double next, {double alpha = 0.2}) =>
    previous + (next - previous) * alpha;
