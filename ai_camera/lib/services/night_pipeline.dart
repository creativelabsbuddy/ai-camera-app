import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../models/camera_options.dart';
import '../models/capture_mode.dart';
import 'night_plan.dart';

export 'night_plan.dart';

/// Night mode building blocks. A capture runs the steps of the selected
/// [CapturePipeline] in order. To add a new night idea later (e.g. a
/// denoise pass, HDR bracketing, a native extension once the camera plugin
/// supports it), add a [NightStep], decide when it applies in
/// [selectCapturePipeline], and handle it in the camera screen / preview.
enum NightStep {
  /// Raise exposure compensation for the burst (free).
  exposureBoost,

  /// Several quick frames, aligned (global shift) and averaged → less noise
  /// (free, on-device, no AI).
  burstMerge,

  /// Pro AI: append the locked night prompt to the enhance (credits as a
  /// normal enhance).
  aiNightPrompt,
}

class CapturePipeline {
  const CapturePipeline({
    required this.night,
    this.frames = 1,
    this.exposureBoostEv = 0,
    this.steps = const [],
    this.holdSteadyHint = false,
  });

  static const normal = CapturePipeline(night: false);

  final bool night;

  /// Frames captured back-to-back (1 = normal single shot).
  final int frames;

  /// Exposure compensation (EV) applied during the burst.
  final double exposureBoostEv;
  final List<NightStep> steps;

  /// Show "Hold steady 1–2s" while capturing.
  final bool holdSteadyHint;

  bool has(NightStep s) => steps.contains(s);

  bool get aiNight => has(NightStep.aiNightPrompt);

  @override
  String toString() =>
      'CapturePipeline(night=$night, frames=$frames, ev=$exposureBoostEv, '
      'steps=${steps.map((e) => e.name).join('+')})';
}

/// v11: picks the capture pipeline from [planNight] (8–15 frames, hold-still
/// countdown, Flash Auto). Pure → unit tested.
///
/// * Night off → normal single shot.
/// * Night on → burst merge (+ exposure boost on the plugin fallback);
///   Pro AI adds the night prompt (server-side, admin-editable).
/// * Flash (On, or Auto in a very dark scene) → single flash frame, no
///   burst / boost; AI night still applies in Pro.
PipelineSelection selectCapturePipeline({
  required bool night,
  required CaptureMode mode,
  FlashChoice flash = FlashChoice.off,
  double maxExposureOffset = 0,
  double luma = 0.15,
}) {
  if (!night) return const PipelineSelection(CapturePipeline.normal);
  final plan = planNight(
    luma: luma,
    mode: mode,
    flash: flash,
    maxExposureOffset: maxExposureOffset,
  );
  final ai = mode == CaptureMode.pro;
  final ev = plan.fallbackEv;
  return PipelineSelection(
    CapturePipeline(
      night: true,
      frames: plan.frames,
      exposureBoostEv: ev,
      holdSteadyHint: plan.burst,
      steps: [
        if (ev > 0) NightStep.exposureBoost,
        if (plan.burst) NightStep.burstMerge,
        if (ai) NightStep.aiNightPrompt,
      ],
    ),
    plan: plan,
  );
}

class PipelineSelection {
  const PipelineSelection(this.pipeline, {this.plan});

  final CapturePipeline pipeline;
  final NightPlan? plan;

  /// Short status for the preview ("Night · 3 frames merged").
  String note({int mergedFrames = 1}) {
    if (!pipeline.night) return '';
    return mergedFrames > 1 ? 'Night · $mergedFrames frames merged' : 'Night';
  }
}

// ---------------------------------------------------------------------------
// Burst merge
// ---------------------------------------------------------------------------

class MergeResult {
  const MergeResult(this.path, this.used, this.shifts);

  final String path;

  /// Frames actually averaged (misaligned / mismatched frames are dropped).
  final int used;

  /// Applied (dx, dy) per used frame in full-res pixels (first = 0,0).
  final List<(int, int)> shifts;
}

/// Aligns (global translation) and averages [paths] into one JPEG in
/// [outDir]. Runs in a background isolate. Falls back to the first frame.
Future<MergeResult> mergeNightFrames(List<String> paths, String outDir) =>
    compute(_mergeSync, _MergeArgs(paths, outDir));

class _MergeArgs {
  const _MergeArgs(this.paths, this.outDir);
  final List<String> paths;
  final String outDir;
}

