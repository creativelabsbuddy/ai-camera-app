import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'frame_stats.dart';
import 'macro.dart' show MacroLevel;

// v11.33 Macro level chips + centre box check (free, on-device).

/// Centre box = this fraction of the preview width / height.
const double kMacroBoxFraction = 0.5;

/// Highest zoom a level chip allows (clamped to the device max).
const double kMacroLevelMaxZoom = 10; // v11.41: manual zoom 1x–10x

/// Start zoom per level. v11.46: used again when a level is picked so the
/// ladder rises with the level (Macro < Close < Microscope < Extreme < Ultra).
const Map<MacroLevel, double> kMacroLevelStartZoom = {
  MacroLevel.macro: 2,
  MacroLevel.close: 3,
  MacroLevel.microscope: 4,
  MacroLevel.extreme: 6,
  MacroLevel.ultra: 8,
};

/// Old zoom band per level (for the v11.7 disclaimer helpers).
const Map<MacroLevel, double> kMacroLevelBandZoom = {
  MacroLevel.macro: 3,
  MacroLevel.close: 6,
  MacroLevel.microscope: 12,
  MacroLevel.extreme: 21,
  MacroLevel.ultra: 30,
};

/// Microscope hint photo is taken at or below this zoom when the chip is
/// tapped (free, sent as a wider context crop).
const double kMicroscopeHintMaxZoom = 2;

/// v11.41 manual macro zoom chips (1x, 2x, 3x, 5x, 10x within the max).
List<double> macroZoomChips(double deviceMax) {
  final m = macroLevelMaxZoom(deviceMax);
  return [
    for (final z in const [1.0, 2.0, 3.0, 5.0, 10.0])
      if (z <= m + 0.01) z,
  ];
}

/// v11.40: zoom when a level chip is picked — the user's zoom (never an
/// automatic jump up), only capped at the macro max.
double macroLevelPickZoom(double current, double deviceMax) =>
    current.clamp(1.0, macroLevelMaxZoom(deviceMax)).toDouble();

/// v11.46 step photos: chip steps captured before the final photo.
const List<double> kMacroStepZooms = [2.0, 5.0, 10.0];

/// v11.46 step photos at the shutter: every step in [kMacroStepZooms]
/// strictly below [shotZoom] (lowest first). Z ≤ 2x → none (final only).
List<double> macroContextZooms(double shotZoom) => [
  for (final z in kMacroStepZooms)
    if (z < shotZoom - 0.05) z,
];

/// v11.46 progress hint, e.g. "Capturing 2x… 5x… final".
String macroStepHint(List<double> steps) => [
  'Capturing',
  for (final z in steps) '${z.toStringAsFixed(0)}x…',
  'final',
].join(' ');

/// v11.42: a context photo is cut to this many times the main shot's area
/// (width) — genuinely wider. Used as the step crop margin.
const double kMacroCtxMargin = 2.5;

/// v11.42: a context photo must be at least this much wider than the shot.
const double kMacroCtxMinWider = 1.2; // v11.46: 2x step before a 3x shot

/// Region zoom (vs the full context photo) a context photo is cut to. Pure.
double macroCtxCropZoom(double regionZoom) =>
    math.max(1.0, regionZoom / kMacroCtxMargin);

/// Short chip names (+ credits on the chip).
const Map<MacroLevel, String> kMacroChipNames = {
  MacroLevel.macro: 'Macro',
  MacroLevel.close: 'Close',
  MacroLevel.microscope: 'Microscope',
  MacroLevel.extreme: 'Extreme',
  MacroLevel.ultra: 'Ultra',
};

/// Max zoom for the levels: min(10, device max), never below 1.
double macroLevelMaxZoom(double deviceMax) =>
    math.max(1.0, math.min(kMacroLevelMaxZoom, deviceMax));

double macroLevelStartZoom(MacroLevel level, double deviceMax) =>
    math.min(kMacroLevelStartZoom[level]!, macroLevelMaxZoom(deviceMax));

/// Smooth zoom path from [from] to [to] over [ms] (ease in-out), one value
/// per [stepMs]; last value = [to]. Never jumps.
List<double> smoothZoomPath(
  double from,
  double to, {
  int ms = 1000,
  int stepMs = 50,
}) {
  final n = math.max(1, (ms / stepMs).round());
  return [for (var i = 1; i <= n; i++) from + (to - from) * _ease(i / n)];
}

