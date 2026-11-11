import 'dart:math' as math;

import 'image_register.dart';

/// v11.60 wide→close zoom TRACKING (cheap phones). The live analysis
/// stream (upright grey proxies of the whole camera frame, at the camera's
/// current native zoom) is registered frame by frame against a keyframe;
/// transforms are CHAINED back to the root (the first clear reference), so
/// the nested region the user ends on is located inside each clear wider
/// reference photo — not by comparing the whole wide image with the final.
///
/// • Registration: image-based similarity (pyramid NCC search + Gauss–
///   Newton), seeded by the zoom ratio; zoom geometry is only a GUESS.
/// • Blurry frames never become keyframes; a blurry or unmatched frame
///   does not reset the chain (the last good keyframe stays valid).
/// • Persistent mismatch, a different subject, implausible motion or the
///   view leaving the reference → LOST: references are invalid and a shot
///   needing a sharp source fails closed (hold steady; no AI call).

/// Analysis proxy (upright portrait, 3:4).
const int kTrackW = 72;
const int kTrackH = 96;

/// Minimum post-alignment NCC for a frame to count as tracked.
const double kTrackMinScore = 0.80;

/// A frame this confident (and clear) may become the new keyframe.
const double kTrackKeyScore = 0.88;

/// Promote a keyframe when the scale vs it grows by this, or the view has
/// moved this far (normalised width units).
const double kTrackKeyScaleStep = 1.4;
const double kTrackKeyShift = 0.12;

/// Blurry frame: Laplacian variance below this fraction of the
/// keyframe's (never a keyframe; still tracked if it matches).
const double kTrackKeySharpRatio = 0.55;

/// Consecutive unmatched analysed frames before the track is lost.
const int kTrackLostAfter = 8;

/// Measured scale may deviate from the zoom-predicted scale by this
/// factor (beyond = a different view, not a zoom).
const double kTrackScaleTol = 1.35;

/// Rotation beyond this (radians) between keyframe and frame = implausible
/// for a handheld zoom (unsupported, lost).
const double kTrackMaxAngle = 0.14; // ≈ 8°

/// Analysis vs still aspect must agree within this (else unsupported).
const double kTrackAspectTol = 0.02;

/// Retry scale search (fast pinch: the camera's zoom lags the request).
const List<double> kTrackWideScales = [
  0.7,
  0.78,
  0.86,
  0.95,
  1.05,
  1.16,
  1.28,
  1.42,
];

enum TrackState {
  /// No root yet (waiting for the first frame).
  idle,

  /// Chain valid.
  tracking,

  /// Chain broken (mismatch / subject change / left reference).
  lost,

  /// Unsupported geometry (orientation, aspect): tracking disabled.
  unsupported,
}

/// One analysed frame.
class TrackFrame {
  const TrackFrame(this.grey, this.cameraZoom, this.at);
  final GreyImage grey;
  final double cameraZoom;
  final DateTime at;
}

class _Key {
  _Key(this.frame, this.rootToKey, this.sharpness);
  final TrackFrame frame;

  /// Root coords → this keyframe's coords.
  final Similarity rootToKey;
  final double sharpness;
}

/// Result of one update (diagnostics are truthful: what really happened).
class TrackUpdate {
  const TrackUpdate(this.state, this.score, this.note);
  final TrackState state;
  final double score;
  final String note;
}

class ZoomTracker {
  ZoomTracker({this.scaleFactors = const [0.85, 0.92, 1.0, 1.08, 1.18]});
  final List<double> scaleFactors;

  TrackState _state = TrackState.idle;
  TrackState get state => _state;
  _Key? _root;
  _Key? _key;
  Similarity? _rootToCur;
  Similarity? _keyToCurLast;
  DateTime? _curAt;
  double _curZoom = 1;
  int _misses = 0;
  int _frames = 0;
  int _keys = 0;
  double _lastScore = -1;
  String _lastNote = 'idle';
  String? _lostReason;

  /// Root → latest TRACKED frame (null unless tracking).
  Similarity? get rootToCur =>
      _state == TrackState.tracking ? _rootToCur : null;
  DateTime? get curAt => _curAt;
  double get curZoom => _curZoom;
  double get rootZoom => _root?.frame.cameraZoom ?? 1;

  /// Analysis frame aspect (h/w) of the chain, null without a root.
  double? get rootAspect => _root?.frame.grey.aspect;
  int get misses => _misses;
  String? get lostReason => _lostReason;

