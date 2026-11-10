import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'night_pipeline.dart' show GrayProxy;

/// Free on-device HDR: a 3-frame exposure bracket (−s / 0 / +s EV) merged
/// with single-scale exposure fusion (Mertens-style well-exposedness
/// weights computed on a small proxy, smoothed, then applied at full
/// resolution), global-shift alignment and ghost rejection.

/// Bracket offsets for the device's exposure-compensation range. Empty when
/// the camera can't bracket meaningfully (HDR falls back to one frame).
/// Order = capture order: reference (0 EV) first, then under, then over.
List<double> hdrBracketEv({
  required double minEv,
  required double maxEv,
  double preferredStep = 2.0,
}) {
  if (!minEv.isFinite || !maxEv.isFinite) return const [];
  final room = math.min(maxEv, -minEv);
  final step = math.min(preferredStep, room * 0.8);
  if (step < 0.7) return const [];
  final s = (step * 3).floor() / 3; // camera EV steps are usually 1/3 EV
  return [0, -s, s];
}

/// v11.48: share of the reference (0 EV) frame kept everywhere.
const double kHdrRefShare = 0.35;

/// v11.48: weight blur radius = proxy width / this (was /96: halos).
const double kHdrBlurDiv = 24;

/// v11.48: frames whose bitmaps still disagree this much at the fine
/// level are dropped.
const double kHdrMaxFineErr = 0.3;

/// v11.48: frames with more ghost pixels than this share are dropped.
const double kHdrMaxGhostShare = 0.3;

/// Well-exposedness weight of a 0..1 luma (Gaussian around 0.5, σ 0.2).
double wellExposedness(double l) {
  final d = l - 0.5;
  return math.exp(-(d * d) / (2 * 0.2 * 0.2)) + 1e-3;
}

/// Ghost factor: 1 = consistent with the reference, ~0 = something moved.
/// [l] = this frame's 0..1 luma, [predicted] = what the reference luma maps
/// to in this frame (see [comparametricLut]). Not judged where the
/// reference itself is clipped ([refClipped]).
double ghostFactor(
  double l,
  double predicted, {
  bool refClipped = false,
  double tol = 0.2,
}) {
  if (refClipped) return 1;
  return (l - predicted).abs() > tol ? 0.02 : 1;
}

/// Exposure-invariant mapping ref luma → frame luma by histogram matching
/// (works with any camera tone curve and with clipping). 256 entries, 0..1.
Float32List comparametricLut(Float32List refL, Float32List frameL) {
  List<int> hist(Float32List l) {
    final h = List<int>.filled(256, 0);
    for (final v in l) {
      h[(v * 255).round().clamp(0, 255)]++;
    }
    return h;
  }

  final hr = hist(refL), hf = hist(frameL);
  final cr = List<double>.filled(256, 0), cf = List<double>.filled(256, 0);
  var a = 0, b = 0;
  for (var i = 0; i < 256; i++) {
    a += hr[i];
    b += hf[i];
    cr[i] = a / refL.length;
    cf[i] = b / frameL.length;
  }
  final lut = Float32List(256);
  var j = 0;
  for (var i = 0; i < 256; i++) {
    // Middle of the reference bin's CDF range → matching frame value.
    final target = (cr[i] + (i == 0 ? 0 : cr[i - 1])) / 2;
    while (j < 255 && cf[j] < target) {
      j++;
    }
    lut[i] = j / 255;
  }
  return lut;
}

/// Ward-style threshold bitmap at quantile [q] (exposure-invariant
/// alignment). Pixels within ±[exclude] of the threshold are ignored (128).
GrayProxy _mtbProxy(_Proxy pr, {double q = 0.5, double exclude = 4 / 255}) {
  final sorted = Float32List.fromList(pr.l)..sort();
  final t = sorted[(q * (sorted.length - 1)).round()];
  final d = Uint8List(pr.l.length);
  for (var i = 0; i < d.length; i++) {
    final v = pr.l[i];
    d[i] = (v - t).abs() <= exclude ? 128 : (v > t ? 255 : 0);
  }
  return GrayProxy(pr.w, pr.h, d);
}

