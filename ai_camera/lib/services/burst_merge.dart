import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import 'image_register.dart';

/// v11.60 zoom BURST: a short, bounded burst around the shutter, merged as
/// an ALIGNED MULTI-FRAME DENOISE MERGE (not super-resolution):
/// • only the zoomed region (+ alignment margin) of each still is decoded
///   (native BitmapRegionDecoder; Dart fallback);
/// • anchor = the sharpest frame (Laplacian variance);
/// • frames with a different exposure or that do not register to the
///   anchor (different subject / big motion) are left out entirely;
/// • similarity registration (scale, rotation, translation) on proxies,
///   bilinear warp at full resolution;
/// • per tile: a frame whose content differs from the anchor beyond the
///   noise level (moving subject) is ignored there (anchor only);
/// • per pixel: robust weights relative to the anchor's noise level;
/// • a mild, halo-clamped sharpen only where ≥ 2 frames really merged
///   (v11.61: per pixel; anchor-only areas stay unsharpened);
/// • v11.61 robust ghost test: per-tile exposure offset removed, edge
///   tolerance for sub-pixel misregistration, σ floor.
/// Fewer than 2 usable frames → the sharpest frame alone.

/// Burst bounds (cheap phones: sequential full-res takePicture calls).
const int kBurstMinFrames = 2;
const int kBurstMaxFrames = 4;

/// Capture time budget for the whole burst, and a single slow capture
/// that ends it (the phone is too slow for more).
const int kBurstBudgetMs = 1800;
const int kBurstSlowCaptureMs = 700;

/// Regions up to this many pixels merge in ONE band (fast path).
const int kBurstMaxRegionPixels = 3000000;

/// v11.60 fix: larger regions (cheap phones at 2x … the camera's own max:
/// the region is the whole ratio crop) merge BAND BY BAND (native region
/// decode per band, fixed memory) up to this many pixels; beyond → single
/// shot.
const int kBurstMaxBandedPixels = 16000000;

/// Output rows per band ≈ this many pixels (memory bound per band).
const int kBurstBandPixels = 1500000;

/// Banded merges get this wall-clock budget (over → the anchor's own
/// full photo, never a half-merged image).
const int kBurstBandedBudgetMs = 15000;

/// Region decode margin (alignment slack each side, fraction of size).
const double kBurstMargin = 0.075;

/// Registration proxy long side.
const int kBurstProxyLong = 320;

/// Minimum registration score (NCC) to merge a frame at all.
const double kBurstMinScore = 0.85;

/// Mean-brightness ratio window vs the anchor (else: other exposure).
const double kBurstExposureTol = 0.10;

/// Ghost tile size and threshold (mean |Δluma| in noise σ units).
const int kBurstTile = 16;
const double kBurstGhostSigma = 3.0;

/// v11.61 robust ghost test: the tile's own brightness offset (exposure
/// flicker) is removed first; edges get extra tolerance for sub-pixel
/// registration error (this × the anchor's mean local gradient); a tile is
/// a ghost only when what is left still differs. A tile whose mean offset
/// alone exceeds [kBurstOffsetSigma]σ + 4 is a ghost too.
const double kBurstGhostGrad = 0.35;
const double kBurstOffsetSigma = 6.0;

/// Noise σ floor for the ghost / weight tests (ISP-denoised stills report
/// a tiny σ that turned most tiles into "ghosts").
const double kBurstSigmaFloor = 1.5;

/// Per-pixel weight: 1 up to [kBurstPixLow]σ, 0 from [kBurstPixHigh]σ.
const double kBurstPixLow = 2.5;
const double kBurstPixHigh = 5.0;

/// Mild sharpen amount after a real merge (halo-clamped). v11.61: applied
/// per pixel in proportion to how much really merged there — anchor-only
/// pixels (ghost tiles) are not sharpened at all, so a burst that mostly
/// fell back to the anchor is not over-sharpened.
const double kBurstSharpen = 0.3;

/// Merge wall-clock budget inside the isolate (ms): over → anchor alone.
const int kBurstMergeBudgetMs = 6000;

