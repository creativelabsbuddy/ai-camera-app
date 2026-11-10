import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// v11.5: colour match of an AI macro result to its source crop (same as the
/// server's color_match.py): luma mean + chroma (Cb/Cr) mean and spread in
/// YCbCr, so hue / white balance follow the real photo while the AI's fine
/// detail and local contrast stay.
Future<Uint8List> matchColors(Uint8List out, Uint8List source) =>
    Isolate.run(() => matchColorsSync(out, source));

class _Ycc {
  _Ycc(this.mean, this.std);
  final List<double> mean;
  final List<double> std;
}

List<double> _toYcc(num r, num g, num b) => [
  0.299 * r + 0.587 * g + 0.114 * b,
  128 - 0.168736 * r - 0.331264 * g + 0.5 * b,
  128 + 0.5 * r - 0.418688 * g - 0.081312 * b,
];

_Ycc _stats(img.Image im) {
  final small = im.width > 256 || im.height > 256
      ? img.copyResize(
          im,
          width: im.width >= im.height ? 256 : null,
          height: im.height > im.width ? 256 : null,
        )
      : im;
  final s = [0.0, 0.0, 0.0], s2 = [0.0, 0.0, 0.0];
  var n = 0;
  for (final p in small) {
    final y = _toYcc(p.r, p.g, p.b);
    for (var i = 0; i < 3; i++) {
      s[i] += y[i];
      s2[i] += y[i] * y[i];
    }
    n++;
  }
  if (n == 0) return _Ycc([0, 128, 128], [1, 1, 1]);
  final mean = [for (var i = 0; i < 3; i++) s[i] / n];
  final std = [
    for (var i = 0; i < 3; i++)
      math.sqrt(math.max(0, s2[i] / n - mean[i] * mean[i])),
  ];
  return _Ycc(mean, std);
}

/// v11.7 regional chroma grid (same as the server's REGION_GRID).
const int kRegionGrid = 8;

/// Grid-averaged chroma (Cb, Cr) of an image: [2][grid*grid].
List<List<double>> _chromaGrid(img.Image im) {
  final g = kRegionGrid;
  final sum = [List<double>.filled(g * g, 0), List<double>.filled(g * g, 0)];
  final n = List<int>.filled(g * g, 0);
  final step = math.max(1, math.min(im.width, im.height) ~/ 128);
  for (var y = 0; y < im.height; y += step) {
    final gy = (y * g ~/ im.height).clamp(0, g - 1);
    for (var x = 0; x < im.width; x += step) {
      final gx = (x * g ~/ im.width).clamp(0, g - 1);
      final p = im.getPixel(x, y);
      final c = _toYcc(p.r, p.g, p.b);
      final i = gy * g + gx;
      sum[0][i] += c[1];
      sum[1][i] += c[2];
      n[i]++;
    }
  }
  for (var i = 0; i < g * g; i++) {
    final k = math.max(1, n[i]);
    sum[0][i] /= k;
    sum[1][i] /= k;
  }
  return sum;
}

/// Bilinear sample of a grid at normalised (u, v) (cell centres).
double _sample(List<double> grid, double u, double v) {
  final g = kRegionGrid;
  final fx = (u * g - 0.5).clamp(0.0, g - 1.0);
  final fy = (v * g - 0.5).clamp(0.0, g - 1.0);
  final x0 = fx.floor(), y0 = fy.floor();
  final x1 = math.min(g - 1, x0 + 1), y1 = math.min(g - 1, y0 + 1);
  final tx = fx - x0, ty = fy - y0;
  final a = grid[y0 * g + x0] * (1 - tx) + grid[y0 * g + x1] * tx;
  final b = grid[y1 * g + x0] * (1 - tx) + grid[y1 * g + x1] * tx;
  return a * (1 - ty) + b * ty;
}

/// v11.42: max overall (global) shift of Y / Cb / Cr means (0..255).
const double kGlobalMaxShift = 10;

