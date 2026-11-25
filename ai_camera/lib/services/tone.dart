import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// v11.69 free on-device tone (Normal mode): Auto Tone + Tone presets +
/// manual sliders. Single frame only — no frame merging. Pure maths here
/// (unit tested); widgets live in tone_bar.dart / preview_screen.dart.
///
/// Every value is −1..1 (0 = unchanged).
@immutable
class ToneParams {
  const ToneParams({
    this.exposure = 0,
    this.contrast = 0,
    this.highlights = 0,
    this.shadows = 0,
    this.warmth = 0,
    this.saturation = 0,
  });

  /// Brightness (gamma-style, ends kept: never clips).
  final double exposure;
  final double contrast;

  /// Negative = darker / recovered highlights.
  final double highlights;

  /// Positive = lifted shadows.
  final double shadows;

  /// Positive = warmer (more red / less blue).
  final double warmth;
  final double saturation;

  static const zero = ToneParams();

  bool get isNeutral =>
      exposure.abs() < 1e-3 &&
      contrast.abs() < 1e-3 &&
      highlights.abs() < 1e-3 &&
      shadows.abs() < 1e-3 &&
      warmth.abs() < 1e-3 &&
      saturation.abs() < 1e-3;

  static double _c(double v) => v.isFinite ? v.clamp(-1.0, 1.0) : 0.0;

  ToneParams clamped() => ToneParams(
    exposure: _c(exposure),
    contrast: _c(contrast),
    highlights: _c(highlights),
    shadows: _c(shadows),
    warmth: _c(warmth),
    saturation: _c(saturation),
  );

  ToneParams operator +(ToneParams o) => ToneParams(
    exposure: exposure + o.exposure,
    contrast: contrast + o.contrast,
    highlights: highlights + o.highlights,
    shadows: shadows + o.shadows,
    warmth: warmth + o.warmth,
    saturation: saturation + o.saturation,
  ).clamped();

  ToneParams copyWith({
    double? exposure,
    double? contrast,
    double? highlights,
    double? shadows,
    double? warmth,
    double? saturation,
  }) => ToneParams(
    exposure: exposure ?? this.exposure,
    contrast: contrast ?? this.contrast,
    highlights: highlights ?? this.highlights,
    shadows: shadows ?? this.shadows,
    warmth: warmth ?? this.warmth,
    saturation: saturation ?? this.saturation,
  );

  /// Stable cache key (2 decimals).
  String get key => [
    exposure,
    contrast,
    highlights,
    shadows,
    warmth,
    saturation,
  ].map((v) => v.toStringAsFixed(2)).join(',');

  @override
  bool operator ==(Object other) => other is ToneParams && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => 'ToneParams($key)';
}

/// Free tone presets (separate from the premium LUT filters and the Pro AI
/// styles, which are unchanged).
enum TonePreset {
  auto('Auto'),
  vivid('Vivid'),
  natural('Natural'),
  warm('Warm'),
  cool('Cool'),
  food('Food'),
  portraitSoft('Portrait soft'),
  bw('B&W');

  const TonePreset(this.label);
  final String label;

  static const prefsKey = 'tone_preset_v1169';

  static TonePreset fromName(String? n) => TonePreset.values.firstWhere(
    (t) => t.name == n,
    orElse: () => TonePreset.auto,
  );

  /// The look added on top of the auto balance (Auto = none).
  ToneParams get offset => switch (this) {
    TonePreset.auto => ToneParams.zero,
    TonePreset.vivid => const ToneParams(
      contrast: 0.18,
      saturation: 0.32,
      shadows: 0.06,
    ),
    TonePreset.natural => const ToneParams(
      contrast: -0.06,
      saturation: -0.10,
      highlights: -0.10,
    ),
    TonePreset.warm => const ToneParams(warmth: 0.32, saturation: 0.05),
    TonePreset.cool => const ToneParams(warmth: -0.32),
    TonePreset.food => const ToneParams(
      exposure: 0.05,
      contrast: 0.10,
      warmth: 0.16,
      saturation: 0.28,
    ),
    TonePreset.portraitSoft => const ToneParams(
      contrast: -0.16,
      highlights: -0.12,
      shadows: 0.12,
      warmth: 0.08,
      saturation: -0.06,
    ),
    TonePreset.bw => const ToneParams(contrast: 0.12),
  };