/// Adaptive burst count: keep capturing while the next capture is likely
/// to fit the budget. Pure → unit tested.
bool burstWantsMore({
  required int taken,
  required int elapsedMs,
  required int lastCaptureMs,
}) {
  if (taken >= kBurstMaxFrames) return false;
  if (taken >= kBurstMinFrames && lastCaptureMs > kBurstSlowCaptureMs) {
    return false;
  }
  if (taken < kBurstMinFrames) return elapsedMs < kBurstBudgetMs * 2;
  return elapsedMs + lastCaptureMs <= kBurstBudgetMs;
}

/// Should this zoom shot use the burst? A plain single photo on a cheap
/// phone that is either digitally zoomed (digital > 1.2) or, v11.60 fix,
/// a Pro AI Zoom-mode shot at 2x … the camera's own max ([nativeZoom],
/// the v11.9 merge coverage) — region within [kBurstMaxBandedPixels].
/// Pure.
bool shouldBurstZoom({
  required bool lowEnd,
  required double digital,
  required int regionPixels,
  required bool plainPhoto,
  bool nativeZoom = false,
}) =>
    lowEnd &&
    plainPhoto &&
    (digital > 1.2 || nativeZoom) &&
    regionPixels > 0 &&
    regionPixels <= kBurstMaxBandedPixels;

/// Packed RGB frame (upright region + margin).
class RgbFrame {
  const RgbFrame(this.width, this.height, this.rgb);
  final int width, height;
  final Uint8List rgb;

  double lumaAt(int i) =>
      0.299 * rgb[i * 3] + 0.587 * rgb[i * 3 + 1] + 0.114 * rgb[i * 3 + 2];
}

class BurstFrameNote {
  const BurstFrameNote(this.index, this.sharpness, this.score, this.status);
  final int index;
  final double sharpness;
  final double score;

  /// 'anchor' / 'merged' / 'exposure' / 'unaligned' / 'size'.
  final String status;
}

class BurstMergeResult {
  const BurstMergeResult({
    this.image,
    required this.used,
    required this.anchor,
    required this.notes,
    required this.sigma,
    required this.ghostTiles,
    this.timedOut = false,
  });

  /// The merged region (null from the file job: written as JPEG).
  final RgbFrame? image;
  final int used;
  final int anchor;
  final List<BurstFrameNote> notes;
  final double sigma;

  /// Fraction of (frame, tile) pairs rejected as moving.
  final double ghostTiles;
  final bool timedOut;

  /// "merge 3/4 (anchor #2, σ 3.1, ghost 6%)".
  String get debugText => used >= 2
      ? 'merge $used/${notes.length} (anchor #${anchor + 1}, σ ${sigma.toStringAsFixed(1)}, ghost ${(ghostTiles * 100).round()}%)'
      : 'best of ${notes.length} (${notes.where((n) => n.status != 'anchor').map((n) => n.status).toSet().join(', ')}${timedOut ? ', time' : ''})';
}

/// Box-downsampled grey proxy (long side ≤ [long]) and its factor.
(GreyImage, int) burstProxy(RgbFrame f, {int long = kBurstProxyLong}) {
  final k = math.max(1, (math.max(f.width, f.height) / long).ceil());
  final w = f.width ~/ k, h = f.height ~/ k;
  final d = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var s = 0.0;
      for (var yy = 0; yy < k; yy++) {
        final row = (y * k + yy) * f.width;
        for (var xx = 0; xx < k; xx++) {
          s += f.lumaAt(row + x * k + xx);
        }
      }
      d[y * w + x] = s / (k * k);
    }
  }
  return (GreyImage(w, h, d), k);
}

/// Robust noise σ of the anchor luma (MAD of the 4-neighbour residual).
double estimateNoise(RgbFrame f) {
  final vals = <double>[];
  final w = f.width;
  for (var y = 1; y < f.height - 1; y += 3) {
    for (var x = 1; x < w - 1; x += 3) {
      final i = y * w + x;
      final r =
          f.lumaAt(i) -
          (f.lumaAt(i - 1) +
                  f.lumaAt(i + 1) +
                  f.lumaAt(i - w) +
                  f.lumaAt(i + w)) /
              4;
      vals.add(r.abs());
    }
  }
  if (vals.isEmpty) return 2;
  vals.sort();
  final mad = vals[vals.length ~/ 2];
  // residual σ = σ·√(1 + 1/4); MAD→σ 1.4826.
  return (1.4826 * mad / 1.118).clamp(1.0, 25.0);
}

