import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ai_camera/services/hdr_merge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Synthetic scene radiance (linear-ish, 1.0 = white at 0 EV):
/// left third dark (0.05), middle textured mid-grey, right third a bright
/// "sky" with texture that clips at 0 EV.
double radiance(int x, int y, int w) {
  // A non-periodic feature (bright disc) so alignment is unambiguous.
  if ((x - 30) * (x - 30) + (y - 22) * (y - 22) < 36) return 0.9;
  if (y > 50 && x > 40 && x < 60 && x - 40 < y - 50) return 0.15;
  if (x < w ~/ 3) {
    return 0.03 + 0.06 * y / 64 + 0.01 * ((x * 7 + y * 3) % 5) / 5;
  }
  if (x < 2 * w ~/ 3) return 0.45 + ((x ~/ 3).isEven ? 0.1 : 0.0);
  return ((x ~/ 4 + y ~/ 4).isEven ? 1.5 : 2.0);
}

img.Image shoot(
  double ev, {
  int w = 96,
  int h = 64,
  int dx = 0,
  int dy = 0,
  void Function(img.Image)? edit,
}) {
  final im = img.Image(width: w, height: h);
  final gain = math.pow(2, ev).toDouble();
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      // Frame shifted by (dx, dy): content at (x, y) comes from (x-dx, y-dy).
      final sx = (x - dx).clamp(0, w - 1);
      final sy = (y - dy).clamp(0, h - 1);
      final v = (radiance(sx, sy, w) * gain * 200).round().clamp(0, 255);
      im.setPixelRgb(x, y, v, v, v);
    }
  }
  edit?.call(im);
  return im;
}

double meanRegion(img.Image im, int x0, int x1, int y0, int y1) {
  var s = 0.0;
  var n = 0;
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      s += im.getPixel(x, y).r;
      n++;
    }
  }
  return s / n;
}

double contrastRegion(img.Image im, int x0, int x1, int y0, int y1) {
  var lo = 255.0, hi = 0.0;
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      final v = im.getPixel(x, y).r.toDouble();
      lo = math.min(lo, v);
      hi = math.max(hi, v);
    }
  }
  return hi - lo;
}

void main() {
  group('bracket plan', () {
    test('±2 EV when the camera allows, reference first', () {
      expect(hdrBracketEv(minEv: -4, maxEv: 4), [0, -2.0, 2.0]);
    });
    test('narrow range → smaller step on 1/3 EV grid', () {
      final b = hdrBracketEv(minEv: -1.5, maxEv: 1.5);
      expect(b.first, 0);
      expect(b[2], closeTo(1.0, 1e-9));
      expect(b[1], -b[2]);
    });
    test('no exposure compensation → no HDR bracket', () {
      expect(hdrBracketEv(minEv: 0, maxEv: 0), isEmpty);
      expect(hdrBracketEv(minEv: -0.5, maxEv: 0.5), isEmpty);
      expect(hdrBracketEv(minEv: double.nan, maxEv: 2), isEmpty);
    });
  });

  group('weights', () {
    test('well-exposedness peaks at mid-grey, tiny at clipping', () {
      expect(wellExposedness(0.5), closeTo(1.001, 1e-6));
      expect(wellExposedness(0.0), lessThan(0.05));
      expect(wellExposedness(1.0), lessThan(0.05));
      expect(wellExposedness(0.3), greaterThan(wellExposedness(0.1)));
    });
    test('ghost factor: far from the predicted value → rejected', () {
      expect(ghostFactor(0.8, 0.82), 1);
      expect(ghostFactor(0.3, 0.8), lessThan(0.1)); // moved
      expect(ghostFactor(0.3, 0.8, refClipped: true), 1); // can't judge
    });

    test('comparametric LUT follows the exposure gain and is monotonic', () {
      final ref = shoot(0), over = shoot(1);
      Float32List luma(img.Image im) =>
          Float32List.fromList([for (final px in im) px.r / 255.0]);
      final lut = comparametricLut(luma(ref), luma(over));
      for (var i = 1; i < 256; i++) {
        expect(lut[i], greaterThanOrEqualTo(lut[i - 1]));
      }
      // Mid-grey 90/255 at 0 EV ≈ 180/255 at +1 EV.
      expect(lut[90] * 255, closeTo(180, 12));
    });
  });

  group('mergeHdr', () {
    test('recovers clipped highlights and lifts shadows', () {
      final ref = shoot(0);
      final under = shoot(-2);
      final over = shoot(2);
      final r = mergeHdr([ref, under, over], proxyWidth: 48);
      expect(r.used, 3);
      const y0 = 8, y1 = 56;
      // Sky clips at 0 EV (texture lost) …
      expect(contrastRegion(ref, 70, 90, y0, y1), lessThan(2));
      // … but the merge keeps the sky texture from the under frame.
      expect(contrastRegion(r.image, 70, 90, y0, y1), greaterThan(12));
      expect(meanRegion(r.image, 70, 90, y0, y1), lessThan(250));
      // Shadows are brighter than the reference.
      expect(
        meanRegion(r.image, 4, 28, y0, y1),
        greaterThan(meanRegion(ref, 4, 28, y0, y1) + 8),
      );
    });

    test('aligns a shifted frame (global shift)', () {
      final ref = shoot(0);
      final over = shoot(2, dx: 3, dy: 2);
      final under = shoot(-2, dx: -2, dy: 1);
      final r = mergeHdr([ref, under, over], proxyWidth: 32, refineWidth: 96);
      expect(r.used, 3);
      expect(r.shifts[0], (0, 0));
      expect(r.shifts[1], (-2, 1));
      expect(r.shifts[2], (3, 2));
    });

    test('ghosting: a moving object in one frame is suppressed', () {
      final ref = shoot(0);
      final under = shoot(-2);
      // Someone walked through the middle (mid-tones) in the +2 frame.
      final over = shoot(
        2,
        edit: (im) {
          for (var y = 20; y < 44; y++) {
            for (var x = 40; x < 56; x++) {
              im.setPixelRgb(x, y, 10, 10, 10);
            }
          }
        },
      );
      final noGhost = mergeHdr([ref, under, shoot(2)], proxyWidth: 96);
      final r = mergeHdr([ref, under, over], proxyWidth: 32, refineWidth: 96);
      expect(r.ghostPixels, greaterThan(0));
      final a = meanRegion(r.image, 44, 52, 26, 38);
      final b = meanRegion(noGhost.image, 44, 52, 26, 38);
      expect((a - b).abs(), lessThan(25), reason: 'ghost mostly rejected');
    });

    test('identical frames → output equals input', () {
      final ref = shoot(0);
      final r = mergeHdr([ref, ref.clone(), ref.clone()], proxyWidth: 48);
      expect(
        meanRegion(r.image, 30, 60, 10, 50),
        closeTo(meanRegion(ref, 30, 60, 10, 50), 1.0),
      );
    });

    test('mismatched frame sizes are skipped', () {
      final r = mergeHdr([shoot(0), shoot(-2, w: 50)], proxyWidth: 48);
      expect(r.used, 1);
    });
  });
}