/// Quantile where BOTH frames are unclipped (the median when possible), so
/// their bitmaps split the scene at the same place even if one frame clips.
double _sharedQuantile(_Proxy a, _Proxy b) {
  (double, double) range(_Proxy p) {
    var lo = 0, hi = 0;
    for (final v in p.l) {
      if (v <= 0.02) lo++;
      if (v < 0.98) hi++;
    }
    return (lo / p.l.length, hi / p.l.length);
  }

  final (alo, ahi) = range(a);
  final (blo, bhi) = range(b);
  final lo = math.max(alo, blo), hi = math.min(ahi, bhi);
  if (hi - lo < 0.06) return 0.5;
  if (lo <= 0.5 && hi >= 0.5) return 0.5;
  return (lo + hi) / 2;
}

/// Best (dx, dy) within ±[radius] with frame(x+dx, y+dy) ≈ ref(x, y) on
/// MTB proxies: XOR error over pixels not excluded in either, ties broken
/// toward the smallest shift. Returns (dx, dy, disagreeShare 0..1).
(int, int, double) mtbShift(
  GrayProxy ref,
  GrayProxy f, {
  int radius = 10,
  int cx = 0,
  int cy = 0,
}) {
  final w = ref.width;
  final h = ref.height;
  final int m = radius + math.max<int>(cx.abs(), cy.abs()) + 1;
  var best = (cx, cy, double.infinity);
  var bestScore = double.infinity;
  for (var dy = cy - radius; dy <= cy + radius; dy++) {
    for (var dx = cx - radius; dx <= cx + radius; dx++) {
      var bad = 0;
      var n = 0;
      for (var y = m; y < h - m; y++) {
        final ry = y * w;
        final fy = (y + dy) * w;
        for (var x = m; x < w - m; x++) {
          final a = ref.data[ry + x];
          final b = f.data[fy + x + dx];
          if (a == 128 || b == 128) continue;
          if (a != b) bad++;
          n++;
        }
      }
      if (n < 16) continue;
      final e = bad / n;
      final score = e + 0.002 * ((dx - cx).abs() + (dy - cy).abs());
      if (score < bestScore) {
        bestScore = score;
        best = (dx, dy, e);
      }
    }
  }
  // Nothing comparable (tiny / flat image): assume no shift.
  return best.$3.isFinite ? best : (cx, cy, 0.0);
}

class HdrMerged {
  const HdrMerged(this.image, this.used, this.shifts, this.ghostPixels);
  final img.Image image;
  final int used;
  final List<(int, int)> shifts;

  /// Proxy pixels where a non-reference frame was rejected as a ghost.
  final int ghostPixels;
}

class _Proxy {
  _Proxy(this.w, this.h, this.l);
  final int w;
  final int h;

  /// Luma 0..1.
  final Float32List l;
}

_Proxy _lumaProxy(img.Image im, int pw, int ph) {
  final small = (im.width == pw && im.height == ph)
      ? im
      : img.copyResize(
          im,
          width: pw,
          height: ph,
          interpolation: img.Interpolation.average,
        );
  final b = small.getBytes(order: img.ChannelOrder.rgb);
  final l = Float32List(pw * ph);
  for (var i = 0, j = 0; i < l.length; i++, j += 3) {
    l[i] = (b[j] * 0.299 + b[j + 1] * 0.587 + b[j + 2] * 0.114) / 255.0;
  }
  return _Proxy(pw, ph, l);
}

Float32List _boxBlur(Float32List src, int w, int h, int r) {
  if (r <= 0) return src;
  final tmp = Float32List(src.length);
  final out = Float32List(src.length);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var s = 0.0;
      var n = 0;
      for (var k = -r; k <= r; k++) {
        final xx = x + k;
        if (xx < 0 || xx >= w) continue;
        s += src[y * w + xx];
        n++;
      }
      tmp[y * w + x] = s / n;
    }
  }
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var s = 0.0;
      var n = 0;
      for (var k = -r; k <= r; k++) {
        final yy = y + k;
        if (yy < 0 || yy >= h) continue;
        s += tmp[yy * w + x];
        n++;
      }
      out[y * w + x] = s / n;
    }
  }
  return out;
}