/// Full-res affine (anchor px → frame px, region coordinates) from a
/// proxy-space similarity; proxy = region scaled by (pw/W, ph/H).
List<double> fullAffine(Similarity t, int pw, int ph, int w, int h) {
  final kx = w / pw, ky = h / ph;
  (double, double) map(double X, double Y) {
    final px = (X + 0.5) / kx - 0.5, py = (Y + 0.5) / ky - 0.5;
    final (u, v) = toNorm(px, py, pw, ph);
    final (u2, v2) = t.apply(u, v);
    final (qx, qy) = toPixel(u2, v2, pw, ph);
    return ((qx + 0.5) * kx - 0.5, (qy + 0.5) * ky - 0.5);
  }

  final (ox, oy) = map(0, 0);
  final (xx, xy) = map(1, 0);
  final (yx, yy) = map(0, 1);
  return [xx - ox, yx - ox, ox, xy - oy, yy - oy, oy];
}

/// Who merges and how: anchor (sharpest), per-frame full-res affine
/// (null = left out) and notes. Registration runs ONCE on proxies.
class BurstPlan {
  const BurstPlan(this.anchor, this.affines, this.notes);
  final int anchor;
  final List<List<double>?> affines;
  final List<BurstFrameNote> notes;
  Iterable<int> get merging sync* {
    for (var i = 0; i < affines.length; i++) {
      if (i != anchor && affines[i] != null) yield i;
    }
  }
}

/// [proxies] = grey proxies of each frame's region (same size), [sharp] =
/// sharpness per frame, region size [w]×[h]. Pure.
BurstPlan planBurst(List<GreyImage> proxies, List<double> sharp, int w, int h) {
  var anchor = 0;
  for (var i = 1; i < proxies.length; i++) {
    if (sharp[i] > sharp[anchor]) anchor = i;
  }
  final ap = proxies[anchor];
  final aMean = ap.mean();
  final apHalf = ap.half();
  final notes = <BurstFrameNote>[];
  final affines = List<List<double>?>.filled(proxies.length, null);
  for (var i = 0; i < proxies.length; i++) {
    if (i == anchor) {
      notes.add(BurstFrameNote(i, sharp[i], 1, 'anchor'));
      continue;
    }
    final fp = proxies[i];
    if (fp.width != ap.width || fp.height != ap.height) {
      notes.add(BurstFrameNote(i, sharp[i], -1, 'size'));
      continue;
    }
    final ratio = aMean <= 1 ? 1.0 : fp.mean() / aMean;
    if ((ratio - 1).abs() > kBurstExposureTol) {
      notes.add(BurstFrameNote(i, sharp[i], -1, 'exposure'));
      continue;
    }
    final r = registerSimilarity(
      ap,
      fp,
      scaleFactors: const [0.98, 1.0, 1.02],
      radius: 3,
      iterations: 5,
    );
    // Robust verdict: median tile NCC at half proxy resolution (a local
    // mover does not reject the frame — the ghost tiles handle it).
    final robust = r.score <= -1
        ? -1.0
        : tileMedianNcc(apHalf, fp.half(), r.transform);
    if (robust < kBurstMinScore || r.transform.angle.abs() > 0.05) {
      notes.add(BurstFrameNote(i, sharp[i], robust, 'unaligned'));
      continue;
    }
    affines[i] = fullAffine(r.transform, ap.width, ap.height, w, h);
    notes.add(BurstFrameNote(i, sharp[i], robust, 'merged'));
  }
  return BurstPlan(anchor, affines, notes);
}

/// A decoded piece of one frame: [f] holds region pixels starting at
/// region coordinates ([ox], [oy]).
class BandPiece {
  const BandPiece(this.f, this.ox, this.oy);
  final RgbFrame f;
  final int ox, oy;
}

class BandStats {
  int tiles = 0, ghost = 0, allGhostBands = 0;
  final Set<int> used = {};
}

