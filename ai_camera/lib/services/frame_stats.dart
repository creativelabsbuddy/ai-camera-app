import 'dart:math' as math;
import 'dart:typed_data';

/// v11 cheap per-frame statistics from the NV21 analysis stream (no ML):
/// * [luma] mean brightness 0..1 (Night planning / Flash Auto),
/// * [sharpness] centre Laplacian variance (Macro distance guide, sharpest
///   frame), [detail] centre mean gradient,
/// * [thumb] tiny upright RGBA thumbnail (freeze frame while the camera is
///   handed over to a native session / the document scanner).
class FrameStats {
  const FrameStats({
    required this.luma,
    required this.sharpness,
    required this.detail,
    this.edgeSharpness = 0,
    this.thumb,
    this.thumbWidth = 0,
    this.thumbHeight = 0,
    this.cropLuma,
    this.cropZoom = 1,
  });

  /// v11.35 upright GREY (1 byte/px) [kThumbW]×[kThumbH] sample of the
  /// visible crop (centre 1/[cropZoom] of the camera frame).
  final Uint8List? cropLuma;
  final double cropZoom;

  final double luma;
  final double sharpness;
  final double detail;

  /// Laplacian variance of the outer border (depth-of-field cue: a close
  /// macro subject has a sharp centre and a blurred surround).
  final double edgeSharpness;
  final Uint8List? thumb;
  final int thumbWidth;
  final int thumbHeight;

  static const empty = FrameStats(luma: 0.5, sharpness: 0, detail: 0);
}

/// Thumbnail size (upright, portrait 3:4).
const kThumbW = 48;
const kThumbH = 64;

/// Computes [FrameStats] from an NV21 buffer (Y plane then interleaved VU).
/// [rotation] = sensor orientation (clockwise degrees to upright).
FrameStats frameStatsFromNv21(
  Uint8List nv21,
  int width,
  int height, {
  int bytesPerRow = 0,
  int rotation = 90,
  bool thumb = true,
  double cropZoom = 1,
}) {
  final stride = bytesPerRow > 0 ? bytesPerRow : width;
  if (width <= 0 || height <= 0 || nv21.length < stride * height) {
    return FrameStats.empty;
  }
  // Mean luma on a 64×48 grid.
  var sum = 0;
  var n = 0;
  for (var gy = 0; gy < 48; gy++) {
    final y = (gy * height) ~/ 48;
    for (var gx = 0; gx < 64; gx++) {
      final x = (gx * width) ~/ 64;
      sum += nv21[y * stride + x];
      n++;
    }
  }
  final luma = n == 0 ? 0.5 : sum / n / 255.0;

  int px(int x, int y) => nv21[y * stride + x];
  final (sharp, detail) = centreSharpness(px, width, height);
  final edge = borderSharpness(px, width, height);

  Uint8List? t;
  if (thumb) {
    t = _thumb(nv21, width, height, stride, rotation);
  }
  final cz = cropZoom.isFinite && cropZoom >= 1 ? cropZoom : 1.0;
  final cl = thumb
      ? _cropLuma(nv21, width, height, stride, rotation, cz)
      : null;
  return FrameStats(
    cropLuma: cl,
    cropZoom: cz,
    luma: luma,
    sharpness: sharp,
    detail: detail,
    edgeSharpness: edge,
    thumb: t,
    thumbWidth: t == null ? 0 : kThumbW,
    thumbHeight: t == null ? 0 : kThumbH,
  );
}

/// Laplacian variance + mean |gradient| over the centre 40 % (step 2).
/// Higher = sharper / more in-focus texture. Pure → unit tested.
(double, double) centreSharpness(
  int Function(int x, int y) px,
  int width,
  int height,
) {
  final x0 = (width * 0.3).round(), x1 = (width * 0.7).round();
  final y0 = (height * 0.3).round(), y1 = (height * 0.7).round();
  final step = math.max(1, (x1 - x0) ~/ 120);
  var s = 0.0, s2 = 0.0, g = 0.0;
  var n = 0;
  for (var y = math.max(1, y0); y < math.min(height - 1, y1); y += step) {
    for (var x = math.max(1, x0); x < math.min(width - 1, x1); x += step) {
      final c = px(x, y);
      final lap =
          (px(x - 1, y) + px(x + 1, y) + px(x, y - 1) + px(x, y + 1) - 4 * c)
              .toDouble();
      s += lap;
      s2 += lap * lap;
      g += (px(x + 1, y) - c).abs() + (px(x, y + 1) - c).abs();
      n++;
    }
  }
  if (n == 0) return (0, 0);
  final mean = s / n;
  return (s2 / n - mean * mean, g / n / 2);
}