  bool get mono => this == TonePreset.bw;
}

/// Full tone of a photo = auto balance (if on) + preset look + manual.
ToneParams composeTone({
  required ToneParams auto,
  required bool autoOn,
  required TonePreset preset,
  ToneParams manual = ToneParams.zero,
}) => (autoOn ? auto : ToneParams.zero) + preset.offset + manual;

/// Whether [t] / [preset] changes the photo at all.
bool toneChangesPhoto(ToneParams t, TonePreset preset) =>
    !t.isNeutral || preset.mono;

// ---------------------------------------------------------------------------
// Statistics → Auto Tone
// ---------------------------------------------------------------------------

/// Cheap statistics of a (small) RGBA frame.
@immutable
class ToneStats {
  const ToneStats({
    required this.lo,
    required this.median,
    required this.hi,
    required this.clipHigh,
    required this.deepShadow,
    required this.meanR,
    required this.meanG,
    required this.meanB,
    required this.chroma,
  });

  /// 2nd / 50th / 98th luma percentiles (0..1).
  final double lo;
  final double median;
  final double hi;

  /// Share of pixels with luma > 0.96 / < 0.06.
  final double clipHigh;
  final double deepShadow;

  /// Mean channel values (0..1).
  final double meanR;
  final double meanG;
  final double meanB;

  /// Mean (max − min) per pixel (0..1): how colourful the photo is.
  final double chroma;
}

/// Stats from RGBA bytes (every [step]-th pixel).
ToneStats toneStatsOf(Uint8List rgba, int width, int height, {int step = 2}) {
  final hist = List<int>.filled(256, 0);
  var n = 0;
  var sr = 0.0, sg = 0.0, sb = 0.0, sc = 0.0;
  var hiClip = 0, deep = 0;
  final s = math.max(1, step);
  for (var y = 0; y < height; y += s) {
    var i = (y * width) * 4;
    for (var x = 0; x < width; x += s, i += 4 * s) {
      if (i + 2 >= rgba.length) break;
      final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
      final l = (r * 54 + g * 183 + b * 19) >> 8;
      hist[l]++;
      if (l > 245) hiClip++;
      if (l < 15) deep++;
      sr += r;
      sg += g;
      sb += b;
      sc += math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
      n++;
    }
  }
  if (n == 0) {
    return const ToneStats(
      lo: 0,
      median: 0.5,
      hi: 1,
      clipHigh: 0,
      deepShadow: 0,
      meanR: 0.5,
      meanG: 0.5,
      meanB: 0.5,
      chroma: 0.2,
    );
  }
  double pct(double q) {
    final target = q * n;
    var acc = 0;
    for (var v = 0; v < 256; v++) {
      acc += hist[v];
      if (acc >= target) return v / 255;
    }
    return 1;
  }

  return ToneStats(
    lo: pct(0.02),
    median: pct(0.5),
    hi: pct(0.98),
    clipHigh: hiClip / n,
    deepShadow: deep / n,
    meanR: sr / n / 255,
    meanG: sg / n / 255,
    meanB: sb / n / 255,
    chroma: sc / n / 255,
  );
}