/// Merges the output rect [out] (x, y, w, h in region coords) from the
/// anchor piece and the other pieces (index → piece, affine from [plan]).
/// Returns packed RGB of [out]. Tiles are aligned to region coordinates.
Uint8List mergeBand({
  required BandPiece anchor,
  required Map<int, BandPiece> others,
  required BurstPlan plan,
  required (int, int, int, int) out,
  required double sigma,
  required BandStats stats,
}) {
  final (ix, iy, iw, ih) = out;
  final a = anchor.f;
  final res = Uint8List(iw * ih * 3);
  for (var y = 0; y < ih; y++) {
    final src = ((iy - anchor.oy + y) * a.width + ix - anchor.ox) * 3;
    res.setRange(y * iw * 3, (y + 1) * iw * 3, a.rgb, src);
  }
  if (others.isEmpty) return res;
  final acc = Float32List(iw * ih * 3);
  final wsum = Float32List(iw * ih)..fillRange(0, iw * ih, 1);
  for (var j = 0; j < iw * ih * 3; j++) {
    acc[j] = res[j].toDouble();
  }
  final sg = math.max(kBurstSigmaFloor, sigma);
  final lo = kBurstPixLow * sg, hi = kBurstPixHigh * sg;
  final ghostTol = kBurstGhostSigma * sg + 1.0;
  final offTol = kBurstOffsetSigma * sg + 4.0;
  final px = Float32List(3);
  final ds = <double>[];
  var any = false;
  double lumaRes(int x, int y) {
    final d = (y * iw + x) * 3;
    return 0.299 * res[d] + 0.587 * res[d + 1] + 0.114 * res[d + 2];
  }

  for (final e in others.entries) {
    final m = plan.affines[e.key]!;
    final f = e.value.f;
    final fox = e.value.ox, foy = e.value.oy;
    var usedHere = false;
    bool warp(int x, int y) {
      final X = (ix + x).toDouble(), Y = (iy + y).toDouble();
      final sx = m[0] * X + m[1] * Y + m[2] - fox;
      final sy = m[3] * X + m[4] * Y + m[5] - foy;
      if (sx < 0 || sy < 0 || sx > f.width - 1 || sy > f.height - 1) {
        return false;
      }
      final x0 = sx.floor(), y0 = sy.floor();
      final x1 = math.min(x0 + 1, f.width - 1);
      final y1 = math.min(y0 + 1, f.height - 1);
      final fx = sx - x0, fy = sy - y0;
      final i00 = (y0 * f.width + x0) * 3, i10 = (y0 * f.width + x1) * 3;
      final i01 = (y1 * f.width + x0) * 3, i11 = (y1 * f.width + x1) * 3;
      for (var c = 0; c < 3; c++) {
        final t0 = f.rgb[i00 + c] + (f.rgb[i10 + c] - f.rgb[i00 + c]) * fx;
        final t1 = f.rgb[i01 + c] + (f.rgb[i11 + c] - f.rgb[i01 + c]) * fx;
        px[c] = t0 + (t1 - t0) * fy;
      }
      return true;
    }

    // Tile grid in REGION coordinates (bands agree on tiles).
    final ty0 = iy - iy % kBurstTile, tx0 = ix - ix % kBurstTile;
    for (var gy = ty0; gy < iy + ih; gy += kBurstTile) {
      for (var gx = tx0; gx < ix + iw; gx += kBurstTile) {
        final yA = math.max(gy, iy) - iy,
            yB = math.min(gy + kBurstTile, iy + ih) - iy;
        final xA = math.max(gx, ix) - ix,
            xB = math.min(gx + kBurstTile, ix + iw) - ix;
        ds.clear();
        var sumD = 0.0, grad = 0.0;
        var outside = false;
        for (var y = yA; y < yB && !outside; y += 2) {
          for (var x = xA; x < xB; x += 2) {
            if (!warp(x, y)) {
              outside = true;
              break;
            }
            final la = lumaRes(x, y);
            final lf = 0.299 * px[0] + 0.587 * px[1] + 0.114 * px[2];
            final d = lf - la;
            ds.add(d);
            sumD += d;
            final xr = x + 1 < iw ? x + 1 : x - 1;
            final yb = y + 1 < ih ? y + 1 : y - 1;
            grad += xr < 0 || yb < 0
                ? 0
                : (lumaRes(xr, y) - la).abs() + (lumaRes(x, yb) - la).abs();
          }
        }
        stats.tiles++;
        final n = ds.length;
        if (outside || n == 0) {
          stats.ghost++;
          continue;
        }
        final meanD = sumD / n;
        var dev = 0.0;
        for (final d in ds) {
          dev += (d - meanD).abs();
        }
        dev /= n;
        final tol = ghostTol + kBurstGhostGrad * (grad / n);
        if (dev > tol || meanD.abs() > offTol) {
          stats.ghost++;
          continue;
        }
        for (var y = yA; y < yB; y++) {
          for (var x = xA; x < xB; x++) {
            if (!warp(x, y)) continue;
            final j = y * iw + x, d = j * 3;
            final la = 0.299 * res[d] + 0.587 * res[d + 1] + 0.114 * res[d + 2];
            // v11.61: this tile's brightness offset removed first.
            final lf = 0.299 * px[0] + 0.587 * px[1] + 0.114 * px[2] - meanD;
            final dd = (lf - la).abs();
            final w = dd <= lo ? 1.0 : (dd >= hi ? 0.0 : (hi - dd) / (hi - lo));
            if (w <= 0) continue;
            acc[d] += w * (px[0] - meanD);
            acc[d + 1] += w * (px[1] - meanD);
            acc[d + 2] += w * (px[2] - meanD);
            wsum[j] += w;
            usedHere = true;
          }
        }
      }
    }
    if (usedHere) {
      stats.used.add(e.key);
      any = true;
    }
  }
  // v11.61: sharpen per pixel in proportion to what really merged there
  // (anchor-only pixels: none) → identical rule in every band (no seams).
  if (!any) stats.allGhostBands++;
  final amount = Float32List(iw * ih);
  for (var j = 0; j < iw * ih; j++) {
    final ws = wsum[j];
    acc[j * 3] /= ws;
    acc[j * 3 + 1] /= ws;
    acc[j * 3 + 2] /= ws;
    amount[j] = kBurstSharpen * math.min(1.0, ws - 1).toDouble();
  }
  _sharpenClamped(acc, iw, ih, res, amount);
  return res;
}

