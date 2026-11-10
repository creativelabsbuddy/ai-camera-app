import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'image_guard.dart' show grayProxy;

// v11.34 high-zoom helpers (100x path): bright-region metering, checkpoint
// subject match, per-phone clear limit. Generic luminance only — no subject
// recognition.

// ---------------------------------------------------------------------------
// 1. Bright small region clipping in a dark frame
// ---------------------------------------------------------------------------

/// v11.35: bright = the brightest ~0.5 % of the visible crop (and at least
/// this grey level), well above the rest.
const double kBrightPercentile = 0.995;

/// v11.36: relative only — no fixed 200 floor (a correctly exposed moon
/// at ~210 must still count). Bright level never below this grey.
const int kBrightFloor = 60;
const int kBrightBand = 15; // within this of the top value counts as bright
const int kBrightContrast = 60; // bright level − rest mean

/// Bright area must be at least / at most this share of the visible crop.
const double kBrightMinArea = 0.001;
const double kBrightMaxArea = 0.08; // v11.46: small lamp / moon only

/// The rest of the crop must be darker than this (mean grey 0..255).
const double kBrightDarkRest = 35; // v11.46: really dark around (was 80)

/// Exposure offset used on the bright region (clamped to the device).
const double kBrightEv = -2.5;
const double kBrightEvMin = -3.0;

class BrightSpot {
  const BrightSpot(
    this.centroid,
    this.area,
    this.restMean, [
    this.level = 0,
    this.top = 0,
  ]);

  /// Upright point (0..1) in the GIVEN image (the visible crop).
  final Offset centroid;
  final double area;
  final double restMean;
  final int level;

  /// Brightest grey of the image (exposure stepping).
  final int top;
}

/// Last check (debug note): area, rest mean, threshold, found.
String brightDebug = '';

/// Bright small region in an otherwise dark GREY image (1 byte/px; RGBA is
/// converted), or null. Pure.
BrightSpot? findBrightSpot(Uint8List? img, int w, int h) {
  if (img == null || w <= 0 || h <= 0 || img.length < w * h) return null;
  final g = img.length >= w * h * 4 ? _luma(img, w, h) : img;
  final total = w * h;
  final hist = List<int>.filled(256, 0);
  for (var i = 0; i < total; i++) {
    hist[g[i]]++;
  }
  var acc = 0, p = 255;
  final need = (total * (1 - kBrightPercentile)).ceil();
  for (var v = 255; v >= 0; v--) {
    acc += hist[v];
    if (acc >= need) {
      p = v;
      break;
    }
  }
  // v11.36 relative: also at least median + contrast (tiny spots where
  // the 99.5th percentile is still background).
  var med = 0, cum = 0;
  for (var v = 0; v < 256; v++) {
    cum += hist[v];
    if (cum * 2 >= total) {
      med = v;
      break;
    }
  }
  var maxV = 255;
  while (maxV > 0 && hist[maxV] == 0) {
    maxV--;
  }
  final thr = math.max(
    kBrightFloor,
    math.max(p - kBrightBand, med + kBrightContrast),
  );
  var n = 0, sx = 0.0, sy = 0.0, rest = 0.0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = g[y * w + x];
      if (v >= thr) {
        n++;
        sx += x + 0.5;
        sy += y + 0.5;
      } else {
        rest += v;
      }
    }
  }
  final area = n / total;
  final restMean = rest / math.max(1, total - n);
  final ok =
      n > 0 &&
      area >= kBrightMinArea &&
      area <= kBrightMaxArea &&
      restMean <= kBrightDarkRest &&
      thr - restMean >= kBrightContrast;
  brightDebug =
      'bright ${ok ? 'found' : 'no'} area ${(area * 100).toStringAsFixed(1)}% '
      'rest ${restMean.toStringAsFixed(0)} top $p';
  if (!ok) return null;
  return BrightSpot(Offset(sx / n / w, sy / n / h), area, restMean, thr, maxV);
}

Uint8List _luma(Uint8List t, int w, int h) {
  final out = Uint8List(w * h);
  for (var i = 0; i < w * h; i++) {
    out[i] = ((t[i * 4] * 77 + t[i * 4 + 1] * 150 + t[i * 4 + 2] * 29) >> 8);
  }
  return out;
}