/// Gentle automatic balance for one photo. Pure. Corrections are partial
/// (the photo's mood is kept) and bounded so nothing looks over-processed.
ToneParams autoToneFor(ToneStats s) {
  // Brightness: move the median part of the way toward ~0.46.
  var exposure = 0.0;
  final m = s.median.clamp(0.03, 0.97);
  if ((m - 0.46).abs() > 0.04) {
    // m^(2^(−0.7e)) = 0.46 → e = −log2(ln 0.46 / ln m) / 0.7
    final e = -(math.log(math.log(0.46) / math.log(m)) / math.ln2) / 0.7;
    exposure = (e * 0.55).clamp(-0.30, 0.40);
  }
  // Contrast: flat photos get a little more, already punchy ones a touch less.
  final spread = s.hi - s.lo;
  var contrast = 0.0;
  if (spread < 0.72) {
    contrast = ((0.72 - spread) * 0.9).clamp(0.0, 0.28);
  } else if (spread > 0.96) {
    contrast = -0.04;
  }
  // Highlights: blown areas are pulled back a little.
  final highlights = s.clipHigh > 0.02
      ? -(s.clipHigh * 6).clamp(0.0, 0.45)
      : 0.0;
  // Shadows: big crushed areas are lifted a little.
  final shadows = s.deepShadow > 0.06
      ? (s.deepShadow * 2.2).clamp(0.0, 0.40)
      : 0.0;
  // Warmth: partial grey-world correction of a colour cast (±0.2 max).
  var warmth = 0.0;
  final g = math.max(0.05, s.meanG);
  final cast = (s.meanB - s.meanR) / g; // >0 = bluish photo
  if (cast.abs() > 0.05) warmth = (cast * 0.8).clamp(-0.20, 0.20);
  // Saturation: dull photos get a little more colour.
  double saturation;
  if (s.chroma < 0.10) {
    saturation = ((0.10 - s.chroma) * 2 + 0.06).clamp(0.0, 0.22);
  } else if (s.chroma > 0.32) {
    saturation = -0.05;
  } else {
    saturation = 0.06;
  }
  return ToneParams(
    exposure: exposure,
    contrast: contrast,
    highlights: highlights,
    shadows: shadows,
    warmth: warmth,
    saturation: saturation,
  ).clamped();
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

/// Tone curve for one channel value v (0..1) BEFORE saturation. Monotonic
/// for every params in −1..1; 0 and 1 stay put except by warmth gain.
double toneCurve(double v, ToneParams t, {double gain = 1}) {
  var x = (v * gain).clamp(0.0, 1.0);
  if (t.exposure != 0) {
    x = math.pow(x, math.pow(2, -0.7 * t.exposure)).toDouble();
  }
  if (t.contrast != 0) {
    final sCurve = x * x * (3 - 2 * x);
    x = x + t.contrast * 0.9 * (sCurve - x);
  }
  if (t.shadows != 0 && x < 0.5) {
    x = x + t.shadows * 0.4 * (x * (0.5 - x) * 4);
  }
  if (t.highlights != 0 && x > 0.5) {
    x = x + t.highlights * 0.4 * ((x - 0.5) * (1 - x) * 4);
  }
  return x.clamp(0.0, 1.0);
}

/// Per-channel LUTs (R, G, B) for [t].
(Uint8List, Uint8List, Uint8List) toneLuts(ToneParams t) {
  final w = t.warmth;
  final gr = 1 + w * 0.10, gg = 1 + w * 0.015, gb = 1 - w * 0.10;
  Uint8List lut(double gain) {
    final o = Uint8List(256);
    for (var i = 0; i < 256; i++) {
      o[i] = (toneCurve(i / 255, t, gain: gain) * 255).round().clamp(0, 255);
    }
    return o;
  }

  return (lut(gr), lut(gg), lut(gb));
}

/// Applies [t] (+ mono) to RGBA bytes in place.
void applyToneRgbaInPlace(Uint8List rgba, ToneParams t, {bool mono = false}) {
  final (lr, lg, lb) = toneLuts(t);
  // saturation factor ×256 (mono → 0).
  final sat = mono ? 0 : ((1 + t.saturation * 0.6) * 256).round();
  final doSat = sat != 256;
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    var r = lr[rgba[i]], g = lg[rgba[i + 1]], b = lb[rgba[i + 2]];
    if (doSat) {
      final l = (r * 54 + g * 183 + b * 19) >> 8;
      r = l + (((r - l) * sat) >> 8);
      g = l + (((g - l) * sat) >> 8);
      b = l + (((b - l) * sat) >> 8);
      r = r < 0 ? 0 : (r > 255 ? 255 : r);
      g = g < 0 ? 0 : (g > 255 ? 255 : g);
      b = b < 0 ? 0 : (b > 255 ? 255 : b);
    }
    rgba[i] = r;
    rgba[i + 1] = g;
    rgba[i + 2] = b;
  }
}