BurstMergeResult _result(
  BurstPlan plan,
  BandStats st,
  double sigma, {
  RgbFrame? image,
  bool timedOut = false,
}) {
  final used = timedOut ? 1 : st.used.length + 1;
  return BurstMergeResult(
    image: image,
    used: used,
    anchor: plan.anchor,
    notes: [
      for (final n in plan.notes)
        n.status == 'merged' && (timedOut || !st.used.contains(n.index))
            ? BurstFrameNote(
                n.index,
                n.sharpness,
                n.score,
                timedOut ? 'time' : 'ghost',
              )
            : n,
    ],
    sigma: sigma,
    ghostTiles: st.tiles == 0 ? 0 : st.ghost / st.tiles,
    timedOut: timedOut,
  );
}

/// In-memory merge (one band; tests call it directly). [inner] = the
/// output region (x, y, w, h) inside every frame (the rest is margin).
BurstMergeResult mergeBurst(
  List<RgbFrame> frames, {
  required (int, int, int, int) inner,
  int budgetMs = kBurstMergeBudgetMs,
}) {
  final sw = Stopwatch()..start();
  final (ix, iy, iw, ih) = inner;
  final w = frames.first.width, h = frames.first.height;
  final proxies = <GreyImage>[];
  final sharp = <double>[];
  for (final f in frames) {
    final (p, _) = burstProxy(f);
    proxies.add(p);
    // Sharpness at half proxy resolution (noise does not pose as detail).
    sharp.add(p.half().laplacianVariance());
  }
  final plan = planBurst(proxies, sharp, w, h);
  // Different-size frames cannot be warped here.
  for (var i = 0; i < frames.length; i++) {
    if (frames[i].width != w || frames[i].height != h) {
      plan.affines[i] = null;
    }
  }
  final a = frames[plan.anchor];
  final sigma = estimateNoise(a);
  final st = BandStats();
  if (sw.elapsedMilliseconds > budgetMs) {
    return _result(
      plan,
      st,
      sigma,
      image: RgbFrame(
        iw,
        ih,
        mergeBand(
          anchor: BandPiece(a, 0, 0),
          others: const {},
          plan: plan,
          out: inner,
          sigma: sigma,
          stats: st,
        ),
      ),
      timedOut: true,
    );
  }
  final rgb = mergeBand(
    anchor: BandPiece(a, 0, 0),
    others: {for (final i in plan.merging) i: BandPiece(frames[i], 0, 0)},
    plan: plan,
    out: (ix, iy, iw, ih),
    sigma: sigma,
    stats: st,
  );
  return _result(plan, st, sigma, image: RgbFrame(iw, ih, rgb));
}