MergeResult _mergeSync(_MergeArgs a) {
  final frames = <img.Image>[];
  for (final path in a.paths) {
    final raw = img.decodeImage(File(path).readAsBytesSync());
    if (raw == null) continue;
    frames.add(img.bakeOrientation(raw));
  }
  if (frames.isEmpty) {
    return MergeResult(a.paths.first, 1, const [(0, 0)]);
  }
  final r = mergeFrames(frames);
  final out = p.join(
    a.outDir,
    'night_${DateTime.now().millisecondsSinceEpoch}.jpg',
  );
  File(out).writeAsBytesSync(img.encodeJpg(r.image, quality: 95));
  return MergeResult(out, r.used, r.shifts);
}

class MergedImage {
  const MergedImage(
    this.image,
    this.used,
    this.shifts, [
    this.errors = const [],
  ]);
  final img.Image image;
  final int used;
  final List<(int, int)> shifts;

  /// v11.30 post-alignment edge error (1 − edge correlation) of every
  /// other frame, in order; NaN = size mismatch. ≤ [kMergeMaxEdgeErr] used.
  final List<double> errors;
}

/// v11.30 frames whose edges still differ this much after alignment
/// (1 − edge correlation) are dropped (ghosted letters / motion).
const double kMergeMaxEdgeErr = 0.5;

/// v11.48: a pixel further than this from the reference (0..255) is a
/// ghost in that frame and is left out of the average.
const int kMergeGhostTol = 48;

/// Alignment works on an edge map at most this wide (then sub-pixel).
const int kMergeWorkWidth = 512;

/// Coarse search radius (half-size edge map px ≈ ±64 work px... ±16).
const int kMergeCoarseRadius = 16;

/// Sub-pixel resampling only up to this many pixels (zoom crops); larger
/// frames (night full frames) use the rounded shift.
const int kMergeSubPixelMaxPixels = 4200000;

/// Pure merge (tests use small synthetic frames): frame 0 is the reference
/// (callers pass the sharpest first). v11.30: every other frame is aligned
/// on a blurred EDGE map (coarse search, then a fine search with a
/// sub-pixel parabola fit), rejected when its edges still disagree
/// (1 − edge correlation > [kMergeMaxEdgeErr]), then averaged ([median]:
/// per-pixel median from 3 frames, robust to one ghosted frame). Fewer
/// than 2 good frames → the reference alone.
MergedImage mergeFrames(
  List<img.Image> frames, {
  int proxyWidth = kMergeWorkWidth,
  bool median = false,
}) {
  final ref = frames.first;
  final w = ref.width;
  final h = ref.height;
  final scale = w > proxyWidth ? w / proxyWidth : 1.0;
  final refEdge = edgeMap(ref, scale);
  final subPixel = w * h <= kMergeSubPixelMaxPixels;
  final aligned = <Uint8List>[ref.getBytes(order: img.ChannelOrder.rgb)];
  final valid = <Uint8List?>[null];
  final shifts = <(int, int)>[(0, 0)];
  final errors = <double>[];
  for (final f in frames.skip(1)) {
    if (f.width != w || f.height != h) {
      errors.add(double.nan);
      continue;
    }
    final a = alignEdges(refEdge, edgeMap(f, scale));
    errors.add(a.err);
    if (a.err > kMergeMaxEdgeErr) continue;
    var dx = a.dx * scale, dy = a.dy * scale;
    if (!subPixel) {
      dx = dx.roundToDouble();
      dy = dy.roundToDouble();
    }
    final (bytes, mask) = _resample(f, dx, dy);
    aligned.add(bytes);
    valid.add(mask);
    shifts.add((dx.round(), dy.round()));
  }
  if (aligned.length < 2) {
    return MergedImage(ref, 1, const [(0, 0)], errors);
  }
  final out = Uint8List(w * h * 3);
  final vals = <int>[];
  for (var i = 0, j = 0; i < w * h; i++, j += 3) {
    for (var c = 0; c < 3; c++) {
      vals.clear();
      final r0 = aligned[0][j + c];
      for (var k = 0; k < aligned.length; k++) {
        final m = valid[k];
        if (m != null && m[i] == 0) continue;
        final v = aligned[k][j + c];
        // v11.48: per-pixel ghost rejection (something moved there).
        if (k > 0 && (v - r0).abs() > kMergeGhostTol) continue;
        vals.add(v);
      }
      if (median && vals.length >= 3) {
        vals.sort();
        final n = vals.length;
        out[j + c] = n.isOdd
            ? vals[n ~/ 2]
            : (vals[n ~/ 2 - 1] + vals[n ~/ 2]) ~/ 2;
      } else {
        var sum = 0;
        for (final v in vals) {
          sum += v;
        }
        out[j + c] = sum ~/ vals.length;
      }
    }
  }
  final image = img.Image.fromBytes(
    width: w,
    height: h,
    bytes: out.buffer,
    numChannels: 3,
  );
  return MergedImage(image, aligned.length, shifts, errors);
}