double _ease(double t) => t < 0.5 ? 2 * t * t : 1 - math.pow(-2 * t + 2, 2) / 2;

/// How much of the centre box the subject fills (0..1), from the grey
/// thumbnail: a box block counts as subject when it differs from the
/// surround (outside the box) or has its own texture.
double boxFill(Uint8List? thumb, int w, int h) {
  if (thumb == null || w < 8 || h < 8 || thumb.length < w * h) return 0;
  thumb = lumaOf(thumb, w, h); // v11.35: the thumb is RGBA (crop: grey)
  final bx0 = (w * (1 - kMacroBoxFraction) / 2).round();
  final by0 = (h * (1 - kMacroBoxFraction) / 2).round();
  final bx1 = w - bx0, by1 = h - by0;
  var bgSum = 0.0, bgN = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final inBox = x >= bx0 && x < bx1 && y >= by0 && y < by1;
      if (!inBox) {
        bgSum += thumb[y * w + x];
        bgN++;
      }
    }
  }
  final bg = bgN == 0 ? 128 : bgSum / bgN;
  const b = 4;
  var blocks = 0, hit = 0;
  for (var y = by0; y + b <= by1; y += b) {
    for (var x = bx0; x + b <= bx1; x += b) {
      var s = 0.0, s2 = 0.0;
      for (var yy = y; yy < y + b; yy++) {
        for (var xx = x; xx < x + b; xx++) {
          final v = thumb[yy * w + xx].toDouble();
          s += v;
          s2 += v * v;
        }
      }
      const n = b * b;
      final mean = s / n;
      final sd = math.sqrt(math.max(0, s2 / n - mean * mean));
      blocks++;
      if ((mean - bg).abs() > kBoxBgDiff || sd > kBoxTexture) hit++;
    }
  }
  return blocks == 0 ? 0 : hit / blocks;
}

/// Tuning (v11.40: looser — hints only, smooth subjects such as skin pass).
const double kBoxBgDiff = 10;
const double kBoxTexture = 4;

/// Some subject in the box but under this fill → "put it in the box" hint.
const double kBoxSmallFill = 0.25;

/// …and at least this much (an even, smooth view such as skin filling the
/// whole frame scores ~0 and is fine).
const double kBoxSomeFill = 0.05;

/// Below this centre sharpness (Laplacian) → "Tap to focus".
const double kBoxBlurSharpness = 12;

/// v11.40 soft hints only — never block the shutter.
enum MacroBoxGuide {
  holdSteady('Hold steady'),
  tapToFocus('Tap to focus'),
  putInBox('Put your subject inside the box – zoom will do the rest');

  const MacroBoxGuide(this.text);
  final String text;
}

/// One frame → soft hint. Blurry centre: tap to focus; a small subject in
/// the box: put it in the box; else hold steady.
MacroBoxGuide macroBoxGuideFor({
  required double fill,
  required double sharpness,
}) {
  if (sharpness < kBoxBlurSharpness) return MacroBoxGuide.tapToFocus;
  if (fill >= kBoxSomeFill && fill < kBoxSmallFill) {
    return MacroBoxGuide.putInBox;
  }
  return MacroBoxGuide.holdSteady;
}

/// Box hint with 2-frame hysteresis (no flicker).
class MacroBoxCheck {
  MacroBoxGuide guide = MacroBoxGuide.holdSteady;
  MacroBoxGuide? _pending;
  int _count = 0;
  double fill = 0;
  double sharpness = 0;

  /// Box drawn gold when nothing to hint (the shutter always works).
  bool get ready => guide == MacroBoxGuide.holdSteady;

  void reset() {
    guide = MacroBoxGuide.holdSteady;
    _pending = null;
    _count = 0;
    fill = 0;
    sharpness = 0;
  }

