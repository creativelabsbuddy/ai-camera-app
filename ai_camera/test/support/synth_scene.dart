import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ai_camera/services/image_register.dart';

/// v11.60 tests: a continuous synthetic world (random blobs + bars) that
/// can be "photographed" at any centre / field of view / rotation, so the
/// true transform between two views is known exactly.
class SynthScene {
  SynthScene(int seed, {int blobs = 160}) {
    final r = math.Random(seed);
    _p1 = r.nextDouble() * 6.28;
    _p2 = r.nextDouble() * 6.28;
    for (var i = 0; i < blobs; i++) {
      _b.add((
        r.nextDouble() * 2 - 1,
        r.nextDouble() * 2 - 1,
        0.01 + r.nextDouble() * 0.06,
        (r.nextDouble() * 2 - 1) * 90,
      ));
    }
  }
  final _b = <(double, double, double, double)>[];
  late final double _p1, _p2;

  double at(double x, double y) {
    var v = 110.0 + 25 * math.sin(7 * x + _p1) * math.cos(5 * y + _p2);
    for (final (bx, by, s, a) in _b) {
      final dx = x - bx, dy = y - by;
      final d2 = dx * dx + dy * dy;
      if (d2 > 9 * s * s) continue;
      v += a * math.exp(-d2 / (2 * s * s));
    }
    return v.clamp(0, 255).toDouble();
  }

  /// A w×h view centred at (cx, cy) whose WIDTH spans [fov] world units,
  /// rotated by [angle]. 2×2 supersampled.
  GreyImage view(
    int w,
    int h, {
    double cx = 0,
    double cy = 0,
    double fov = 1,
    double angle = 0,
    double blur = 0,
    double noise = 0,
    int seed = 1,
    int ss = 2,
  }) {
    final d = Float32List(w * h);
    final c = math.cos(angle), s = math.sin(angle);
    final r = math.Random(seed);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var acc = 0.0;
        for (var sy = 0; sy < ss; sy++) {
          for (var sx = 0; sx < ss; sx++) {
            final (u, v) = toNorm(
              x - 0.5 + (sx + 0.5) / ss,
              y - 0.5 + (sy + 0.5) / ss,
              w,
              h,
            );
            final wu = u * fov, wv = v * fov;
            acc += at(cx + c * wu - s * wv, cy + s * wu + c * wv);
          }
        }
        d[y * w + x] = acc / (ss * ss) + (noise > 0 ? _gauss(r) * noise : 0);
      }
    }
    var im = GreyImage(w, h, d);
    for (var i = 0; i < blur; i++) {
      im = boxBlur(im);
    }
    return im;
  }
}

double _gauss(math.Random r) {
  final u1 = math.max(1e-12, r.nextDouble()), u2 = r.nextDouble();
  return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
}

GreyImage boxBlur(GreyImage im) {
  final w = im.width, h = im.height;
  final o = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var s = 0.0;
      var n = 0;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final xx = x + dx, yy = y + dy;
          if (xx < 0 || yy < 0 || xx >= w || yy >= h) continue;
          s += im.data[yy * w + xx];
          n++;
        }
      }
      o[y * w + x] = s / n;
    }
  }
  return GreyImage(w, h, o);
}

/// True transform mapping view A's normalised coords into view B's
/// (views given as (cx, cy, fov, angle)).
Similarity trueMap(
  (double, double, double, double) a,
  (double, double, double, double) b,
) {
  // world = c + R(ang)·fov·p  ⇒  p_b = R(−angB)/fovB · (world − c_b)
  Similarity toWorld((double, double, double, double) v) =>
      Similarity.of(scale: v.$3, angle: v.$4, tx: v.$1, ty: v.$2);
  return toWorld(b).inverse().compose(toWorld(a));
}

/// Grey → tinted packed RGB (all three channels carry the content).
Uint8List toRgb(GreyImage g) {
  final o = Uint8List(g.width * g.height * 3);
  for (var i = 0; i < g.width * g.height; i++) {
    final v = g.data[i];
    o[i * 3] = v.round().clamp(0, 255);
    o[i * 3 + 1] = (v * 0.9 + 12).round().clamp(0, 255);
    o[i * 3 + 2] = (v * 0.8 + 25).round().clamp(0, 255);
  }
  return o;
}

/// NCC of two equal-size grey images.
double ncc(GreyImage a, GreyImage b) {
  var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0;
  final n = a.data.length;
  for (var i = 0; i < n; i++) {
    final x = a.data[i], y = b.data[i];
    sa += x;
    sb += y;
    saa += x * x;
    sbb += y * y;
    sab += x * y;
  }
  final va = saa / n - (sa / n) * (sa / n), vb = sbb / n - (sb / n) * (sb / n);
  return (sab / n - (sa / n) * (sb / n)) / math.sqrt(va * vb);
}

/// RMS difference of two equal-size grey images.
double rms(GreyImage a, GreyImage b) {
  var s = 0.0;
  for (var i = 0; i < a.data.length; i++) {
    final d = a.data[i] - b.data[i];
    s += d * d;
  }
  return math.sqrt(s / a.data.length);
}
