import 'dart:math' as math;
import 'dart:typed_data';

/// v11.60 image registration shared by the wide→close zoom tracker and the
/// burst merge. Pure Dart, no allocation-heavy image objects: small grey
/// proxies in, a similarity transform (scale, rotation, translation) and an
/// honest confidence (masked NCC after alignment) out.
///
/// Coordinates: every image uses CENTRED, WIDTH-NORMALISED coordinates:
/// u = (x + 0.5 − w/2) / w, v = (y + 0.5 − h/2) / w. So the frame spans
/// u ∈ [−0.5, 0.5] and v ∈ [−h/2w, h/2w], independent of resolution, and
/// transforms between differently sized proxies of the same view compose.

/// A grey image (any value range; float).
class GreyImage {
  GreyImage(this.width, this.height, this.data)
    : assert(data.length == width * height);
  final int width;
  final int height;
  final Float32List data;

  factory GreyImage.fromBytes(int w, int h, List<int> bytes) {
    final d = Float32List(w * h);
    for (var i = 0; i < d.length; i++) {
      d[i] = bytes[i].toDouble();
    }
    return GreyImage(w, h, d);
  }

  double get aspect => height / width;

  /// 2×2 box downsample (odd edge dropped).
  GreyImage half() {
    final w = width ~/ 2, h = height ~/ 2;
    final d = Float32List(w * h);
    for (var y = 0; y < h; y++) {
      final r0 = 2 * y * width, r1 = r0 + width;
      for (var x = 0; x < w; x++) {
        final c = 2 * x;
        d[y * w + x] =
            (data[r0 + c] +
                data[r0 + c + 1] +
                data[r1 + c] +
                data[r1 + c + 1]) *
            0.25;
      }
    }
    return GreyImage(w, h, d);
  }

  /// Bilinear sample at pixel coords; NaN outside [0, w−1]×[0, h−1].
  double sample(double x, double y) {
    if (x < 0 || y < 0 || x > width - 1 || y > height - 1) return double.nan;
    final x0 = x.floor(), y0 = y.floor();
    final x1 = x0 + 1 < width ? x0 + 1 : x0;
    final y1 = y0 + 1 < height ? y0 + 1 : y0;
    final fx = x - x0, fy = y - y0;
    final r0 = y0 * width, r1 = y1 * width;
    final a = data[r0 + x0] + (data[r0 + x1] - data[r0 + x0]) * fx;
    final b = data[r1 + x0] + (data[r1 + x1] - data[r1 + x0]) * fx;
    return a + (b - a) * fy;
  }

  /// Laplacian variance (focus / blur measure; higher = sharper).
  double laplacianVariance() {
    var s = 0.0, s2 = 0.0;
    var n = 0;
    for (var y = 1; y < height - 1; y++) {
      for (var x = 1; x < width - 1; x++) {
        final i = y * width + x;
        final l =
            data[i - 1] +
            data[i + 1] +
            data[i - width] +
            data[i + width] -
            4 * data[i];
        s += l;
        s2 += l * l;
        n++;
      }
    }
    if (n == 0) return 0;
    final m = s / n;
    return s2 / n - m * m;
  }

  double mean() {
    var s = 0.0;
    for (final v in data) {
      s += v;
    }
    return data.isEmpty ? 0 : s / data.length;
  }
}

/// p' = [a −b; b a]·p + (tx, ty) in centred normalised coordinates.
class Similarity {
  const Similarity(this.a, this.b, this.tx, this.ty);
  const Similarity.identity() : a = 1, b = 0, tx = 0, ty = 0;
  factory Similarity.of({
    double scale = 1,
    double angle = 0,
    double tx = 0,
    double ty = 0,
  }) => Similarity(scale * math.cos(angle), scale * math.sin(angle), tx, ty);

  final double a, b, tx, ty;

  double get scale => math.sqrt(a * a + b * b);
  double get angle => math.atan2(b, a);

  (double, double) apply(double u, double v) =>
      (a * u - b * v + tx, b * u + a * v + ty);

  /// (this ∘ other)(p) = this(other(p)).
  Similarity compose(Similarity o) => Similarity(
    a * o.a - b * o.b,
    a * o.b + b * o.a,
    a * o.tx - b * o.ty + tx,
    b * o.tx + a * o.ty + ty,
  );

  Similarity inverse() {
    final s2 = a * a + b * b;
    final ia = a / s2, ib = -b / s2;
    return Similarity(ia, ib, -(ia * tx - ib * ty), -(ib * tx + ia * ty));
  }