  /// v11.40: the VISIBLE zoomed area (crop luma, matches the on-screen
  /// box); the whole frame only when no crop sample exists.
  /// Returns true when the shown hint changed.
  bool update(FrameStats s) {
    final crop = s.cropLuma;
    fill = crop != null && crop.length >= kThumbW * kThumbH
        ? boxFill(crop, kThumbW, kThumbH)
        : boxFill(s.thumb, s.thumbWidth, s.thumbHeight);
    sharpness = s.sharpness;
    final g = macroBoxGuideFor(fill: fill, sharpness: sharpness);
    if (g == guide) {
      _pending = null;
      _count = 0;
      return false;
    }
    if (g == _pending) {
      _count++;
    } else {
      _pending = g;
      _count = 1;
    }
    if (_count < 2) return false;
    guide = g;
    _pending = null;
    _count = 0;
    return true;
  }

  String get debug =>
      'box fill ${fill.toStringAsFixed(2)} sharp ${sharpness.toStringAsFixed(0)} · ${guide.name}';
}

/// Shutter without a level picked.
const String kPickMacroLevel =
    'Pick a level: Macro, Close, Microscope, Extreme or Ultra';

/// Centre 1/[factor] of the photo at [path] → a small JPEG (≤[maxLong] px)
/// in [dir] (the box area for the shutter detection).
Future<String> cropCentreToFile(
  String path,
  double factor,
  String dir, {
  int maxLong = 768,
}) {
  final out = '$dir/macro_box_${DateTime.now().microsecondsSinceEpoch}.jpg';
  return Isolate.run(() {
    final src = img.decodeImage(File(path).readAsBytesSync());
    if (src == null) throw StateError('decode failed');
    final o = img.bakeOrientation(src);
    final f = factor < 1 ? 1.0 : factor;
    final w = math.max(8, (o.width / f).round());
    final h = math.max(8, (o.height / f).round());
    var c = img.copyCrop(
      o,
      x: (o.width - w) ~/ 2,
      y: (o.height - h) ~/ 2,
      width: w,
      height: h,
    );
    if (math.max(w, h) > maxLong) {
      c = w >= h
          ? img.copyResize(c, width: maxLong)
          : img.copyResize(c, height: maxLong);
    }
    File(out).writeAsBytesSync(img.encodeJpg(c, quality: 88));
    return out;
  });
}

// ---- v11.47 Microscope: sharpest photo for the spot detection -------------

/// Laplacian variance over a whole grey image (step 1). Higher = sharper.
double laplacianVariance(Uint8List g, int w, int h) {
  if (w < 3 || h < 3 || g.length < w * h) return 0;
  var s = 0.0, s2 = 0.0;
  var n = 0;
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x;
      final lap = (g[i - 1] + g[i + 1] + g[i - w] + g[i + w] - 4 * g[i])
          .toDouble();
      s += lap;
      s2 += lap * lap;
      n++;
    }
  }
  final mean = s / n;
  return s2 / n - mean * mean;
}

/// Index of the highest score (first wins on a tie; -1 when empty).
int sharpestPhotoIndex(List<double> scores) {
  var best = -1;
  for (var i = 0; i < scores.length; i++) {
    if (best < 0 || scores[i] > scores[best]) best = i;
  }
  return best;
}

/// Long side of the grey copy used for the sharpness score.
const int kSharpnessLong = 256;

/// Sharpness of the centre 1/[factor] of a photo, on a downscaled grey
/// copy (free, on-device). 0 when the file can't be read.
Future<double> photoRegionSharpness(String path, double factor) =>
    Isolate.run(() {
      try {
        final src = img.decodeImage(File(path).readAsBytesSync());
        if (src == null) return 0.0;
        final o = img.bakeOrientation(src);
        final f = factor < 1 ? 1.0 : factor;
        final w = math.max(8, (o.width / f).round());
        final h = math.max(8, (o.height / f).round());
        var c = img.copyCrop(
          o,
          x: (o.width - w) ~/ 2,
          y: (o.height - h) ~/ 2,
          width: w,
          height: h,
        );
        c = w >= h
            ? img.copyResize(c, width: kSharpnessLong)
            : img.copyResize(c, height: kSharpnessLong);
        final g = Uint8List(c.width * c.height);
        var i = 0;
        for (final p in c) {
          g[i++] = p.luminance.toInt().clamp(0, 255);
        }
        return laplacianVariance(g, c.width, c.height);
      } catch (_) {
        return 0.0;
      }
    });