/// Frame [f] sampled at (x + dx, y + dy) (bilinear for fractional shifts);
/// mask 0 = outside the frame (not counted).
(Uint8List, Uint8List) _resample(img.Image f, double dx, double dy) {
  final w = f.width, h = f.height;
  final b = f.getBytes(order: img.ChannelOrder.rgb);
  final out = Uint8List(w * h * 3);
  final mask = Uint8List(w * h);
  final ix = dx.floor(), iy = dy.floor();
  final fx = dx - ix, fy = dy - iy;
  final frac = fx > 1e-3 || fy > 1e-3;
  final w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy);
  final w01 = (1 - fx) * fy, w11 = fx * fy;
  for (var y = 0; y < h; y++) {
    final sy = y + iy;
    if (sy < 0 || sy >= h || (frac && sy + 1 >= h)) continue;
    for (var x = 0; x < w; x++) {
      final sx = x + ix;
      if (sx < 0 || sx >= w || (frac && sx + 1 >= w)) continue;
      final o = (y * w + x) * 3;
      final s0 = (sy * w + sx) * 3;
      if (!frac) {
        out[o] = b[s0];
        out[o + 1] = b[s0 + 1];
        out[o + 2] = b[s0 + 2];
      } else {
        final s1 = s0 + 3, s2 = s0 + w * 3, s3 = s2 + 3;
        for (var c = 0; c < 3; c++) {
          out[o + c] =
              (b[s0 + c] * w00 +
                      b[s1 + c] * w10 +
                      b[s2 + c] * w01 +
                      b[s3 + c] * w11)
                  .round()
                  .clamp(0, 255);
        }
      }
      mask[y * w + x] = 1;
    }
  }
  return (out, mask);
}

/// v11.30 blurred edge map (|gx| + |gy| of a 3×3-box-blurred grey proxy).
EdgeMap edgeMap(img.Image im, double scale) {
  final g = _gray(im, scale);
  final w = g.width, h = g.height;
  final bl = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var s = 0, n = 0;
      for (var j = -1; j <= 1; j++) {
        final yy = y + j;
        if (yy < 0 || yy >= h) continue;
        for (var i = -1; i <= 1; i++) {
          final xx = x + i;
          if (xx < 0 || xx >= w) continue;
          s += g.data[yy * w + xx];
          n++;
        }
      }
      bl[y * w + x] = s / n;
    }
  }
  final e = Float32List(w * h);
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x;
      e[i] = (bl[i + 1] - bl[i - 1]).abs() + (bl[i + w] - bl[i - w]).abs();
    }
  }
  return EdgeMap(w, h, e);
}

class EdgeMap {
  EdgeMap(this.width, this.height, this.data);
  final int width;
  final int height;
  final Float32List data;

  /// Half-size copy (2×2 average) for the coarse search.
  EdgeMap half() {
    final w2 = width ~/ 2, h2 = height ~/ 2;
    final d = Float32List(math.max(0, w2 * h2));
    for (var y = 0; y < h2; y++) {
      for (var x = 0; x < w2; x++) {
        final i = 2 * y * width + 2 * x;
        d[y * w2 + x] =
            (data[i] + data[i + 1] + data[i + width] + data[i + width + 1]) / 4;
      }
    }
    return EdgeMap(w2, h2, d);
  }
}

/// Mean |ref − frame(x+dx, y+dy)| over the interior (sampled every
/// [step] px); infinity when nothing overlaps.
double _edgeSad(EdgeMap a, EdgeMap b, int dx, int dy, int margin, int step) {
  final w = a.width, h = a.height;
  var s = 0.0;
  var n = 0;
  for (var y = margin; y < h - margin; y += step) {
    final ry = y * w, fy = (y + dy) * w;
    for (var x = margin; x < w - margin; x += step) {
      s += (a.data[ry + x] - b.data[fy + x + dx]).abs();
      n++;
    }
  }
  return n == 0 ? double.infinity : s / n;
}