/// Unsharp mask (3×3 box) whose result is clamped to the 3×3 min/max of
/// the merged image (no overshoot → no halos). Writes bytes into [out].
/// v11.61: per-pixel amount [ks] (0 = untouched).
void _sharpenClamped(
  Float32List m,
  int w,
  int h,
  Uint8List out,
  Float32List ks,
) {
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final k = ks[y * w + x];
      if (k <= 0) {
        for (var c = 0; c < 3; c++) {
          out[(y * w + x) * 3 + c] = m[(y * w + x) * 3 + c].round().clamp(
            0,
            255,
          );
        }
        continue;
      }
      for (var c = 0; c < 3; c++) {
        final v = m[(y * w + x) * 3 + c];
        var s = 0.0, mn = v, mx = v;
        var n = 0;
        for (var dy = -1; dy <= 1; dy++) {
          final yy = y + dy;
          if (yy < 0 || yy >= h) continue;
          for (var dx = -1; dx <= 1; dx++) {
            final xx = x + dx;
            if (xx < 0 || xx >= w) continue;
            final q = m[(yy * w + xx) * 3 + c];
            s += q;
            n++;
            if (q < mn) mn = q;
            if (q > mx) mx = q;
          }
        }
        final r = (v + k * (v - s / n)).clamp(mn, mx);
        out[(y * w + x) * 3 + c] = r.round().clamp(0, 255);
      }
    }
  }
}

// ---- Banded file merge ------------------------------------------------------

/// Reads an upright pixel rect of a still, [sample] = power-of-2 downscale.
typedef RegionReader =
    Future<RgbFrame> Function(
      String path,
      (int, int, int, int) rect,
      int sample,
    );

/// Output band rows for a region [w] wide (multiple of the tile size).
int bandRows(int w) {
  final r = (kBurstBandPixels / math.max(1, w)).floor();
  return math.max(kBurstTile, r - r % kBurstTile);
}

/// Bounding box (region coords) of [rect] under affine [m], padded,
/// clipped to [w]×[h].
(int, int, int, int) mappedBox(
  List<double> m,
  (int, int, int, int) rect,
  int w,
  int h, {
  int pad = 3,
}) {
  final (x, y, rw, rh) = rect;
  final xs = <double>[], ys = <double>[];
  for (final (X, Y) in [(x, y), (x + rw, y), (x, y + rh), (x + rw, y + rh)]) {
    xs.add(m[0] * X + m[1] * Y + m[2]);
    ys.add(m[3] * X + m[4] * Y + m[5]);
  }
  final l = math.max(0, xs.reduce(math.min).floor() - pad);
  final t = math.max(0, ys.reduce(math.min).floor() - pad);
  final r = math.min(w, xs.reduce(math.max).ceil() + pad + 1);
  final b = math.min(h, ys.reduce(math.max).ceil() + pad + 1);
  return (l, t, math.max(1, r - l), math.max(1, b - t));
}