/// Copy of [rgba] with the tone applied (for the live preview isolate).
Uint8List toneRgba(Uint8List rgba, ToneParams t, {bool mono = false}) {
  final out = Uint8List.fromList(rgba);
  applyToneRgbaInPlace(out, t, mono: mono);
  return out;
}

/// Full-resolution tone render of [src] → a new JPEG in [outDir] (isolate;
/// the original file is never touched).
Future<File> renderToneFile(
  File src,
  ToneParams t, {
  bool mono = false,
  required String outDir,
  int quality = 93,
}) async {
  final path = src.path;
  final out = p.join(
    outDir,
    'ai_camera_tone_${DateTime.now().microsecondsSinceEpoch}.jpg',
  );
  final te = t.exposure, tc = t.contrast, th = t.highlights;
  final ts = t.shadows, tw = t.warmth, tsat = t.saturation;
  await Isolate.run(() {
    final raw = img.decodeImage(File(path).readAsBytesSync());
    if (raw == null) throw StateError('Unsupported image');
    final up = img.bakeOrientation(raw);
    final rgba = up.getBytes(order: img.ChannelOrder.rgba);
    applyToneRgbaInPlace(
      rgba,
      ToneParams(
        exposure: te,
        contrast: tc,
        highlights: th,
        shadows: ts,
        warmth: tw,
        saturation: tsat,
      ),
      mono: mono,
    );
    final whole =
        rgba.offsetInBytes == 0 &&
        rgba.lengthInBytes == rgba.buffer.lengthInBytes;
    final im = img.Image.fromBytes(
      width: up.width,
      height: up.height,
      bytes: (whole ? rgba : Uint8List.fromList(rgba)).buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    File(out).writeAsBytesSync(img.encodeJpg(im, quality: quality));
  });
  return File(out);
}

/// Live viewfinder approximation of a preset (Flutter ColorFilter.matrix,
/// offsets 0..255). Null = no change (Auto: the real auto balance needs the
/// captured photo). Highlights / shadows can't be shown by a matrix; the
/// exact tone is rendered after the shutter.
List<double>? tonePreviewMatrix(TonePreset preset) {
  if (preset == TonePreset.auto) return null;
  final t = preset.offset;
  final sat = preset.mono ? 0.0 : 1 + t.saturation * 0.6;
  final c = 1 + t.contrast * 0.45;
  final bright = t.exposure * 40 + t.shadows * 10 + t.highlights * 8;
  final rG = 1 + t.warmth * 0.10, gG = 1 + t.warmth * 0.015;
  final bG = 1 - t.warmth * 0.10;
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  double a(double l, bool d) => (d ? (1 - sat) * l + sat : (1 - sat) * l) * c;
  final off = 128 * (1 - c) + bright;
  return [
    a(lr, true) * rG, a(lg, false) * rG, a(lb, false) * rG, 0, off, //
    a(lr, false) * gG, a(lg, true) * gG, a(lb, false) * gG, 0, off, //
    a(lr, false) * bG, a(lg, false) * bG, a(lb, true) * bG, 0, off, //
    0, 0, 0, 1, 0,
  ];
}