/// v11.30 alignment of edge maps: coarse search (±[kMergeCoarseRadius] on
/// half size), then ±2 px on full size with a sub-pixel parabola fit.
/// err = 1 − correlation of the edges where the reference has edges.
({double dx, double dy, double err}) alignEdges(EdgeMap ref, EdgeMap f) {
  var cx = 0, cy = 0;
  final rh = ref.half(), fh = f.half();
  final cr = math.min(
    kMergeCoarseRadius,
    math.max(1, math.min(rh.width, rh.height) ~/ 4),
  );
  // v11.48 coarse-to-fine: a quarter-size search first (bigger hand
  // shake), then ±4 on half size around it.
  var qx = 0, qy = 0;
  final rq = rh.half(), fq = fh.half();
  final qr = math.min(
    kMergeCoarseRadius,
    math.max(1, math.min(rq.width, rq.height) ~/ 4),
  );
  if (rq.width > 2 * qr + 4 && rq.height > 2 * qr + 4) {
    var best = double.infinity;
    for (var dy = -qr; dy <= qr; dy++) {
      for (var dx = -qr; dx <= qr; dx++) {
        final e =
            _edgeSad(rq, fq, dx, dy, qr + 1, 1) *
            (1 + 0.01 * (dx.abs() + dy.abs()));
        if (e < best) {
          best = e;
          qx = dx;
          qy = dy;
        }
      }
    }
  }
  // Quarter result on the half grid (kept inside the ±cr search).
  final useQ = qx != 0 || qy != 0;
  final hx = (2 * qx).clamp(-cr, cr), hy = (2 * qy).clamp(-cr, cr);
  if (rh.width > 2 * cr + 4 && rh.height > 2 * cr + 4) {
    var best = double.infinity;
    for (var dy = -cr; dy <= cr; dy++) {
      for (var dx = -cr; dx <= cr; dx++) {
        if (useQ && ((dx - hx).abs() > 4 || (dy - hy).abs() > 4)) {
          continue; // v11.48: near the quarter-size result only
        }
        // Small bias to the nearest match (periodic textures).
        final e =
            _edgeSad(rh, fh, dx, dy, cr + 1, 2) *
            (1 + 0.01 * (dx.abs() + dy.abs()));
        if (e < best) {
          best = e;
          cx = dx;
          cy = dy;
        }
      }
    }
  }
  final m = 2 * cr + 4;
  final cost = <(int, int), double>{};
  double at(int dx, int dy) =>
      cost[(dx, dy)] ??= _edgeSad(ref, f, dx, dy, m, 1);
  var bx = 2 * cx, by = 2 * cy;
  // Fine search ±2 around the coarse result (walks if still on the edge).
  for (var it = 0; it < 4; it++) {
    var moved = false;
    var best = at(bx, by);
    var nx = bx, ny = by;
    for (var dy = -2; dy <= 2; dy++) {
      for (var dx = -2; dx <= 2; dx++) {
        if (dx.abs() + bx.abs() >= m || dy.abs() + by.abs() >= m) continue;
        final e = at(bx + dx, by + dy);
        if (e < best) {
          best = e;
          nx = bx + dx;
          ny = by + dy;
          moved = true;
        }
      }
    }
    bx = nx;
    by = ny;
    if (!moved) break;
  }
  double fit(double l, double c, double r) {
    final d = l - 2 * c + r;
    if (!d.isFinite || d <= 1e-9) return 0;
    return (0.5 * (l - r) / d).clamp(-0.5, 0.5).toDouble();
  }

  final fx = fit(at(bx - 1, by), at(bx, by), at(bx + 1, by));
  final fy = fit(at(bx, by - 1), at(bx, by), at(bx, by + 1));
  final global = 1 - _edgeCorr(ref, f, bx, by, m);
  // v11.48 sub-regions: a frame that only fits in part of the picture
  // (tilt / local motion) is judged by its worst quadrant too.
  var worst = 0.0;
  final w = ref.width, h = ref.height;
  for (final (x0, y0) in [(0, 0), (w ~/ 2, 0), (0, h ~/ 2), (w ~/ 2, h ~/ 2)]) {
    final c = _edgeCorrRect(ref, f, bx, by, m, x0, y0, w ~/ 2, h ~/ 2);
    if (c != null) worst = math.max(worst, 1 - c);
  }
  final err = math.max(global, worst * kMergeRegionWeight);
  return (dx: bx + fx, dy: by + fy, err: err);
}