/// Pure merge. [frames][0] is the reference (0 EV, sharpest timing); the
/// others are aligned to it. Frames of another size are skipped.
HdrMerged mergeHdr(
  List<img.Image> frames, {
  int proxyWidth = 256,
  int maxShift = 64,
  int refineWidth = 1024,
}) {
  final ref = frames.first;
  final w = ref.width;
  final h = ref.height;
  final pw = math.min(proxyWidth, w);
  final ph = math.max(1, (h * pw / w).round());
  final scale = w / pw;

  final refProxy = _lumaProxy(ref, pw, ph);
  final used = <img.Image>[ref];
  final shifts = <(int, int)>[(0, 0)];
  final proxies = <_Proxy>[refProxy];
  // Fine level for sub-proxy accuracy (coarse-to-fine MTB).
  final fw = math.min(refineWidth, w);
  final fh = math.max(1, (h * fw / w).round());
  final fineScale = w / fw;
  final refine = fw > pw;
  final refFineL = refine ? _lumaProxy(ref, fw, fh) : null;
  for (final f in frames.skip(1)) {
    if (f.width != w || f.height != h) continue;
    final pr = _lumaProxy(f, pw, ph);
    // Keep enough overlap to compare: search at most a quarter of the proxy.
    final radius = math.max(
      1,
      math.min((maxShift / scale).ceil(), math.min(pw, ph) ~/ 4),
    );
    final q = _sharedQuantile(refProxy, pr);
    final (dx, dy, err) = mtbShift(
      _mtbProxy(refProxy, q: q),
      _mtbProxy(pr, q: q),
      radius: radius,
    );
    // err = share of compared pixels whose bits disagree; >0.35 → drop.
    if (err > 0.35) continue;
    var fx = (dx * scale).round(), fy = (dy * scale).round();
    if (refFineL != null) {
      final k = scale / fineScale;
      final fl = _lumaProxy(f, fw, fh);
      final fq = _sharedQuantile(refFineL, fl);
      final (rx, ry, _) = mtbShift(
        _mtbProxy(refFineL, q: fq),
        _mtbProxy(fl, q: fq),
        radius: k.ceil() + 1,
        cx: (dx * k).round(),
        cy: (dy * k).round(),
      );
      fx = (rx * fineScale).round();
      fy = (ry * fineScale).round();
      // v11.48: still misaligned at the fine level → drop the frame.
      final (_, _, fe) = mtbShift(
        _mtbProxy(refFineL, q: fq),
        _mtbProxy(fl, q: fq),
        radius: 0,
        cx: rx,
        cy: ry,
      );
      if (fe > kHdrMaxFineErr) continue;
    }
    used.add(f);
    shifts.add((fx, fy));
    proxies.add(_shiftProxy(pr, dx, dy));
  }

  // v11.48: a frame that is mostly ghost (moved scene / bad alignment) is
  // dropped; nothing left → the reference frame alone.
  for (var k = used.length - 1; k >= 1; k--) {
    final lut = comparametricLut(refProxy.l, proxies[k].l);
    var g = 0;
    for (var i = 0; i < pw * ph; i++) {
      final lr = refProxy.l[i];
      if (lr < 0.02 || lr > 0.98) continue;
      if (ghostFactor(proxies[k].l[i], lut[(lr * 255).round().clamp(0, 255)]) <
          1) {
        g++;
      }
    }
    if (g > pw * ph * kHdrMaxGhostShare) {
      used.removeAt(k);
      shifts.removeAt(k);
      proxies.removeAt(k);
    }
  }
  if (used.length < 2) return HdrMerged(ref, 1, const [(0, 0)], 0);

  // Weight maps on the proxy.
  final n = used.length;
  final weights = List<Float32List>.generate(n, (_) => Float32List(pw * ph));
  var ghosts = 0;
  for (var k = 0; k < n; k++) {
    final lut = k == 0 ? null : comparametricLut(refProxy.l, proxies[k].l);
    final wk = weights[k];
    final lk = proxies[k].l;
    for (var i = 0; i < wk.length; i++) {
      var wv = wellExposedness(lk[i]);
      if (lut != null) {
        final lr = refProxy.l[i];
        final gf = ghostFactor(
          lk[i],
          lut[(lr * 255).round().clamp(0, 255)],
          refClipped: lr < 0.02 || lr > 0.98,
        );
        if (gf < 1) ghosts++;
        wv *= gf;
      }
      wk[i] = wv;
    }
  }
  // v11.48 lighter tone: wide smooth weights (no halos / outlines).
  final blurR = math.max(1, (pw / kHdrBlurDiv).round());
  for (var k = 0; k < n; k++) {
    weights[k] = _boxBlur(weights[k], pw, ph, blurR);
  }
  for (var i = 0; i < pw * ph; i++) {
    var s = 0.0;
    for (var k = 0; k < n; k++) {
      s += weights[k][i];
    }
    if (s <= 0) {
      weights[0][i] = 1;
      continue;
    }
    for (var k = 0; k < n; k++) {
      // v11.48: keep part of the normal frame everywhere → natural look
      // (less contrast / saturation boost than full fusion).
      weights[k][i] = weights[k][i] / s * (1 - kHdrRefShare);
    }
    weights[0][i] += kHdrRefShare;
  }

  // Full-resolution composite (bilinear weights, per-frame shift).
  final bytes = [for (final f in used) f.getBytes(order: img.ChannelOrder.rgb)];
  final out = Uint8List(w * h * 3);
  final wk = Float64List(n);
  for (var y = 0; y < h; y++) {
    final fy = ((y + 0.5) / scale - 0.5).clamp(0.0, ph - 1.0);
    final y0 = fy.floor();
    final y1 = math.min(y0 + 1, ph - 1);
    final ty = fy - y0;
    for (var x = 0; x < w; x++) {
      final fx = ((x + 0.5) / scale - 0.5).clamp(0.0, pw - 1.0);
      final x0 = fx.floor();
      final x1 = math.min(x0 + 1, pw - 1);
      final tx = fx - x0;
      var total = 0.0;
      for (var k = 0; k < n; k++) {
        final m = weights[k];
        final top = m[y0 * pw + x0] * (1 - tx) + m[y0 * pw + x1] * tx;
        final bot = m[y1 * pw + x0] * (1 - tx) + m[y1 * pw + x1] * tx;
        var v = top * (1 - ty) + bot * ty;
        final sx = x + shifts[k].$1;
        final sy = y + shifts[k].$2;
        if (sx < 0 || sy < 0 || sx >= w || sy >= h) v = 0;
        wk[k] = v;
        total += v;
      }
      if (total <= 1e-6) {
        wk[0] = 1;
        for (var k = 1; k < n; k++) {
          wk[k] = 0;
        }
        total = 1;
      }
      var r = 0.0, g = 0.0, b = 0.0;
      for (var k = 0; k < n; k++) {
        final v = wk[k];
        if (v == 0) continue;
        final si = ((y + shifts[k].$2) * w + (x + shifts[k].$1)) * 3;
        final bk = bytes[k];
        r += bk[si] * v;
        g += bk[si + 1] * v;
        b += bk[si + 2] * v;
      }
      final o = (y * w + x) * 3;
      out[o] = (r / total).round().clamp(0, 255);
      out[o + 1] = (g / total).round().clamp(0, 255);
      out[o + 2] = (b / total).round().clamp(0, 255);
    }
  }
  final merged = img.Image.fromBytes(
    width: w,
    height: h,
    bytes: out.buffer,
    numChannels: 3,
  );
  return HdrMerged(merged, n, shifts, ghosts);
}