  /// Key builds: "track ok 0.93 k2 f37" / "track lost (mismatch)".
  String get debugText => switch (_state) {
    TrackState.idle => 'track idle',
    TrackState.tracking =>
      'track ok ${_lastScore.toStringAsFixed(2)} k$_keys f$_frames'
          '${_misses > 0 ? ' miss $_misses' : ''}',
    TrackState.lost => 'track lost ($_lostReason)',
    TrackState.unsupported => 'track off ($_lostReason)',
  };

  String get lastNote => _lastNote;

  /// Full reset (camera re-open, lens switch, zoom back out, new shot).
  void reset([String why = 'reset']) {
    _state = TrackState.idle;
    _root = null;
    _key = null;
    _rootToCur = null;
    _keyToCurLast = null;
    _curAt = null;
    _misses = 0;
    _frames = 0;
    _keys = 0;
    _lastScore = -1;
    _lastNote = why;
    _lostReason = null;
  }

  /// Unsupported geometry → disabled until [reset].
  void disable(String why) {
    reset(why);
    _state = TrackState.unsupported;
    _lostReason = why;
  }

  void _lose(String why) {
    _state = TrackState.lost;
    _lostReason = why;
    _rootToCur = null;
  }

  /// Starts a new chain at [f] (identity root). Used for the first frame,
  /// and to re-root while there is nothing to protect (no references).
  void rebase(TrackFrame f) {
    final sh = f.grey.laplacianVariance();
    _root = _Key(f, const Similarity.identity(), sh);
    _key = _root;
    _rootToCur = const Similarity.identity();
    _keyToCurLast = const Similarity.identity();
    _curAt = f.at;
    _curZoom = f.cameraZoom;
    _state = TrackState.tracking;
    _misses = 0;
    _keys = 1;
    _lastScore = 1;
    _lostReason = null;
    _lastNote = 'root';
  }

  TrackUpdate update(TrackFrame f) {
    if (_state == TrackState.unsupported || _state == TrackState.lost) {
      return TrackUpdate(_state, _lastScore, _lostReason ?? '');
    }
    _frames++;
    final key = _key;
    if (key == null) {
      rebase(f);
      return const TrackUpdate(TrackState.tracking, 1, 'root');
    }
    if ((f.grey.aspect - key.frame.grey.aspect).abs() > kTrackAspectTol) {
      disable('aspect');
      return const TrackUpdate(TrackState.unsupported, -1, 'aspect');
    }
    // cur → key: the current (narrower) view inside the keyframe. Guess:
    // zoom ratio for scale, last solved rotation / position.
    final predScale = key.frame.cameraZoom / math.max(1e-3, f.cameraZoom);
    final last = _keyToCurLast?.inverse();
    final guess = Similarity.of(
      scale: predScale,
      angle: last?.angle ?? 0,
      tx: last?.tx ?? 0,
      ty: last?.ty ?? 0,
    );
    var r = registerSimilarity(
      f.grey,
      key.frame.grey,
      guess: guess,
      scaleFactors: scaleFactors,
      radius: 4,
    );
    if (r.score < kTrackMinScore && last != null) {
      // Retry centred (a jump the prior did not cover).
      final r2 = registerSimilarity(
        f.grey,
        key.frame.grey,
        guess: Similarity.of(scale: predScale),
        scaleFactors: kTrackWideScales,
        radius: 6,
      );
      if (r2.score > r.score) r = r2;
    }
    _lastScore = r.score;
    final t = r.transform;
    final plausible =
        r.score >= kTrackMinScore &&
        t.isFinite &&
        t.scale / predScale <= kTrackScaleTol &&
        predScale / t.scale <= kTrackScaleTol &&
        t.angle.abs() <= kTrackMaxAngle;
    if (!plausible) {
      _misses++;
      _lastNote = r.score < kTrackMinScore
          ? 'miss ${r.score.toStringAsFixed(2)}'
          : 'implausible ${t.toString()}';
      if (_misses >= kTrackLostAfter) {
        _lose(r.score < kTrackMinScore ? 'mismatch' : 'implausible motion');
      }
      return TrackUpdate(_state, r.score, _lastNote);
    }
    _misses = 0;
    final keyToCur = t.inverse();
    _keyToCurLast = keyToCur;
    final rootToCur = keyToCur.compose(key.rootToKey);
    // The current view must stay inside the root reference.
    if (!viewInside(
      rootToCur.inverse(),
      f.grey.aspect,
      rootAspect: _root!.frame.grey.aspect,
    )) {
      _lose('left reference');
      return TrackUpdate(_state, r.score, 'left reference');
    }
    _rootToCur = rootToCur;
    _curAt = f.at;
    _curZoom = f.cameraZoom;
    _lastNote = 'ok ${r.score.toStringAsFixed(2)}';
    // Keyframe promotion: clear + confident + moved / zoomed enough.
    final sh = f.grey.laplacianVariance();
    final grown = 1 / t.scale >= kTrackKeyScaleStep;
    final moved = math.sqrt(t.tx * t.tx + t.ty * t.ty) >= kTrackKeyShift;
    if (r.score >= kTrackKeyScore &&
        (grown || moved) &&
        sh >= key.sharpness * kTrackKeySharpRatio) {
      _key = _Key(f, rootToCur, sh);
      _keyToCurLast = const Similarity.identity();
      _keys++;
      _lastNote = '$_lastNote · key';
    }
    return TrackUpdate(_state, r.score, _lastNote);
  }