/// The banded merge of [paths] over the still rect [region] (x, y, w, h;
/// region = inner + margin), output rect [inner] (region coords).
/// Registration once on sampled proxies, anchor by a full-resolution
/// centre crop, then band by band (fixed memory). Returns the merged
/// RGB of [inner] and the result, or a timed-out result (no image).
Future<(Uint8List?, BurstMergeResult)> mergeBurstBanded({
  required List<String> paths,
  required (int, int, int, int) region,
  required (int, int, int, int) inner,
  required RegionReader read,
  int budgetMs = kBurstBandedBudgetMs,
  int? rows,
}) async {
  final sw = Stopwatch()..start();
  final (rx, ry, rw, rh) = region;
  (int, int, int, int) still((int, int, int, int) r) =>
      (r.$1 + rx, r.$2 + ry, r.$3, r.$4);
  // 1. Proxies (sampled decode of the whole region).
  var sample = 1;
  while (math.max(rw, rh) / (sample * 2) >= kBurstProxyLong) {
    sample *= 2;
  }
  final proxies = <GreyImage>[];
  for (final p in paths) {
    final f = await read(p, region, sample);
    proxies.add(burstProxy(f).$1);
  }
  final pw = proxies.map((e) => e.width).reduce(math.min);
  final ph = proxies.map((e) => e.height).reduce(math.min);
  final same = [
    for (final g in proxies)
      g.width == pw && g.height == ph ? g : _cropGrey(g, pw, ph),
  ];
  // 2. Sharpness + noise from a full-resolution centre crop.
  final cs = math.min(384, math.min(rw, rh));
  final crop = ((rw - cs) ~/ 2, (rh - cs) ~/ 2, cs, cs);
  final sharp = <double>[];
  final centres = <RgbFrame>[];
  for (final p in paths) {
    final f = await read(p, still(crop), 1);
    centres.add(f);
    sharp.add(lumaGrey(f).half().laplacianVariance());
  }
  final plan = planBurst(same, sharp, rw, rh);
  final sigma = estimateNoise(centres[plan.anchor]);
  final st = BandStats();
  final (ix, iy, iw, ih) = inner;
  final out = Uint8List(iw * ih * 3);
  final step = rows ?? bandRows(iw);
  const t = kBurstTile;
  int down(int v) => v - v % t;
  int up(int v) => down(v + t - 1);
  for (var y0 = iy; y0 < iy + ih;) {
    if (sw.elapsedMilliseconds > budgetMs) {
      return (null, _result(plan, st, sigma, timedOut: true));
    }
    // Band ends on the region tile grid: every tile verdict is the same as
    // in a single-band merge (no seams).
    final y1 = math.min(iy + ih, math.max(up(y0 + 1), down(y0 + step)));
    // Whole tiles + ≥ 1 extra row each side (sharpen neighbourhood);
    // clipped to the inner rect like the single-band merge.
    final eTop = math.max(iy, down(y0 - 1));
    final eBot = math.min(iy + ih, up(y1 + 1));
    final ext = (ix, eTop, iw, eBot - eTop);
    final aRect = ext;
    final aPiece = BandPiece(
      await read(paths[plan.anchor], still(aRect), 1),
      aRect.$1,
      aRect.$2,
    );
    final others = <int, BandPiece>{};
    for (final i in plan.merging) {
      final box = mappedBox(plan.affines[i]!, ext, rw, rh);
      others[i] = BandPiece(
        await read(paths[i], still(box), 1),
        box.$1,
        box.$2,
      );
    }
    final rgb = mergeBand(
      anchor: aPiece,
      others: others,
      plan: plan,
      out: ext,
      sigma: sigma,
      stats: st,
    );
    // Copy the band rows (drop the extra rows).
    for (var y = y0; y < y1; y++) {
      final src = ((y - eTop) * iw) * 3;
      out.setRange(((y - iy) * iw) * 3, ((y - iy) * iw + iw) * 3, rgb, src);
    }
    y0 = y1;
  }
  return (out, _result(plan, st, sigma));
}

GreyImage _cropGrey(GreyImage g, int w, int h) {
  final d = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      d[y * w + x] = g.data[y * g.width + x];
    }
  }
  return GreyImage(w, h, d);
}

GreyImage lumaGrey(RgbFrame f) {
  final d = Float32List(f.width * f.height);
  for (var i = 0; i < d.length; i++) {
    d[i] = f.lumaAt(i);
  }
  return GreyImage(f.width, f.height, d);
}

// ---- Files / platform ------------------------------------------------------

const MethodChannel _region = MethodChannel('ai_camera/region');

/// Upright size of a JPEG (native; Dart fallback).
Future<(int, int)> uprightSize(String path) async {
  try {
    final r = await _region.invokeMapMethod<String, Object?>('info', {
      'path': path,
    });
    if (r != null) return (r['width'] as int, r['height'] as int);
  } catch (_) {}
  return Isolate.run(() {
    final raw = img.decodeImage(File(path).readAsBytesSync());
    if (raw == null) throw const FormatException('undecodable');
    final u = img.bakeOrientation(raw);
    return (u.width, u.height);
  });
}

/// Native region decode (upright rect, [sample] power of 2) into RGB.
Future<RgbFrame> nativeRegion(
  String path,
  (int, int, int, int) rect,
  int sample,
) async {
  final (x, y, w, h) = rect;
  final r = await _region.invokeMapMethod<String, Object?>('decodeBytes', {
    'path': path,
    'x': x,
    'y': y,
    'w': w,
    'h': h,
    'sample': sample,
  });
  if (r == null) throw StateError('region decode');
  return RgbFrame(r['width'] as int, r['height'] as int, r['rgb'] as Uint8List);
}