  bool get isFinite =>
      a.isFinite && b.isFinite && tx.isFinite && ty.isFinite && scale > 1e-6;

  @override
  String toString() =>
      's ${scale.toStringAsFixed(3)} r ${(angle * 180 / math.pi).toStringAsFixed(1)}° '
      't (${tx.toStringAsFixed(3)}, ${ty.toStringAsFixed(3)})';
}

class Registration {
  const Registration(this.transform, this.score, this.overlap);
  static const failed = Registration(Similarity.identity(), -1, 0);

  /// Maps image A's coordinates into image B's.
  final Similarity transform;

  /// Masked NCC of A vs warped B over the overlap (−1 = no evidence).
  final double score;

  /// Fraction of A's pixels that land inside B.
  final double overlap;
}

/// Huber threshold (normalised-intensity residual units).
const double kHuber = 1.0;

/// Fewer valid overlap pixels than this fraction of A → no evidence.
const double kRegisterMinOverlap = 0.5;

/// Standard deviation below this (grey levels) = flat, untrackable.
const double kRegisterMinStd = 2.0;

List<GreyImage> pyramid(GreyImage im, {int minSide = 16}) {
  final out = [im];
  while (math.min(out.last.width, out.last.height) ~/ 2 >= minSide) {
    out.add(out.last.half());
  }
  return out;
}

/// Masked NCC of A(p) vs B(T p), sampling A every [step] px. Returns
/// (score, overlap fraction). Score −1 when there is no evidence.
(double, double) nccUnder(
  GreyImage a,
  GreyImage b,
  Similarity t, {
  int step = 1,
}) {
  var n = 0, total = 0;
  var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0;
  final aw = a.width.toDouble(), bw = b.width.toDouble();
  final ahc = a.height / 2, bhc = b.height / 2;
  for (var y = 0; y < a.height; y += step) {
    final v = (y + 0.5 - ahc) / aw;
    for (var x = 0; x < a.width; x += step) {
      total++;
      final u = (x + 0.5 - aw / 2) / aw;
      final pu = t.a * u - t.b * v + t.tx, pv = t.b * u + t.a * v + t.ty;
      final bv = b.sample(pu * bw + bw / 2 - 0.5, pv * bw + bhc - 0.5);
      if (bv.isNaN) continue;
      final av = a.data[y * a.width + x];
      sa += av;
      sb += bv;
      saa += av * av;
      sbb += bv * bv;
      sab += av * bv;
      n++;
    }
  }
  final overlap = total == 0 ? 0.0 : n / total;
  if (n < 16 || overlap < kRegisterMinOverlap) return (-1, overlap);
  final va = saa / n - (sa / n) * (sa / n);
  final vb = sbb / n - (sb / n) * (sb / n);
  if (va < kRegisterMinStd * kRegisterMinStd ||
      vb < kRegisterMinStd * kRegisterMinStd) {
    return (-1, overlap);
  }
  final cov = sab / n - (sa / n) * (sb / n);
  return (cov / math.sqrt(va * vb), overlap);
}