/// v11.48: a quadrant's error counts at this share (one weak quadrant
/// with few edges should not drop a good frame).
const double kMergeRegionWeight = 0.8;

/// Edge correlation inside one rectangle (null = too few edges there).
double? _edgeCorrRect(
  EdgeMap a,
  EdgeMap b,
  int dx,
  int dy,
  int margin,
  int rx,
  int ry,
  int rw,
  int rh,
) {
  final w = a.width, h = a.height;
  final x0 = math.max(margin, rx), x1 = math.min(w - margin, rx + rw);
  final y0 = math.max(margin, ry), y1 = math.min(h - margin, ry + rh);
  if (x1 - x0 < 4 || y1 - y0 < 4) return null;
  var mean = 0.0;
  var cnt = 0;
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      mean += a.data[y * w + x];
      cnt++;
    }
  }
  mean /= cnt;
  var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0;
  var n = 0;
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      final va = a.data[y * w + x];
      final vb = b.data[(y + dy) * w + x + dx];
      if (va <= mean && vb <= mean) continue;
      sa += va;
      sb += vb;
      saa += va * va;
      sbb += vb * vb;
      sab += va * vb;
      n++;
    }
  }
  if (n < 32) return null;
  final cov = sab / n - (sa / n) * (sb / n);
  final va = saa / n - (sa / n) * (sa / n);
  final vb = sbb / n - (sb / n) * (sb / n);
  if (va <= 1e-6 || vb <= 1e-6) return null;
  return (cov / math.sqrt(va * vb)).clamp(-1.0, 1.0).toDouble();
}

/// Pearson correlation of the edge maps at shift (dx, dy), over pixels
/// where either map has an edge; 0 when there are no edges.
double _edgeCorr(EdgeMap a, EdgeMap b, int dx, int dy, int margin) {
  final w = a.width, h = a.height;
  var mean = 0.0;
  var cnt = 0;
  for (var y = margin; y < h - margin; y++) {
    for (var x = margin; x < w - margin; x++) {
      mean += a.data[y * w + x];
      cnt++;
    }
  }
  if (cnt == 0) return 0;
  mean /= cnt;
  var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0;
  var n = 0;
  for (var y = margin; y < h - margin; y++) {
    for (var x = margin; x < w - margin; x++) {
      final va = a.data[y * w + x];
      final vb = b.data[(y + dy) * w + x + dx];
      if (va <= mean && vb <= mean) continue; // flat wall: not informative
      sa += va;
      sb += vb;
      saa += va * va;
      sbb += vb * vb;
      sab += va * vb;
      n++;
    }
  }
  if (n < 8) return 0;
  final cov = sab / n - (sa / n) * (sb / n);
  final va = saa / n - (sa / n) * (sa / n);
  final vb = sbb / n - (sb / n) * (sb / n);
  if (va <= 1e-9 || vb <= 1e-9) return 0;
  return (cov / math.sqrt(va * vb)).clamp(-1.0, 1.0).toDouble();
}

/// v11.30 debug: 'Merged 3 of 4 · err 0.21/0.18/0.64✗' or 'Sharpest of 4'.
String mergeDebugText(int used, int total, List<double> errors) {
  final head = used >= 2 ? 'Merged $used of $total' : 'Sharpest of $total';
  if (errors.isEmpty) return head;
  final e = [
    for (final v in errors)
      v.isNaN
          ? 'size✗'
          : '${v.toStringAsFixed(2)}${v > kMergeMaxEdgeErr ? '✗' : ''}',
  ].join('/');
  return '$head · err $e';
}

class GrayProxy {
  GrayProxy(this.width, this.height, this.data);
  final int width;
  final int height;
  final Uint8List data;
}

GrayProxy _gray(img.Image im, double scale) {
  final small = scale > 1
      ? img.copyResize(
          im,
          width: (im.width / scale).round(),
          height: (im.height / scale).round(),
          interpolation: img.Interpolation.average,
        )
      : im;
  final b = small.getBytes(order: img.ChannelOrder.rgb);
  final d = Uint8List(small.width * small.height);
  for (var i = 0, j = 0; i < d.length; i++, j += 3) {
    d[i] = (b[j] * 77 + b[j + 1] * 150 + b[j + 2] * 29) >> 8;
  }
  return GrayProxy(small.width, small.height, d);
}