/// Point in the visible crop (0..1) → point in the full camera frame.
Offset cropToFrame(Offset p, double cropZoom) {
  final z = cropZoom >= 1 ? cropZoom : 1.0;
  return Offset(0.5 + (p.dx - 0.5) / z, 0.5 + (p.dy - 0.5) / z);
}

/// v11.35 metering area (share of the camera frame) that matches the
/// visible crop (CameraX default 0.15).
/// v11.36: never tiny (min 0.05) so AF/AE have enough to work with.
double meteringSizeFor(double digitalZoom) =>
    (0.15 / (digitalZoom >= 1 ? digitalZoom : 1)).clamp(0.05, 0.15);

/// v11.35: after a bright lock at the device's lowest EV the spot still
/// clips for this long → manual short exposure (when allowed).
const Duration kBrightManualAfter = Duration(milliseconds: 1500);
const int kBrightManualExposureNs = 2000000; // 1/500 s
const int kBrightManualIso = 100;

/// Focus to infinity for a bright subject from this camera zoom up.
const double kInfinityFocusZoom = 5;

/// Tap pauses auto bright metering this long (or until the next zoom).
const Duration kTapPausesBright = Duration(seconds: 10);

/// A tap survives a zoom change smaller than this ratio.
const double kTapKeepZoomRatio = 1.25;

bool tapSurvivesZoom(double from, double to) {
  if (from <= 0 || to <= 0) return false;
  final r = from > to ? from / to : to / from;
  return r < kTapKeepZoomRatio;
}

/// Exposure offset for the bright region, clamped to the device range.
double brightEvFor(double deviceMin, double deviceMax) {
  final lo = math.max(deviceMin, kBrightEvMin);
  return kBrightEv.clamp(lo, math.max(lo, deviceMax)).toDouble();
}

/// On after 3 frames with a bright spot, off after 10 frames without
/// (no flicker).
class BrightMeter {
  int _on = 0, _off = 0;
  bool active = false;
  Offset? point;

  /// Returns true when [active] changed.
  bool update(BrightSpot? s) {
    if (s != null) {
      _on++;
      _off = 0;
      point = s.centroid;
      if (!active && _on >= 3) return active = true;
    } else {
      _off++;
      _on = 0;
      if (active && _off >= 10) {
        active = false;
        point = null;
        return true;
      }
    }
    return false;
  }

  void reset() {
    _on = _off = 0;
    active = false;
    point = null;
  }
}

// ---------------------------------------------------------------------------
// 3. Step-by-step zoom (cheap phones): checkpoints never skipped
// ---------------------------------------------------------------------------

/// Pause at each checkpoint while walking through it (photo taken).
const Duration kLadderStepPause = Duration(milliseconds: 250);
const String kZoomSlowlyHint = 'Zoom slowly for best detail';

/// Checkpoints strictly between [from] and [to] (zooming in) with no photo
/// yet, ascending. Pure.
List<double> checkpointsToWalk(
  double from,
  double to,
  List<double> checkpoints,
  Set<double> taken,
) => [
  for (final c in checkpoints)
    if (c > from + 0.01 && c < to - 0.01 && !taken.contains(c)) c,
];

// ---------------------------------------------------------------------------
// 4. Subject change between checkpoints (centre region after scale)
// ---------------------------------------------------------------------------

/// Below this the two photos show a different subject.
const double kSubjectMatchMin = 0.45;
const int kMatchW = 48, kMatchH = 36;

/// Normalised cross-correlation of two equal-size grey images. Pure.
double ncc(List<double> a, List<double> b) {
  final n = math.min(a.length, b.length);
  if (n == 0) return 0;
  var ma = 0.0, mb = 0.0;
  for (var i = 0; i < n; i++) {
    ma += a[i];
    mb += b[i];
  }
  ma /= n;
  mb /= n;
  var num = 0.0, da = 0.0, db = 0.0;
  for (var i = 0; i < n; i++) {
    final x = a[i] - ma, y = b[i] - mb;
    num += x * y;
    da += x * x;
    db += y * y;
  }
  if (da < 1e-6 || db < 1e-6) return da < 1e-6 && db < 1e-6 ? 1 : 0;
  return num / math.sqrt(da * db);
}