/// One Gauss–Newton (Lucas–Kanade) pass of the 4-parameter similarity on
/// normalised intensities (gain/offset invariant). Returns the update or
/// null when the system is degenerate.
Similarity? _gnStep(GreyImage a, GreyImage b, Similarity t) {
  final aw = a.width.toDouble(), bw = b.width.toDouble();
  final ahc = a.height / 2, bhc = b.height / 2;
  // Pass 1: means / stds over the overlap.
  var n = 0;
  var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0;
  final bx = Float64List(a.width * a.height);
  final by = Float64List(a.width * a.height);
  final bvals = Float64List(a.width * a.height);
  final ok = Uint8List(a.width * a.height);
  for (var y = 0; y < a.height; y++) {
    final v = (y + 0.5 - ahc) / aw;
    for (var x = 0; x < a.width; x++) {
      final u = (x + 0.5 - aw / 2) / aw;
      final px = (t.a * u - t.b * v + t.tx) * bw + bw / 2 - 0.5;
      final py = (t.b * u + t.a * v + t.ty) * bw + bhc - 0.5;
      if (px < 1 || py < 1 || px > b.width - 2 || py > b.height - 2) continue;
      final i = y * a.width + x;
      final c = b.sample(px, py);
      bvals[i] = c;
      // Gradient in B pixels → per normalised unit (× bw).
      bx[i] = (b.sample(px + 1, py) - b.sample(px - 1, py)) * 0.5 * bw;
      by[i] = (b.sample(px, py + 1) - b.sample(px, py - 1)) * 0.5 * bw;
      ok[i] = 1;
      final av = a.data[i];
      sa += av;
      saa += av * av;
      sb += c;
      sbb += c * c;
      n++;
    }
  }
  if (n < 16 || n < a.width * a.height * kRegisterMinOverlap) return null;
  final ma = sa / n, mb = sb / n;
  final da = math.sqrt(math.max(1e-9, saa / n - ma * ma));
  final db = math.sqrt(math.max(1e-9, sbb / n - mb * mb));
  if (da < kRegisterMinStd || db < kRegisterMinStd) return null;
  final h = Float64List(16), g = Float64List(4);
  final j = Float64List(4);
  for (var y = 0; y < a.height; y++) {
    final v = (y + 0.5 - ahc) / aw;
    for (var x = 0; x < a.width; x++) {
      final i = y * a.width + x;
      if (ok[i] == 0) continue;
      final u = (x + 0.5 - aw / 2) / aw;
      final gx = bx[i] / db, gy = by[i] / db;
      final r = (bvals[i] - mb) / db - (a.data[i] - ma) / da;
      // Huber weight: a local mover / outlier cannot drag the transform.
      final ar = r.abs();
      final wt = ar <= kHuber ? 1.0 : kHuber / ar;
      j[0] = gx * u + gy * v;
      j[1] = -gx * v + gy * u;
      j[2] = gx;
      j[3] = gy;
      for (var p = 0; p < 4; p++) {
        g[p] += wt * j[p] * r;
        for (var q = p; q < 4; q++) {
          h[p * 4 + q] += wt * j[p] * j[q];
        }
      }
    }
  }
  for (var p = 0; p < 4; p++) {
    for (var q = 0; q < p; q++) {
      h[p * 4 + q] = h[q * 4 + p];
    }
    h[p * 4 + p] *= 1.0001; // tiny damping
  }
  final d = _solve4(h, g);
  if (d == null) return null;
  return Similarity(t.a - d[0], t.b - d[1], t.tx - d[2], t.ty - d[3]);
}

List<double>? _solve4(Float64List m, Float64List rhs) {
  final a = [
    for (var r = 0; r < 4; r++)
      [for (var c = 0; c < 4; c++) m[r * 4 + c], rhs[r]],
  ];
  for (var c = 0; c < 4; c++) {
    var piv = c;
    for (var r = c + 1; r < 4; r++) {
      if (a[r][c].abs() > a[piv][c].abs()) piv = r;
    }
    if (a[piv][c].abs() < 1e-12) return null;
    final tmp = a[c];
    a[c] = a[piv];
    a[piv] = tmp;
    for (var r = 0; r < 4; r++) {
      if (r == c) continue;
      final f = a[r][c] / a[c][c];
      for (var k = c; k < 5; k++) {
        a[r][k] -= f * a[c][k];
      }
    }
  }
  return [for (var r = 0; r < 4; r++) a[r][4] / a[r][r]];
}

