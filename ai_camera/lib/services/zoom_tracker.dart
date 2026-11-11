import 'dart:math' as math;

import 'dart:typed_data';

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

/// v11.61 past blur: a BLURRY frame (deep digital zoom) may still be
/// tracked by a coarse match at half resolution with this lower score,
/// when the result stays near the zoom-predicted view.
const double kTrackBlurMinScore = 0.70;

/// Coarse/coasted result must stay within this (normalised units) of the
/// predicted position, and its scale within [kTrackCoarseScaleTol].
const double kTrackCoarseShift = 0.08;
const double kTrackCoarseScaleTol = 1.15;

/// v11.61: while the GYRO says the phone is steady, an unmatched frame
/// "coasts" on the zoom-predicted view (scale = zoom ratio, last position)
/// for at most this many consecutive frames instead of losing the chain.
/// A coasted region is never trusted blindly: the strict source check
/// must still match the final against it (else fail closed).
const int kTrackCoastMax = 20;

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
  const TrackFrame(this.grey, this.cameraZoom, this.at, {this.steady = false});
  final GreyImage grey;
  final double cameraZoom;
  final DateTime at;

  /// v11.61: the gyro reported the phone steady at this frame.
  final bool steady;
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
  int _coast = 0;
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
          '${_misses > 0 ? ' miss $_misses' : ''}'
          '${_coast > 0 ? ' coast $_coast' : ''}',
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
    _coast = 0;
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
    _coast = 0;
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
    var t = r.transform;
    bool plausibleT(Similarity x) =>
        x.isFinite &&
        x.scale / predScale <= kTrackScaleTol &&
        predScale / x.scale <= kTrackScaleTol &&
        x.angle.abs() <= kTrackMaxAngle;
    bool nearGuess(Similarity x) {
      final dx = x.tx - guess.tx, dy = x.ty - guess.ty;
      return math.sqrt(dx * dx + dy * dy) <= kTrackCoarseShift &&
          x.scale / predScale <= kTrackCoarseScaleTol &&
          predScale / x.scale <= kTrackCoarseScaleTol;
    }

    var plausible = r.score >= kTrackMinScore && plausibleT(t);
    var coarse = false;
    var coasted = false;
    final sh = f.grey.laplacianVariance();
    if (!plausible && sh < key.sharpness * kTrackKeySharpRatio) {
      // v11.61 past blur: coarse match at half resolution (the blur hides
      // the fine detail, the coarse structure is still there).
      final rc = registerSimilarity(
        f.grey.half(),
        key.frame.grey.half(),
        guess: guess,
        scaleFactors: scaleFactors,
        radius: 3,
      );
      if (rc.score >= kTrackBlurMinScore &&
          plausibleT(rc.transform) &&
          nearGuess(rc.transform)) {
        t = rc.transform;
        _lastScore = rc.score;
        plausible = true;
        coarse = true;
      }
    }
    if (!plausible && f.steady && _coast < kTrackCoastMax && guess.isFinite) {
      // v11.61: gyro steady → coast on the zoom-predicted view.
      t = guess;
      plausible = true;
      coasted = true;
    }
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
    _coast = coasted ? _coast + 1 : 0;
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
    _lastNote = coasted
        ? 'coast $_coast'
        : coarse
        ? 'coarse ${_lastScore.toStringAsFixed(2)}'
        : 'ok ${r.score.toStringAsFixed(2)}';
    // Coarse / coasted frames never become keyframes.
    if (coarse || coasted) return TrackUpdate(_state, _lastScore, _lastNote);
    // Keyframe promotion: clear + confident + moved / zoomed enough.
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

// ---- v11.60 still orientation ----------------------------------------------
//
// Analysis frames are always rotated by the sensor orientation only (the
// app UI is portrait-locked), so tracking coordinates never rotate. Stills
// follow the DEVICE orientation (EXIF): a still is the analysis view
// rotated clockwise by k·90°. k's parity comes from the device orientation
// (metadata: portrait → 0/2, landscape → 1/3); within that pair an image
// match against the live analysis frame must decide with a clear margin,
// else the reference is rejected (no guessing).

/// Rotates a grey image clockwise by [k]·90°.
GreyImage rotateGreyCw(GreyImage g, int k) {
  var cur = g;
  for (var n = 0; n < ((k % 4) + 4) % 4; n++) {
    final w = cur.width, h = cur.height;
    final d = Float32List(w * h);
    // new (x', y') in an h×w image = old (y', h − 1 − x')
    for (var y2 = 0; y2 < w; y2++) {
      for (var x2 = 0; x2 < h; x2++) {
        d[y2 * h + x2] = cur.data[(h - 1 - x2) * w + y2];
      }
    }
    cur = GreyImage(h, w, d);
  }
  return cur;
}