/// Centre 1/[factor] of a [w]×[h] grey image, resampled to [ow]×[oh]
/// (nearest). Pure.
List<double> centreResample(
  List<double> v,
  int w,
  int h,
  double factor,
  int ow,
  int oh,
) {
  final f = math.max(1.0, factor);
  final cw = w / f, ch = h / f;
  final x0 = (w - cw) / 2, y0 = (h - ch) / 2;
  return [
    for (var y = 0; y < oh; y++)
      for (var x = 0; x < ow; x++)
        v[(math.min(h - 1, (y0 + (y + 0.5) * ch / oh).floor())) * w +
            math.min(w - 1, (x0 + (x + 0.5) * cw / ow).floor())],
  ];
}

/// v11.36 edge map (gradient magnitude) with clipped pixels (≥ 250, and
/// their neighbours) masked out (NaN). Pure.
List<double> edgeMap(List<double> v, int w, int h) {
  final out = List<double>.filled(w * h, double.nan);
  for (var y = 0; y < h - 1; y++) {
    for (var x = 0; x < w - 1; x++) {
      final i = y * w + x;
      final a = v[i], r = v[i + 1], d = v[i + w];
      if (a >= 250 || r >= 250 || d >= 250) continue;
      out[i] = (r - a).abs() + (d - a).abs();
    }
  }
  return out;
}

/// NCC over the pixels valid in both (NaN = masked). Pure.
double maskedNcc(List<double> a, List<double> b) {
  var n = 0;
  var ma = 0.0, mb = 0.0;
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i].isNaN || b[i].isNaN) continue;
    ma += a[i];
    mb += b[i];
    n++;
  }
  if (n < 20) return 1; // nothing comparable (all clipped) → no evidence
  ma /= n;
  mb /= n;
  var num = 0.0, da = 0.0, db = 0.0;
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i].isNaN || b[i].isNaN) continue;
    final x = a[i] - ma, y = b[i] - mb;
    num += x * y;
    da += x * x;
    db += y * y;
  }
  if (da < 1e-6 || db < 1e-6) return da < 1e-6 && db < 1e-6 ? 1 : 0;
  return num / math.sqrt(da * db);
}

/// Shift search: [wide] (ww×wh, covering [kMatchSlack]× the close view)
/// vs [close] (cw×ch); best masked edge NCC over all offsets. Pure.
double bestShiftMatch(
  List<double> wide,
  int ww,
  int wh,
  List<double> close,
  int cw,
  int ch,
) {
  final ce = edgeMap(close, cw, ch);
  final we = edgeMap(wide, ww, wh);
  var best = -1.0;
  for (var oy = 0; oy + ch <= wh; oy++) {
    for (var ox = 0; ox + cw <= ww; ox++) {
      final win = [
        for (var y = 0; y < ch; y++)
          for (var x = 0; x < cw; x++) we[(oy + y) * ww + ox + x],
      ];
      final s = maskedNcc(win, ce);
      if (s > best) best = s;
    }
  }
  return best;
}

/// ±15 % shift search window.
const double kMatchSlack = 1.3;

/// How well the wider photo [wide] (camera zoom [wideCam]) matches the
/// closer photo [close] ([closeCam]): edges, ±15 % shift, clipped pixels
/// ignored (-1..1).
Future<double> checkpointMatch(
  String wide,
  double wideCam,
  String close,
  double closeCam,
) async {
  final f = math.max(1.0, closeCam / math.max(0.3, wideCam));
  final a = await grayProxy(
    await File(wide).readAsBytes(),
    (kMatchW * math.min(f, 8) * 1.2).round(),
  );
  final b = await grayProxy(await File(close).readAsBytes(), kMatchW);
  final ww = (kMatchW * kMatchSlack).round(),
      wh = (kMatchH * kMatchSlack).round();
  final av = centreResample(
    a.values,
    a.width,
    a.height,
    f / kMatchSlack,
    ww,
    wh,
  );
  final bv = centreResample(b.values, b.width, b.height, 1, kMatchW, kMatchH);
  return bestShiftMatch(av, ww, wh, bv, kMatchW, kMatchH);
}

