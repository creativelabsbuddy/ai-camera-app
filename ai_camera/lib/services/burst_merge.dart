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
/// • a mild, halo-clamped sharpen only when ≥ 2 frames really merged.
/// Fewer than 2 usable frames → the sharpest frame alone.

/// Burst bounds (cheap phones: sequential full-res takePicture calls).
const int kBurstMinFrames = 2;
const int kBurstMaxFrames = 4;

/// Capture time budget for the whole burst, and a single slow capture
/// that ends it (the phone is too slow for more).
const int kBurstBudgetMs = 1800;
const int kBurstSlowCaptureMs = 700;

/// Merge only regions up to this many pixels (memory / time on weak
/// phones); larger regions → single shot.
const int kBurstMaxRegionPixels = 3000000;

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

/// Per-pixel weight: 1 up to [kBurstPixLow]σ, 0 from [kBurstPixHigh]σ.
const double kBurstPixLow = 2.5;
const double kBurstPixHigh = 5.0;

/// Mild sharpen amount after a real merge (halo-clamped).
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

/// Should this zoom shot use the burst? Small zoomed region (digital crop
/// on top of the camera's zoom) and a plain single photo. Pure.
bool shouldBurstZoom({
  required bool lowEnd,
  required double digital,
  required int regionPixels,
  required bool plainPhoto,
}) =>
    lowEnd &&
    plainPhoto &&
    digital > 1.2 &&
    regionPixels > 0 &&
    regionPixels <= kBurstMaxRegionPixels;

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
    required this.image,
    required this.used,
    required this.anchor,
    required this.notes,
    required this.sigma,
    required this.ghostTiles,
    this.timedOut = false,
  });
  final RgbFrame image;
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

/// Full-res affine (anchor px → frame px) from a proxy-space similarity.
List<double> _fullAffine(Similarity t, int pw, int ph, int k) {
  (double, double) map(double X, double Y) {
    final px = (X + 0.5) / k - 0.5, py = (Y + 0.5) / k - 0.5;
    final (u, v) = toNorm(px, py, pw, ph);
    final (u2, v2) = t.apply(u, v);
    final (qx, qy) = toPixel(u2, v2, pw, ph);
    return ((qx + 0.5) * k - 0.5, (qy + 0.5) * k - 0.5);
  }

  final (ox, oy) = map(0, 0);
  final (xx, xy) = map(1, 0);
  final (yx, yy) = map(0, 1);
  return [xx - ox, yx - ox, ox, xy - oy, yy - oy, oy];
}