/// Box/bilinear resample of [g] to [w]×[h].
GreyImage resizeGrey(GreyImage g, int w, int h) {
  final d = Float32List(w * h);
  final sx = g.width / w, sy = g.height / h;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      // average of a 2×2 sample grid inside the footprint
      var s = 0.0;
      var n = 0;
      for (var j = 0; j < 2; j++) {
        for (var i = 0; i < 2; i++) {
          final v = g.sample(
            ((x + (i + 0.5) / 2) * sx - 0.5).clamp(0, g.width - 1).toDouble(),
            ((y + (j + 0.5) / 2) * sy - 0.5).clamp(0, g.height - 1).toDouble(),
          );
          if (!v.isNaN) {
            s += v;
            n++;
          }
        }
      }
      d[y * w + x] = n == 0 ? 0 : s / n;
    }
  }
  return GreyImage(w, h, d);
}

/// Margin the winning rotation must beat the other candidate by.
const double kRotationMargin = 0.10;

class StillRotation {
  const StillRotation(this.k, this.score, this.margin);
  final int? k;
  final double score;
  final double margin;
  bool get ok => k != null;
}

/// Which clockwise quarter-turn [k] makes the still from the analysis
/// view: candidates by the device's [landscape] metadata, decided by the
/// image (score ≥ [kTrackMinScore], margin ≥ [kRotationMargin]). Pure.
StillRotation detectStillRotation(
  GreyImage analysis,
  GreyImage still, {
  required bool landscape,
}) {
  final cands = landscape ? const [1, 3] : const [0, 2];
  final scores = <int, double>{};
  for (final k in cands) {
    // still rotated back (counter-clockwise k) = analysis orientation
    final back = rotateGreyCw(still, 4 - k);
    if ((back.aspect - analysis.aspect).abs() >
        kTrackAspectTol * analysis.aspect) {
      scores[k] = -1;
      continue;
    }
    final r = registerSimilarity(
      resizeGrey(back, analysis.width, analysis.height),
      analysis,
      scaleFactors: const [0.95, 1.0, 1.05],
      radius: 3,
    );
    scores[k] = r.score;
  }
  final best = cands.reduce((a, b) => scores[a]! >= scores[b]! ? a : b);
  final other = cands.firstWhere((c) => c != best);
  final margin = scores[best]! - scores[other]!;
  final ok = scores[best]! >= kTrackMinScore && margin >= kRotationMargin;
  return StillRotation(ok ? best : null, scores[best]!, margin);
}

/// Analysis-normalised (u, v) of a frame with [aspect] (h/w) → fractional
/// (0..1) coords in a still that is the view rotated clockwise by [k]. Pure.
(double, double) analysisToStillFrac(double u, double v, double aspect, int k) {
  var fx = u + 0.5, fy = v / aspect + 0.5;
  for (var n = 0; n < ((k % 4) + 4) % 4; n++) {
    final t = fx;
    fx = 1 - fy;
    fy = t;
  }
  return (fx, fy);
}

/// [roi] (analysis coords, frame aspect [aspect]) → the matching rect in
/// a [w]×[h] still rotated by [k], in the STILL's normalised coords. Pure.
NRect roiToStill(NRect roi, double aspect, int k, int w, int h) {
  final pts = [
    analysisToStillFrac(roi.l, roi.t, aspect, k),
    analysisToStillFrac(roi.r, roi.t, aspect, k),
    analysisToStillFrac(roi.l, roi.b, aspect, k),
    analysisToStillFrac(roi.r, roi.b, aspect, k),
  ];
  final l = pts.map((p) => p.$1).reduce(math.min);
  final r = pts.map((p) => p.$1).reduce(math.max);
  final t = pts.map((p) => p.$2).reduce(math.min);
  final b = pts.map((p) => p.$2).reduce(math.max);
  final hw = h / w;
  return NRect(l - 0.5, (t - 0.5) * hw, r - 0.5, (b - 0.5) * hw);
}

/// The final visible region (fractions [fw]×[fh] of a still rotated by
/// [k]) in analysis coords (centred; a quarter turn swaps the axes). Pure.
NRect finalRoiInAnalysis(double fw, double fh, double aspect, int k) =>
    k.isOdd ? NRect.centre(fh, fw, aspect) : NRect.centre(fw, fh, aspect);