/// Registers A into B: the similarity mapping A's coordinates into B's.
/// Coarse exhaustive search (scales [guess.scale] × [scaleFactors],
/// translations ±[radius] px at the coarsest level around [guess]), then
/// Gauss–Newton refinement level by level. The final score is the masked
/// NCC at the finest level. Pure; deterministic.
Registration registerSimilarity(
  GreyImage a,
  GreyImage b, {
  Similarity guess = const Similarity.identity(),
  List<double> scaleFactors = const [1.0],
  int radius = 3,
  int iterations = 6,
  int minSide = 12,
}) {
  final pa = pyramid(a, minSide: minSide);
  final pb = pyramid(b, minSide: minSide);
  // Matched pixel density: A covering 1/s of B's width is compared at the
  // A level whose pixels are about as large as B's (A is not penalised for
  // detail B cannot hold).
  final s0 = guess.scale;
  final k = s0 >= 1
      ? 0
      : math.max(0, (math.log(1 / s0) / math.ln2 + 0.25).floor());
  final off = math.min(k, pa.length - 1);
  final levels = math.min(pa.length - off, pb.length);
  final top = levels - 1;
  final ta = pa[top + off], tb = pb[top];
  // Coarse search at the top level.
  var best = guess;
  var bestScore = -2.0;
  final step = 1.0 / tb.width; // one top-level B pixel, normalised
  for (final f in scaleFactors) {
    final base = Similarity(guess.a * f, guess.b * f, guess.tx, guess.ty);
    for (var dy = -radius; dy <= radius; dy++) {
      for (var dx = -radius; dx <= radius; dx++) {
        final t = Similarity(
          base.a,
          base.b,
          base.tx + dx * step,
          base.ty + dy * step,
        );
        final (s, _) = nccUnder(ta, tb, t);
        if (s > bestScore) {
          bestScore = s;
          best = t;
        }
      }
    }
  }
  if (bestScore <= -1) return Registration.failed;
  // Refine coarse → fine.
  var t = best;
  for (var l = top; l >= 0; l--) {
    final la = pa[l + off], lb = pb[l];
    for (var it = 0; it < iterations; it++) {
      final n = _gnStep(la, lb, t);
      if (n == null || !n.isFinite) break;
      final moved =
          (n.tx - t.tx).abs() +
          (n.ty - t.ty).abs() +
          (n.a - t.a).abs() +
          (n.b - t.b).abs();
      // Reject divergent steps (keep the better of old / new).
      final st = la.width * la.height > 40000 ? 2 : 1;
      final (sNew, _) = nccUnder(la, lb, n, step: st);
      final (sOld, _) = nccUnder(la, lb, t, step: st);
      if (sNew < sOld) break;
      t = n;
      if (moved < 1e-5) break;
    }
  }
  final (score, overlap) = nccUnder(pa[off], pb[0], t);
  return Registration(t, score, overlap);
}

/// Robust alignment confidence: the MEDIAN of per-tile NCCs over a
/// [grid]×[grid] split of A (tiles without evidence skipped). A local
/// moving object lowers a few tiles, not the verdict; a wrong subject or
/// a wrong transform lowers most. −1 when fewer than half the tiles have
/// evidence. Pure.
double tileMedianNcc(GreyImage a, GreyImage b, Similarity t, {int grid = 4}) {
  final scores = <double>[];
  final aw = a.width.toDouble(), bw = b.width.toDouble();
  final ahc = a.height / 2, bhc = b.height / 2;
  for (var gy = 0; gy < grid; gy++) {
    for (var gx = 0; gx < grid; gx++) {
      final x0 = a.width * gx ~/ grid, x1 = a.width * (gx + 1) ~/ grid;
      final y0 = a.height * gy ~/ grid, y1 = a.height * (gy + 1) ~/ grid;
      var n = 0;
      var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0;
      for (var y = y0; y < y1; y++) {
        final v = (y + 0.5 - ahc) / aw;
        for (var x = x0; x < x1; x++) {
          final u = (x + 0.5 - aw / 2) / aw;
          final pu = t.a * u - t.b * v + t.tx, pv = t.b * u + t.a * v + t.ty;
          final bv = b.sample(pu * bw + bw / 2 - 0.5, pv * bw + bhc - 0.5);
          if (bv.isNaN) continue;
          final av = a.data[y * a.width + x];
          sa += av;
          sb += bv;
          saa += av * av;
          sbb += bv * bv;
          sab += av * bv;
          n++;
        }
      }
      if (n < 16 || n < (x1 - x0) * (y1 - y0) * kRegisterMinOverlap) continue;
      final va = saa / n - (sa / n) * (sa / n);
      final vb = sbb / n - (sb / n) * (sb / n);
      if (va < kRegisterMinStd * kRegisterMinStd ||
          vb < kRegisterMinStd * kRegisterMinStd) {
        continue;
      }
      scores.add((sab / n - (sa / n) * (sb / n)) / math.sqrt(va * vb));
    }
  }
  if (scores.length * 2 < grid * grid) return -1;
  scores.sort();
  final m = scores.length;
  return m.isOdd ? scores[m ~/ 2] : (scores[m ~/ 2 - 1] + scores[m ~/ 2]) / 2;
}

/// Pixel coords (x, y) of normalised (u, v) in a w×h image.
(double, double) toPixel(double u, double v, int w, int h) =>
    (u * w + w / 2 - 0.5, v * w + h / 2 - 0.5);

/// Normalised (u, v) of pixel (x, y) in a w×h image.
(double, double) toNorm(double x, double y, int w, int h) =>
    ((x + 0.5 - w / 2) / w, (y + 0.5 - h / 2) / w);