/// Dart fallback reader: decodes each still once (cached) — only for
/// stills up to [maxPixels] (larger: too slow / big → caller falls back).
RegionReader dartRegionReader({int maxPixels = 6000000}) {
  final cache = <String, img.Image>{};
  return (path, rect, sample) async {
    final im = cache[path] ??= () {
      final raw = img.decodeImage(File(path).readAsBytesSync());
      if (raw == null) throw const FormatException('undecodable');
      final u = img.bakeOrientation(raw);
      if (u.width * u.height > maxPixels) {
        throw StateError('still too large for the Dart fallback');
      }
      return u;
    }();
    final (x, y, w, h) = rect;
    var c = img.copyCrop(im, x: x, y: y, width: w, height: h);
    if (sample > 1) {
      c = img.copyResize(
        c,
        width: math.max(1, w ~/ sample),
        height: math.max(1, h ~/ sample),
        interpolation: img.Interpolation.average,
      );
    }
    return RgbFrame(c.width, c.height, c.getBytes(order: img.ChannelOrder.rgb));
  };
}

/// Decodes the upright pixel rect of [path] into a packed RGB file (used
/// by the tracked-source crops). Returns (rgbPath, width, height).
Future<(String, int, int)> decodeRegion(
  String path,
  (int, int, int, int) rect,
  String outPath,
) async {
  RgbFrame f;
  try {
    f = await nativeRegion(path, rect, 1);
  } catch (_) {
    f = await Isolate.run(() => dartRegionReader()(path, rect, 1));
  }
  File(outPath).writeAsBytesSync(f.rgb, flush: true);
  return (outPath, f.width, f.height);
}

/// Cancellable background banded merge: cancel() kills the isolate at
/// once. Native region decode from the isolate (background platform
/// channel), Dart fallback for small stills.
class BurstJob {
  BurstJob._(this._iso, this.result);
  final Isolate _iso;
  final Future<BurstMergeResult?> result;
  void cancel() => _iso.kill(priority: Isolate.immediate);

  static Future<BurstJob> start({
    required List<String> paths,
    required (int, int, int, int) region,
    required (int, int, int, int) inner,
    required String outJpeg,
    int budgetMs = kBurstBandedBudgetMs,

    /// false = Dart decode only (host tests: no platform channel).
    bool native = true,
  }) async {
    final port = ReceivePort();
    final done = Completer<BurstMergeResult?>();
    final token = native ? RootIsolateToken.instance : null;
    final iso = await Isolate.spawn(
      _entry,
      (port.sendPort, token, paths, region, inner, outJpeg, budgetMs),
      onExit: port.sendPort,
      errorsAreFatal: true,
    );
    port.listen((m) {
      if (!done.isCompleted) done.complete(m is BurstMergeResult ? m : null);
      port.close();
    });
    return BurstJob._(iso, done.future);
  }

  static Future<void> _entry(
    (
      SendPort,
      RootIsolateToken?,
      List<String>,
      (int, int, int, int),
      (int, int, int, int),
      String,
      int,
    )
    a,
  ) async {
    final (send, token, paths, region, inner, outJpeg, budget) = a;
    try {
      var nativeOk = false;
      if (token != null) {
        try {
          BackgroundIsolateBinaryMessenger.ensureInitialized(token);
          nativeOk = true;
        } catch (_) {}
      }
      final dart = dartRegionReader();
      Future<RgbFrame> read(String p, (int, int, int, int) r, int s) async {
        if (nativeOk) {
          try {
            return await nativeRegion(p, r, s);
          } catch (_) {
            nativeOk = false;
          }
        }
        return dart(p, r, s);
      }

      final (rgb, res) = await mergeBurstBanded(
        paths: paths,
        region: region,
        inner: inner,
        read: read,
        budgetMs: budget,
      );
      if (rgb != null) {
        final im = img.Image.fromBytes(
          width: inner.$3,
          height: inner.$4,
          bytes: rgb.buffer,
          numChannels: 3,
        );
        File(
          outJpeg,
        ).writeAsBytesSync(img.encodeJpg(im, quality: 95), flush: true);
      }
      send.send(res);
    } catch (_) {
      send.send(null);
    }
  }
}

/// Best-effort removal of temporary burst files.
void deleteQuietly(Iterable<String> paths) {
  for (final p in paths) {
    try {
      final f = File(p);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
}