/// The merge (pure; tests call it directly). [inner] = the output region
/// (x, y, w, h) inside every frame (the rest is alignment margin).
BurstMergeResult mergeBurst(
  List<RgbFrame> frames, {
  required (int, int, int, int) inner,
  int budgetMs = kBurstMergeBudgetMs,
}) {
  final sw = Stopwatch()..start();
  final (ix, iy, iw, ih) = inner;
  final proxies = <(GreyImage, int)>[for (final f in frames) burstProxy(f)];
  // Sharpness at half proxy resolution (pixel noise does not pose as
  // detail).
  final sharp = <double>[
    for (final p in proxies) p.$1.half().laplacianVariance(),
  ];
  var anchor = 0;
  for (var i = 1; i < frames.length; i++) {
    if (sharp[i] > sharp[anchor]) anchor = i;
  }
  final a = frames[anchor];
  final (ap, ak) = proxies[anchor];
  final aMean = ap.mean();
  // Tile verdicts at half proxy resolution (noise σ halves).
  final apHalf = ap.half();
  final notes = List<BurstFrameNote?>.filled(frames.length, null);
  notes[anchor] = BurstFrameNote(anchor, sharp[anchor], 1, 'anchor');
  final affines = <int, List<double>>{};
  for (var i = 0; i < frames.length; i++) {
    if (i == anchor) continue;
    final f = frames[i];
    final (fp, _) = proxies[i];
    if (f.width != a.width || f.height != a.height) {
      notes[i] = BurstFrameNote(i, sharp[i], -1, 'size');
      continue;
    }
    final ratio = aMean <= 1 ? 1.0 : fp.mean() / aMean;
    if ((ratio - 1).abs() > kBurstExposureTol) {
      notes[i] = BurstFrameNote(i, sharp[i], -1, 'exposure');
      continue;
    }
    final r = registerSimilarity(
      ap,
      fp,
      scaleFactors: const [0.98, 1.0, 1.02],
      radius: 3,
      iterations: 5,
    );
    // Robust verdict: median tile NCC (a local mover does not reject the
    // whole frame — its tiles are handled by the ghost test below).
    final robust = r.score <= -1
        ? -1.0
        : tileMedianNcc(apHalf, fp.half(), r.transform);
    if (robust < kBurstMinScore || r.transform.angle.abs() > 0.05) {
      notes[i] = BurstFrameNote(i, sharp[i], robust, 'unaligned');
      continue;
    }
    affines[i] = _fullAffine(r.transform, ap.width, ap.height, ak);
    notes[i] = BurstFrameNote(i, sharp[i], robust, 'merged');
  }
  final sigma = estimateNoise(a);
  final out = Uint8List(iw * ih * 3);
  // Anchor-only copy first (fallback + base).
  for (var y = 0; y < ih; y++) {
    final src = ((iy + y) * a.width + ix) * 3;
    out.setRange(y * iw * 3, (y + 1) * iw * 3, a.rgb, src);
  }
  if (affines.isEmpty) {
    return BurstMergeResult(
      image: RgbFrame(iw, ih, out),
      used: 1,
      anchor: anchor,
      notes: notes.cast<BurstFrameNote>(),
      sigma: sigma,
      ghostTiles: 0,
    );
  }
  final acc = Float32List(iw * ih * 3);
  final wsum = Float32List(iw * ih);
  for (var j = 0; j < iw * ih; j++) {
    wsum[j] = 1;
  }
  for (var y = 0; y < ih; y++) {
    for (var x = 0; x < iw; x++) {
      final s = ((iy + y) * a.width + ix + x) * 3, d = (y * iw + x) * 3;
      acc[d] = a.rgb[s].toDouble();
      acc[d + 1] = a.rgb[s + 1].toDouble();
      acc[d + 2] = a.rgb[s + 2].toDouble();
    }
  }
  final usedFrames = <int>{anchor};
  var tilesTotal = 0, tilesGhost = 0;
  final lo = kBurstPixLow * sigma, hi = kBurstPixHigh * sigma;
  final ghostTol = kBurstGhostSigma * sigma + 1.0;
  var timedOut = false;
  final px = Float32List(3);
  for (final e in affines.entries) {
    if (sw.elapsedMilliseconds > budgetMs) {
      timedOut = true;
      break;
    }
    final f = frames[e.key];
    final m = e.value;
    var anyUsed = false;
    bool warp(int x, int y) {
      final X = (ix + x).toDouble(), Y = (iy + y).toDouble();
      final sx = m[0] * X + m[1] * Y + m[2], sy = m[3] * X + m[4] * Y + m[5];
      if (sx < 0 || sy < 0 || sx > f.width - 1 || sy > f.height - 1) {
        return false;
      }
      final x0 = sx.floor(), y0 = sy.floor();
      final x1 = math.min(x0 + 1, f.width - 1),
          y1 = math.min(y0 + 1, f.height - 1);
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

    for (var ty = 0; ty < ih; ty += kBurstTile) {
      for (var tx = 0; tx < iw; tx += kBurstTile) {
        final tw = math.min(kBurstTile, iw - tx),
            th = math.min(kBurstTile, ih - ty);
        // Tile ghost test (moving subject / parallax): mean |Δluma|.
        var diff = 0.0;
        var n = 0;
        var outside = false;
        for (var y = ty; y < ty + th && !outside; y += 2) {
          for (var x = tx; x < tx + tw; x += 2) {
            if (!warp(x, y)) {
              outside = true;
              break;
            }
            final d = (y * iw + x) * 3;
            final la = 0.299 * out[d] + 0.587 * out[d + 1] + 0.114 * out[d + 2];
            final lf = 0.299 * px[0] + 0.587 * px[1] + 0.114 * px[2];
            diff += (lf - la).abs();
            n++;
          }
        }
        tilesTotal++;
        if (outside || n == 0 || diff / n > ghostTol) {
          tilesGhost++;
          continue;
        }
        for (var y = ty; y < ty + th; y++) {
          for (var x = tx; x < tx + tw; x++) {
            if (!warp(x, y)) continue;
            final j = y * iw + x, d = j * 3;
            final la = 0.299 * out[d] + 0.587 * out[d + 1] + 0.114 * out[d + 2];
            final lf = 0.299 * px[0] + 0.587 * px[1] + 0.114 * px[2];
            final dd = (lf - la).abs();
            final w = dd <= lo ? 1.0 : (dd >= hi ? 0.0 : (hi - dd) / (hi - lo));
            if (w <= 0) continue;
            acc[d] += w * px[0];
            acc[d + 1] += w * px[1];
            acc[d + 2] += w * px[2];
            wsum[j] += w;
            anyUsed = true;
          }
        }
      }
    }
    if (anyUsed) {
      usedFrames.add(e.key);
    } else {
      notes[e.key] = BurstFrameNote(
        e.key,
        sharp[e.key],
        notes[e.key]!.score,
        'ghost',
      );
    }
  }
  if (usedFrames.length < 2) {
    return BurstMergeResult(
      image: RgbFrame(iw, ih, out),
      used: 1,
      anchor: anchor,
      notes: notes.cast<BurstFrameNote>(),
      sigma: sigma,
      ghostTiles: tilesTotal == 0 ? 0 : tilesGhost / tilesTotal,
      timedOut: timedOut,
    );
  }
  // Normalise in place (no second full-size float buffer).
  for (var j = 0; j < iw * ih; j++) {
    final ws = wsum[j];
    acc[j * 3] /= ws;
    acc[j * 3 + 1] /= ws;
    acc[j * 3 + 2] /= ws;
  }
  _sharpenClamped(acc, iw, ih, out, kBurstSharpen);
  for (final n in notes) {
    if (n != null && n.status == 'merged' && !usedFrames.contains(n.index)) {
      notes[n.index] = BurstFrameNote(n.index, n.sharpness, n.score, 'ghost');
    }
  }
  return BurstMergeResult(
    image: RgbFrame(iw, ih, out),
    used: usedFrames.length,
    anchor: anchor,
    notes: notes.cast<BurstFrameNote>(),
    sigma: sigma,
    ghostTiles: tilesTotal == 0 ? 0 : tilesGhost / tilesTotal,
    timedOut: timedOut,
  );
}

/// Unsharp mask (3×3 box) whose result is clamped to the 3×3 min/max of
/// the merged image (no overshoot → no halos). Writes bytes into [out].
void _sharpenClamped(Float32List m, int w, int h, Uint8List out, double k) {
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
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

/// Decodes the upright pixel rect of [path] into a packed RGB file.
/// Returns (rgbPath, width, height).
Future<(String, int, int)> decodeRegion(
  String path,
  (int, int, int, int) rect,
  String outPath,
) async {
  final (x, y, w, h) = rect;
  try {
    final r = await _region.invokeMapMethod<String, Object?>('decode', {
      'path': path,
      'x': x,
      'y': y,
      'w': w,
      'h': h,
      'out': outPath,
    });
    if (r != null) return (outPath, r['width'] as int, r['height'] as int);
  } catch (_) {}
  return Isolate.run(() {
    final raw = img.decodeImage(File(path).readAsBytesSync());
    if (raw == null) throw const FormatException('undecodable');
    final u = img.bakeOrientation(raw);
    final c = img.copyCrop(u, x: x, y: y, width: w, height: h);
    File(
      outPath,
    ).writeAsBytesSync(c.getBytes(order: img.ChannelOrder.rgb), flush: true);
    return (outPath, c.width, c.height);
  });
}

/// Cancellable background merge: kill() stops the isolate at once.
class BurstJob {
  BurstJob._(this._iso, this.result);
  final Isolate _iso;
  final Future<BurstMergeResult?> result;
  void cancel() => _iso.kill(priority: Isolate.immediate);

  /// Merges the RGB region files and writes the JPEG [outJpeg].
  static Future<BurstJob> start({
    required List<(String, int, int)> frames,
    required (int, int, int, int) inner,
    required String outJpeg,
  }) async {
    final port = ReceivePort();
    final done = Completer<BurstMergeResult?>();
    final iso = await Isolate.spawn(
      _entry,
      (port.sendPort, frames, inner, outJpeg),
      onExit: port.sendPort,
      errorsAreFatal: true,
    );
    port.listen((m) {
      if (!done.isCompleted) done.complete(m is BurstMergeResult ? m : null);
      port.close();
    });
    return BurstJob._(iso, done.future);
  }

  static void _entry(
    (SendPort, List<(String, int, int)>, (int, int, int, int), String) a,
  ) {
    final (send, files, inner, outJpeg) = a;
    try {
      final fr = <RgbFrame>[
        for (final (p, w, h) in files)
          RgbFrame(w, h, File(p).readAsBytesSync()),
      ];
      final r = mergeBurst(fr, inner: inner);
      final im = img.Image.fromBytes(
        width: r.image.width,
        height: r.image.height,
        bytes: r.image.rgb.buffer,
        numChannels: 3,
      );
      File(
        outJpeg,
      ).writeAsBytesSync(img.encodeJpg(im, quality: 95), flush: true);
      send.send(r);
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