/// v11.36: a subject change needs this many misses in a row.
const int kSubjectMissesNeeded = 2;

bool isSameSubject(double score) => score >= kSubjectMatchMin;

// ---------------------------------------------------------------------------
// 5. Per-phone clear limit (zoom where photos turn blurry)
// ---------------------------------------------------------------------------

const String kClearLimitKey = 'zoom_clear_limit_v1';
const String kNewSubjectHint = 'New subject – tap to capture detail';
const Duration kClearLimitAnim = Duration(milliseconds: 1000);

/// From (checkpoint, clear?) pairs, ascending: the highest clear checkpoint
/// right before the first blurry one, or null when none turned blurry.
double? observedClearLimit(List<(double, bool)> shots) {
  double? lastClear;
  for (final (z, clear) in shots) {
    if (clear) {
      lastClear = z;
    } else if (lastClear != null) {
      return lastClear;
    }
  }
  return null;
}

/// Show the hint when the subject changed past the clear limit.
bool showNewSubjectHint({
  required bool subjectChanged,
  required double zoom,
  required double? clearLimit,
}) => subjectChanged && clearLimit != null && zoom > clearLimit + 0.01;

// ---------------------------------------------------------------------------
// v11.36 far-bright latch (Zoom mode only)
// ---------------------------------------------------------------------------

/// Latch turns on from this camera zoom, ends below [kLatchOffZoom].
const double kLatchOnZoom = 5;
const double kLatchOffZoom = 3;

/// Latch ends after this long without a bright spot.
const Duration kLatchIdle = Duration(seconds: 30);

/// Manual exposure: start, limits (ns) and target top level.
const int kLatchStartNs = 4000000; // 1/250 s
const int kLatchMinNs = 500000; // 1/2000 s
const int kLatchMaxNs = 8000000; // 1/125 s
const int kLatchIso = 100;
const int kLatchTargetLow = 200;
const int kLatchTargetHigh = 230;

/// Next shutter (ns) so the spot's top level lands in 200–230 without
/// clipping. Pure.
int nextLatchExposure(int currentNs, int top) {
  var n = currentNs;
  if (top >= 245) {
    n = (currentNs / 1.6).round(); // clipping: faster shutter
  } else if (top > kLatchTargetHigh) {
    n = (currentNs / 1.15).round();
  } else if (top < kLatchTargetLow) {
    n = (currentNs * (top < 120 ? 1.6 : 1.15)).round();
  }
  return n.clamp(kLatchMinNs, kLatchMaxNs);
}

/// 99th-percentile grey in a square of half-size [r] around [c] (0..1) of
/// a w×h grey image (tap re-metering). Pure.
int regionTop(Uint8List g, int w, int h, Offset c, {double r = 0.15}) {
  final x0 = ((c.dx - r) * w).floor().clamp(0, w - 1);
  final x1 = ((c.dx + r) * w).ceil().clamp(1, w);
  final y0 = ((c.dy - r) * h).floor().clamp(0, h - 1);
  final y1 = ((c.dy + r) * h).ceil().clamp(1, h);
  final v = <int>[
    for (var y = y0; y < y1; y++)
      for (var x = x0; x < x1; x++) g[y * w + x],
  ]..sort();
  if (v.isEmpty) return 0;
  return v[((v.length - 1) * 0.99).round()];
}

/// Camera-frame point (0..1) → point in the visible crop. Pure.
Offset frameToCrop(Offset p, double cropZoom) {
  final z = cropZoom >= 1 ? cropZoom : 1.0;
  return Offset(0.5 + (p.dx - 0.5) * z, 0.5 + (p.dy - 0.5) * z);
}

/// Normal zoom limit (Zoom mode off).
const double kNormalZoomMax = 10;
const String kZoomModeHint = 'Tap Zoom mode for more';
const String kZoomModeLabel = 'Zoom mode';
const String kAutoFocusLabel = 'Auto focus';