/// v11.42: average Cb/Cr difference above this → skip the colour match.
const double kColorSkipDiff = 12;

/// Skip the colour match when the result's average colour differs a lot
/// from the original's (means are [Y, Cb, Cr]). Pure.
bool colorMatchSkip(List<double> outMean, List<double> srcMean) =>
    ((outMean[1] - srcMean[1]).abs() + (outMean[2] - srcMean[2]).abs()) / 2 >
    kColorSkipDiff;

/// v11.41: max regional chroma shift per area (0..255), same as the server.
const double kRegionMaxShift = 10;

/// Pure → unit tested. Returns JPEG bytes.
///
/// 1. global: luma mean + chroma mean/spread follow the source;
/// 2. regional (v11.7): the low-frequency chroma (8×8 grid, bilinear) is
///    replaced by the source crop's, so a golden patch on uniform silver
///    goes back to silver while fine detail stays.
Uint8List matchColorsSync(Uint8List outBytes, Uint8List sourceBytes) {
  final out = img.decodeImage(outBytes);
  final src = img.decodeImage(sourceBytes);
  if (out == null || src == null) return outBytes;
  final so = _stats(out), ss0 = _stats(src);
  // v11.42: result colours far from the original (the AI changed what is in
  // the frame) → no colour match at all; else the overall shift is capped.
  if (colorMatchSkip(so.mean, ss0.mean)) return outBytes;
  final ss = _Ycc([
    for (var i = 0; i < 3; i++)
      so.mean[i] +
          (ss0.mean[i] - so.mean[i]).clamp(-kGlobalMaxShift, kGlobalMaxShift),
  ], ss0.std);
  double gain(int i) {
    if (so.std[i] < 1e-3) return 1;
    // v11.39: never AMPLIFY chroma spread (it turned fine AI texture /
    // noise into coloured RGB dots on skin, hair and paper).
    return (ss.std[i] / so.std[i]).clamp(0.6, 1.0).toDouble();
  }

  final gCb = gain(1), gCr = gain(2);
  // Global pass first (into a buffer of Ycc), then regional chroma.
  final w = out.width, h = out.height;
  final yb = Float32List(w * h),
      cbb = Float32List(w * h),
      crb = Float32List(w * h);
  for (final p in out) {
    final c = _toYcc(p.r, p.g, p.b);
    final i = p.y * w + p.x;
    yb[i] = c[0] - so.mean[0] + ss.mean[0];
    cbb[i] = (c[1] - so.mean[1]) * gCb + ss.mean[1];
    crb[i] = (c[2] - so.mean[2]) * gCr + ss.mean[2];
  }
  // Low-frequency chroma of the globally matched output vs the source.
  final g = kRegionGrid;
  final og = [List<double>.filled(g * g, 0), List<double>.filled(g * g, 0)];
  final on = List<int>.filled(g * g, 0);
  for (var y = 0; y < h; y++) {
    final gy = (y * g ~/ h).clamp(0, g - 1);
    for (var x = 0; x < w; x++) {
      final k = gy * g + (x * g ~/ w).clamp(0, g - 1);
      og[0][k] += cbb[y * w + x];
      og[1][k] += crb[y * w + x];
      on[k]++;
    }
  }
  for (var k = 0; k < g * g; k++) {
    og[0][k] /= math.max(1, on[k]);
    og[1][k] /= math.max(1, on[k]);
  }
  final sg = _chromaGrid(src);
  for (final p in out) {
    final i = p.y * w + p.x;
    final u = (p.x + 0.5) / w, v = (p.y + 0.5) / h;
    final y = yb[i];
    // v11.41: the regional shift is capped so a strong background colour
    // in a grid cell can't tint a small subject inside it.
    final dCb = (_sample(sg[0], u, v) - _sample(og[0], u, v)).clamp(
      -kRegionMaxShift,
      kRegionMaxShift,
    );
    final dCr = (_sample(sg[1], u, v) - _sample(og[1], u, v)).clamp(
      -kRegionMaxShift,
      kRegionMaxShift,
    );
    final cb = cbb[i] + dCb - 128;
    final cr = crb[i] + dCr - 128;
    p
      ..r = (y + 1.402 * cr).round().clamp(0, 255)
      ..g = (y - 0.344136 * cb - 0.714136 * cr).round().clamp(0, 255)
      ..b = (y + 1.772 * cb).round().clamp(0, 255);
  }
  return Uint8List.fromList(img.encodeJpg(out, quality: 94));
}