/// Proxy of frame f aligned to the reference: aligned(x, y) = f(x+dx, y+dy).
_Proxy _shiftProxy(_Proxy pr, int dx, int dy) {
  if (dx == 0 && dy == 0) return pr;
  final l = Float32List(pr.l.length);
  for (var y = 0; y < pr.h; y++) {
    final sy = (y + dy).clamp(0, pr.h - 1);
    for (var x = 0; x < pr.w; x++) {
      final sx = (x + dx).clamp(0, pr.w - 1);
      l[y * pr.w + x] = pr.l[sy * pr.w + sx];
    }
  }
  return _Proxy(pr.w, pr.h, l);
}

class HdrFileResult {
  const HdrFileResult(this.path, this.used, this.shifts, this.ghostPixels);
  final String path;
  final int used;
  final List<(int, int)> shifts;
  final int ghostPixels;
}

class _HdrArgs {
  const _HdrArgs(this.paths, this.outDir);
  final List<String> paths;
  final String outDir;
}

/// Decodes (EXIF baked), merges and writes a JPEG — in a background isolate.
Future<HdrFileResult> mergeHdrFiles(List<String> paths, String outDir) =>
    compute(_mergeFilesSync, _HdrArgs(paths, outDir));

HdrFileResult _mergeFilesSync(_HdrArgs a) {
  final frames = <img.Image>[];
  for (final path in a.paths) {
    final raw = img.decodeImage(File(path).readAsBytesSync());
    if (raw == null) continue;
    frames.add(img.bakeOrientation(raw));
  }
  if (frames.length < 2) {
    return HdrFileResult(a.paths.first, 1, const [(0, 0)], 0);
  }
  final r = mergeHdr(frames);
  final out = p.join(
    a.outDir,
    'hdr_${DateTime.now().millisecondsSinceEpoch}.jpg',
  );
  File(out).writeAsBytesSync(img.encodeJpg(r.image, quality: 95));
  return HdrFileResult(out, r.used, r.shifts, r.ghostPixels);
}