  /// Does the view (corners of a frame with [aspect], mapped by
  /// [curToRoot]) stay inside the root frame (± [slack])? Pure.
  static bool viewInside(
    Similarity curToRoot,
    double aspect, {
    required double rootAspect,
    double slack = 0.04,
  }) => rectInside(
    mapRect(curToRoot, NRect.frame(aspect)),
    NRect.frame(rootAspect),
    slack: slack,
  );
}

/// Axis-aligned rectangle in centred, width-normalised coordinates.
class NRect {
  const NRect(this.l, this.t, this.r, this.b);

  /// The whole frame of [aspect] (h/w).
  factory NRect.frame(double aspect) =>
      NRect(-0.5, -aspect / 2, 0.5, aspect / 2);

  /// Centred rect [fw]×[fh] fractions of a frame of [aspect].
  factory NRect.centre(double fw, double fh, double aspect) =>
      NRect(-fw / 2, -fh * aspect / 2, fw / 2, fh * aspect / 2);

  final double l, t, r, b;
  double get w => r - l;
  double get h => b - t;
  double get cx => (l + r) / 2;
  double get cy => (t + b) / 2;

  NRect scaled(double f) =>
      NRect(cx - w * f / 2, cy - h * f / 2, cx + w * f / 2, cy + h * f / 2);

  @override
  String toString() =>
      '[${l.toStringAsFixed(3)},${t.toStringAsFixed(3)} ${w.toStringAsFixed(3)}×${h.toStringAsFixed(3)}]';
}

/// Bounding box of [r]'s corners under [t].
NRect mapRect(Similarity t, NRect r) {
  final pts = [
    t.apply(r.l, r.t),
    t.apply(r.r, r.t),
    t.apply(r.l, r.b),
    t.apply(r.r, r.b),
  ];
  return NRect(
    pts.map((p) => p.$1).reduce(math.min),
    pts.map((p) => p.$2).reduce(math.min),
    pts.map((p) => p.$1).reduce(math.max),
    pts.map((p) => p.$2).reduce(math.max),
  );
}

bool rectInside(NRect inner, NRect outer, {double slack = 0}) =>
    inner.l >= outer.l - slack &&
    inner.t >= outer.t - slack &&
    inner.r <= outer.r + slack &&
    inner.b <= outer.b + slack;

/// A clear reference photo taken while tracking: its view in root coords.
class TrackedRef {
  const TrackedRef({
    required this.path,
    required this.cameraZoom,
    required this.rootToRef,
    required this.sharpness,
  });
  final String path;
  final double cameraZoom;

  /// Root → this reference's (analysis-frame) coordinates.
  final Similarity rootToRef;
  final double sharpness;
}

/// Where the final visible region lies inside [ref]: the final region
/// [finalRoi] (in the CURRENT frame's coords) mapped cur → root → ref.
/// Null when the transform is unsupported (rotation) or the region is not
/// inside the reference (it was never photographed clearly). Pure.
NRect? roiInRef({
  required Similarity rootToCur,
  required TrackedRef ref,
  required NRect finalRoi,
  required double aspect,
  double slack = 0.03,
}) {
  final curToRef = ref.rootToRef.compose(rootToCur.inverse());
  if (!curToRef.isFinite || curToRef.angle.abs() > kTrackMaxAngle) {
    return null;
  }
  final roi = mapRect(curToRef, finalRoi);
  if (!rectInside(roi, NRect.frame(aspect), slack: slack)) return null;
  return roi;
}

/// Motion between two root→frame transforms (normalised units + scale).
/// Used to reject a reference whose still was taken while the view moved.
double transformDelta(Similarity a, Similarity b) {
  final d = a.inverse().compose(b);
  return math.sqrt(d.tx * d.tx + d.ty * d.ty) +
      (d.scale - 1).abs() +
      d.angle.abs();
}