/// Laplacian variance over the outer 15 % border ring (step ~w/80).
double borderSharpness(int Function(int x, int y) px, int width, int height) {
  final bx = (width * 0.15).round(), by = (height * 0.15).round();
  final step = math.max(1, width ~/ 80);
  var s = 0.0, s2 = 0.0;
  var n = 0;
  for (var y = 1; y < height - 1; y += step) {
    for (var x = 1; x < width - 1; x += step) {
      final inner = x > bx && x < width - bx && y > by && y < height - by;
      if (inner) continue;
      final c = px(x, y);
      final lap =
          (px(x - 1, y) + px(x + 1, y) + px(x, y - 1) + px(x, y + 1) - 4 * c)
              .toDouble();
      s += lap;
      s2 += lap * lap;
      n++;
    }
  }
  if (n == 0) return 0;
  final mean = s / n;
  return s2 / n - mean * mean;
}

Uint8List _thumb(Uint8List nv21, int w, int h, int stride, int rotation) {
  final out = Uint8List(kThumbW * kThumbH * 4);
  final uvBase = stride * h;
  final rot = ((rotation % 360) + 360) % 360;
  for (var ty = 0; ty < kThumbH; ty++) {
    for (var tx = 0; tx < kThumbW; tx++) {
      // Upright (tx, ty) → sensor (sx, sy).
      final u = (tx + 0.5) / kThumbW, v = (ty + 0.5) / kThumbH;
      double fx, fy;
      switch (rot) {
        case 90:
          fx = v;
          fy = 1 - u;
        case 180:
          fx = 1 - u;
          fy = 1 - v;
        case 270:
          fx = 1 - v;
          fy = u;
        default:
          fx = u;
          fy = v;
      }
      final sx = (fx * (w - 1)).round(), sy = (fy * (h - 1)).round();
      final yv = nv21[sy * stride + sx].toDouble();
      final ci = uvBase + (sy ~/ 2) * stride + (sx & ~1);
      final vv = ci + 1 < nv21.length ? nv21[ci] - 128.0 : 0.0;
      final uu = ci + 1 < nv21.length ? nv21[ci + 1] - 128.0 : 0.0;
      final o = (ty * kThumbW + tx) * 4;
      out[o] = (yv + 1.402 * vv).round().clamp(0, 255);
      out[o + 1] = (yv - 0.344136 * uu - 0.714136 * vv).round().clamp(0, 255);
      out[o + 2] = (yv + 1.772 * uu).round().clamp(0, 255);
      out[o + 3] = 255;
    }
  }
  return out;
}

/// v11.35 upright grey sample of the centre 1/[zoom] of the frame.
Uint8List _cropLuma(
  Uint8List nv21,
  int w,
  int h,
  int stride,
  int rotation,
  double zoom,
) {
  final out = Uint8List(kThumbW * kThumbH);
  final rot = ((rotation % 360) + 360) % 360;
  final half = 0.5 / zoom;
  for (var ty = 0; ty < kThumbH; ty++) {
    for (var tx = 0; tx < kThumbW; tx++) {
      final u = 0.5 - half + (tx + 0.5) / kThumbW * 2 * half;
      final v = 0.5 - half + (ty + 0.5) / kThumbH * 2 * half;
      double fx, fy;
      switch (rot) {
        case 90:
          fx = v;
          fy = 1 - u;
        case 180:
          fx = 1 - u;
          fy = 1 - v;
        case 270:
          fx = 1 - v;
          fy = u;
        default:
          fx = u;
          fy = v;
      }
      final sx = (fx * (w - 1)).round().clamp(0, w - 1);
      final sy = (fy * (h - 1)).round().clamp(0, h - 1);
      out[ty * kThumbW + tx] = nv21[sy * stride + sx];
    }
  }
  return out;
}

/// v11.35: grey (1 byte/px) view of a thumb that may be RGBA (4 bytes/px).
Uint8List lumaOf(Uint8List t, int w, int h) {
  if (t.length < w * h * 4) return t;
  final out = Uint8List(w * h);
  for (var i = 0; i < w * h; i++) {
    out[i] = ((t[i * 4] * 77 + t[i * 4 + 1] * 150 + t[i * 4 + 2] * 29) >> 8);
  }
  return out;
}