/// Max spread (0..255) of 4×4-grid-averaged chroma — 0 for uniform colour.
double regionalChromaSpread(Uint8List bytes) {
  final im = img.decodeImage(bytes)!;
  final small = img.copyResize(
    im,
    width: 4,
    height: 4,
    interpolation: img.Interpolation.average,
  );
  var worst = 0.0;
  for (var ch = 1; ch <= 2; ch++) {
    var lo = 1e9, hi = -1e9;
    for (final p in small) {
      final c = _toYcc(p.r, p.g, p.b)[ch];
      lo = math.min(lo, c);
      hi = math.max(hi, c);
    }
    worst = math.max(worst, hi - lo);
  }
  return worst;
}

/// Mean Cb/Cr difference (0..255) between two images (tests).
double chromaDistance(Uint8List a, Uint8List b) {
  final x = _stats(img.decodeImage(a)!), y = _stats(img.decodeImage(b)!);
  return ((x.mean[1] - y.mean[1]).abs() + (x.mean[2] - y.mean[2]).abs()) / 2;
}

/// v11.39 Macro / Microscope input clean-up: phone crops at the optical
/// limit carry strong colour (chroma) noise, which the image model turned
/// into coloured dots. Luma (detail) is untouched; only Cb/Cr are smoothed
/// (two 3x3 box passes). Long side capped at [maxLong]. Returns JPEG bytes.
Future<Uint8List> softenChroma(Uint8List bytes, {int maxLong = 1536}) =>
    Isolate.run(() => softenChromaSync(bytes, maxLong: maxLong));

Uint8List softenChromaSync(Uint8List bytes, {int maxLong = 1536}) {
  var im = img.decodeImage(bytes);
  if (im == null) return bytes;
  im = img.bakeOrientation(im);
  if (math.max(im.width, im.height) > maxLong) {
    im = img.copyResize(
      im,
      width: im.width >= im.height ? maxLong : null,
      height: im.height > im.width ? maxLong : null,
      interpolation: img.Interpolation.average,
    );
  }
  final w = im.width, h = im.height;
  final yb = Float32List(w * h),
      cb = Float32List(w * h),
      cr = Float32List(w * h);
  for (final p in im) {
    final c = _toYcc(p.r, p.g, p.b);
    final i = p.y * w + p.x;
    yb[i] = c[0];
    cb[i] = c[1];
    cr[i] = c[2];
  }
  Float32List box(Float32List a) {
    final o = Float32List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var s = 0.0;
        var n = 0;
        for (var dy = -1; dy <= 1; dy++) {
          final yy = y + dy;
          if (yy < 0 || yy >= h) continue;
          for (var dx = -1; dx <= 1; dx++) {
            final xx = x + dx;
            if (xx < 0 || xx >= w) continue;
            s += a[yy * w + xx];
            n++;
          }
        }
        o[y * w + x] = s / n;
      }
    }
    return o;
  }

  final cb2 = box(box(cb)), cr2 = box(box(cr));
  for (final p in im) {
    final i = p.y * w + p.x;
    final y = yb[i], u = cb2[i] - 128, v = cr2[i] - 128;
    p
      ..r = (y + 1.402 * v).round().clamp(0, 255)
      ..g = (y - 0.344136 * u - 0.714136 * v).round().clamp(0, 255)
      ..b = (y + 1.772 * u).round().clamp(0, 255);
  }
  return Uint8List.fromList(img.encodeJpg(im, quality: 95));
}
