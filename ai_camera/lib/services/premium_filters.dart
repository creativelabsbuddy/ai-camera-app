import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// v11 premium colour filters.
///
/// * Live preview: on-device colour matrix fitted to the exact pipeline
///   (free, no credits, no API calls).
/// * NORMAL: the on-device result IS the final photo (free).
/// * PRO AI: the AI renders a premium final of the same look (hidden
///   server prompt per filter, admin-editable; tier credits on success).
///
/// Skin-aware: on skin tones the filter keeps the original hue /
/// saturation (only tone changes), so faces never turn orange / teal / grey
/// (except Pro B&W). Strength 0–100 % blends with the original.
enum PremiumFilter {
  original('original', 'Original'),
  vivid('vivid', 'Vivid'),
  richContrast('rich_contrast', 'Rich Contrast'),
  warmGold('warm_gold', 'Warm Gold'),
  coolClean('cool_clean', 'Cool Clean'),
  cinematic('cinematic', 'Cinematic'),
  film('film', 'Film'),
  moodyDark('moody_dark', 'Moody Dark'),
  softPastel('soft_pastel', 'Soft Pastel'),
  brightAiry('bright_airy', 'Bright Airy'),
  proBw('pro_bw', 'Pro B&W');

  const PremiumFilter(this.id, this.label);

  /// Server id (`color_filter`), same as prompts.COLOR_FILTER_PROMPTS.
  final String id;
  final String label;

  bool get isOriginal => this == PremiumFilter.original;

  static PremiumFilter fromId(String? id) => PremiumFilter.values.firstWhere(
    (f) => f.id == id,
    orElse: () => PremiumFilter.original,
  );

  FilterParams get params => kFilterParams[this]!;
}

/// Parametric look (all values are small offsets around "no change").
class FilterParams {
  const FilterParams({
    this.exposure = 0,
    this.contrast = 0,
    this.lift = 0,
    this.whitePoint = 1,
    this.temperature = 0,
    this.tint = 0,
    this.saturation = 1,
    this.vibrance = 0,
    this.shadows = const [0, 0, 0],
    this.highlights = const [0, 0, 0],
    this.mono = false,
    this.monoMix = const [0.30, 0.59, 0.11],
    this.grain = 0,
    this.skinProtect = 0.8,
  });

  /// EV (stops).
  final double exposure;

  /// > 0 = S-curve punch, < 0 = flatter / softer.
  final double contrast;

  /// Raised blacks (film / pastel fade), 0..0.1.
  final double lift;

  /// < 1 = softer highlights.
  final double whitePoint;

  /// + warm (amber) / − cool (blue).
  final double temperature;

  /// + green / − magenta.
  final double tint;
  final double saturation;

  /// Boosts muted colours more than already-saturated ones.
  final double vibrance;

  /// Split toning: RGB added in the shadows / highlights.
  final List<double> shadows;
  final List<double> highlights;
  final bool mono;
  final List<double> monoMix;
  final double grain;

  /// 0..1: how much of the original skin hue/saturation is kept.
  final double skinProtect;
}

/// Tuned looks. "Vivid" is iPhone-like: natural but rich (not Samsung neon).
const kFilterParams = <PremiumFilter, FilterParams>{
  PremiumFilter.original: FilterParams(skinProtect: 0),
  PremiumFilter.vivid: FilterParams(
    exposure: 0.04,
    contrast: 0.22,
    saturation: 1.10,
    vibrance: 0.22,
    temperature: 0.02,
    skinProtect: 0.75,
  ),
  PremiumFilter.richContrast: FilterParams(
    contrast: 0.42,
    lift: -0.015,
    saturation: 1.06,
    vibrance: 0.08,
    skinProtect: 0.7,
  ),
  PremiumFilter.warmGold: FilterParams(
    exposure: 0.03,
    contrast: 0.12,
    temperature: 0.30,
    tint: -0.03,
    saturation: 1.04,
    highlights: [0.035, 0.022, -0.02],
    shadows: [0.012, 0.004, -0.01],
    skinProtect: 0.55,
  ),
  PremiumFilter.coolClean: FilterParams(
    exposure: 0.08,
    contrast: 0.12,
    temperature: -0.24,
    saturation: 0.98,
    vibrance: 0.06,
    highlights: [0, 0.01, 0.02],
    skinProtect: 0.8,
  ),
  PremiumFilter.cinematic: FilterParams(
    contrast: 0.28,
    whitePoint: 0.97,
    saturation: 0.95,
    shadows: [-0.035, 0.012, 0.045],
    highlights: [0.045, 0.018, -0.035],
    skinProtect: 0.7,
  ),
  PremiumFilter.film: FilterParams(
    contrast: -0.14,
    lift: 0.05,
    whitePoint: 0.96,
    temperature: 0.06,
    tint: 0.05,
    saturation: 0.88,
    shadows: [0, 0.012, 0.008],
    grain: 0.035,
    skinProtect: 0.6,
  ),
  PremiumFilter.moodyDark: FilterParams(
    exposure: -0.32,
    contrast: 0.34,
    saturation: 0.74,
    shadows: [-0.01, 0.0, 0.02],
    skinProtect: 0.6,
  ),
  PremiumFilter.softPastel: FilterParams(
    exposure: 0.16,
    contrast: -0.32,
    lift: 0.06,
    whitePoint: 0.98,
    saturation: 0.78,
    highlights: [0.02, 0.0, 0.012],
    skinProtect: 0.65,
  ),
  PremiumFilter.brightAiry: FilterParams(
    exposure: 0.30,
    contrast: -0.10,
    lift: 0.035,
    temperature: -0.05,
    saturation: 0.95,
    vibrance: 0.05,
    skinProtect: 0.7,
  ),
  PremiumFilter.proBw: FilterParams(
    contrast: 0.32,
    mono: true,
    monoMix: [0.34, 0.56, 0.10],
    grain: 0.012,
    skinProtect: 0,
  ),
};

double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

double _curve(double x, double c) {
  if (c >= 0) {
    final s = x * x * (3 - 2 * x); // smoothstep S-curve
    return x + (s - x) * c;
  }
  return x + ((0.5 + (x - 0.5) * 0.7) - x) * (-c);
}

/// Skin likelihood from YCbCr (0..1, soft edges). Pure → tested.
double skinWeight(double r, double g, double b) {
  final y = 0.299 * r + 0.587 * g + 0.114 * b;
  final cb = 0.5 - 0.168736 * r - 0.331264 * g + 0.5 * b;
  final cr = 0.5 + 0.5 * r - 0.418688 * g - 0.081312 * b;
  if (y < 0.12 || y > 0.97) return 0;
  double band(double v, double lo, double hi, double soft) {
    if (v < lo - soft || v > hi + soft) return 0;
    if (v < lo) return (v - (lo - soft)) / soft;
    if (v > hi) return ((hi + soft) - v) / soft;
    return 1;
  }

  // Cb 77..127, Cr 133..173 (8-bit) → normalised.
  return band(cb, 0.302, 0.498, 0.03) * band(cr, 0.522, 0.678, 0.03);
}

/// The full look on one pixel (0..1 RGB), WITHOUT strength / grain.
/// Single source of truth for stills and the live matrix fit.
(double, double, double) filterPixel(
  FilterParams f,
  double r,
  double g,
  double b, {
  bool skin = true,
}) {
  final r0 = r, g0 = g, b0 = b;
  final e = math.pow(2, f.exposure).toDouble();
  r *= e;
  g *= e;
  b *= e;
  r *= 1 + f.temperature * 0.12;
  b *= 1 - f.temperature * 0.12;
  g *= 1 + f.tint * 0.06;
  // Tone.
  double tone(double v) {
    v = _curve(_clamp01(v), f.contrast);
    v = f.lift + v * (1 - f.lift);
    return v * f.whitePoint;
  }

  r = tone(r);
  g = tone(g);
  b = tone(b);
  var l = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  if (f.mono) {
    final m = f.monoMix;
    final v = _clamp01(m[0] * r + m[1] * g + m[2] * b);
    return (v, v, v);
  }
  // Saturation + vibrance.
  final mx = math.max(r, math.max(g, b)), mn = math.min(r, math.min(g, b));
  final sat = mx - mn;
  final k = f.saturation * (1 + f.vibrance * (1 - _clamp01(sat * 1.5)));
  r = l + (r - l) * k;
  g = l + (g - l) * k;
  b = l + (b - l) * k;
  // Split toning.
  final ws = (1 - l) * (1 - l), wh = l * l;
  r += f.shadows[0] * ws + f.highlights[0] * wh;
  g += f.shadows[1] * ws + f.highlights[1] * wh;
  b += f.shadows[2] * ws + f.highlights[2] * wh;
  // Skin-aware: keep the original chroma on skin, take only the new tone.
  if (skin && f.skinProtect > 0) {
    final w = skinWeight(r0, g0, b0) * f.skinProtect;
    if (w > 0) {
      l = 0.2126 * r + 0.7152 * g + 0.0722 * b;
      final l0 = 0.2126 * r0 + 0.7152 * g0 + 0.0722 * b0;
      final sr = l + (r0 - l0), sg = l + (g0 - l0), sb = l + (b0 - l0);
      r += (sr - r) * w;
      g += (sg - g) * w;
      b += (sb - b) * w;
    }
  }
  return (_clamp01(r), _clamp01(g), _clamp01(b));
}

/// Look at [strength] (0..1): linear blend with the original. Pure.
(double, double, double) applyFilterRgb(
  PremiumFilter filter,
  double r,
  double g,
  double b, {
  double strength = 1,
  bool skin = true,
}) {
  if (filter.isOriginal || strength <= 0) return (r, g, b);
  final s = strength.clamp(0.0, 1.0);
  final (fr, fg, fb) = filterPixel(filter.params, r, g, b, skin: skin);
  return (r + (fr - r) * s, g + (fg - g) * s, b + (fb - b) * s);
}

/// Live-preview 4×5 colour matrix (Flutter 0..255 domain), least-squares
/// fitted to [applyFilterRgb] over a colour grid. Null = no filter.
List<double>? premiumPreviewMatrix(PremiumFilter filter, double strength) {
  if (filter.isOriginal || strength <= 0) return null;
  // Normal equations for out = M·[r g b 1] (per output channel).
  final ata = List.generate(4, (_) => List<double>.filled(4, 0));
  final atb = List.generate(3, (_) => List<double>.filled(4, 0));
  const steps = 7;
  for (var i = 0; i < steps; i++) {
    for (var j = 0; j < steps; j++) {
      for (var k = 0; k < steps; k++) {
        final r = i / (steps - 1), g = j / (steps - 1), b = k / (steps - 1);
        final (orr, og, ob) = applyFilterRgb(
          filter,
          r,
          g,
          b,
          strength: strength,
          skin: false, // the preview can't mask skin per pixel
        );
        final x = [r, g, b, 1.0];
        for (var a = 0; a < 4; a++) {
          for (var c = 0; c < 4; c++) {
            ata[a][c] += x[a] * x[c];
          }
          atb[0][a] += x[a] * orr;
          atb[1][a] += x[a] * og;
          atb[2][a] += x[a] * ob;
        }
      }
    }
  }
  final rows = [for (var ch = 0; ch < 3; ch++) _solve4(ata, atb[ch])];
  return [
    for (var ch = 0; ch < 3; ch++) ...[
      rows[ch][0],
      rows[ch][1],
      rows[ch][2],
      0,
      rows[ch][3] * 255,
    ],
    0,
    0,
    0,
    1,
    0,
  ];
}

List<double> _solve4(List<List<double>> a0, List<double> b0) {
  final a = [
    for (final r in a0) [...r],
  ];
  final b = [...b0];
  for (var c = 0; c < 4; c++) {
    var piv = c;
    for (var r = c + 1; r < 4; r++) {
      if (a[r][c].abs() > a[piv][c].abs()) piv = r;
    }
    final tr = a[c];
    a[c] = a[piv];
    a[piv] = tr;
    final tb = b[c];
    b[c] = b[piv];
    b[piv] = tb;
    final d = a[c][c];
    if (d.abs() < 1e-12) continue;
    for (var r = 0; r < 4; r++) {
      if (r == c) continue;
      final f = a[r][c] / d;
      for (var k = c; k < 4; k++) {
        a[r][k] -= f * a[c][k];
      }
      b[r] -= f * b[c];
    }
  }
  return [
    for (var i = 0; i < 4; i++) a[i][i].abs() < 1e-12 ? 0 : b[i] / a[i][i],
  ];
}

/// Max side of the NORMAL on-device final.
const int kFilterMaxSide = 3000;

/// Applies [filter] to [source] (EXIF baked, ≤ [kFilterMaxSide]) in a
/// background isolate → new JPEG in [outDir]. NORMAL mode final.
Future<File> applyPremiumFilter(
  File source,
  PremiumFilter filter, {
  required double strength,
  required String outDir,
}) async {
  if (filter.isOriginal || strength <= 0) return source;
  final path = await Isolate.run(
    () => _applySync(source.path, filter, strength, outDir),
  );
  return File(path);
}

String _applySync(
  String path,
  PremiumFilter filter,
  double strength,
  String outDir,
) {
  var image = img.decodeImage(File(path).readAsBytesSync());
  if (image == null) throw StateError('Could not decode image');
  image = img.bakeOrientation(image);
  if (image.width > kFilterMaxSide || image.height > kFilterMaxSide) {
    image = img.copyResize(
      image,
      width: image.width >= image.height ? kFilterMaxSide : null,
      height: image.height > image.width ? kFilterMaxSide : null,
      interpolation: img.Interpolation.average,
    );
  }
  final grain = filter.params.grain * strength;
  var seed = 0x9E3779B9;
  for (final px in image) {
    var (r, g, b) = applyFilterRgb(
      filter,
      px.r / 255,
      px.g / 255,
      px.b / 255,
      strength: strength,
    );
    if (grain > 0) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      final n = ((seed >> 8) / 0x7fffff - 0.5) * 2 * grain;
      r += n;
      g += n;
      b += n;
    }
    px
      ..r = (_clamp01(r) * 255).round()
      ..g = (_clamp01(g) * 255).round()
      ..b = (_clamp01(b) * 255).round();
  }
  image.exif.imageIfd.orientation = null;
  final out = p.join(
    outDir,
    'ai_camera_${filter.id}_${DateTime.now().microsecondsSinceEpoch}.jpg',
  );
  File(out).writeAsBytesSync(img.encodeJpg(image, quality: 93), flush: true);
  return out;
}

/// Pinned favourite filter (auto-applied when the camera opens).
class PinnedFilter {
  const PinnedFilter(this.filter, this.strength);
  final PremiumFilter filter;
  final double strength;

  static const prefsKey = 'pinned_filter_v11';

  static Future<PinnedFilter?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw == null || raw.isEmpty) return null;
      final parts = raw.split('|');
      final f = PremiumFilter.fromId(parts.first);
      if (f.isOriginal) return null;
      final s = parts.length > 1 ? double.tryParse(parts[1]) ?? 1.0 : 1.0;
      return PinnedFilter(f, s.clamp(0.0, 1.0));
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(PinnedFilter? pin) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (pin == null || pin.filter.isOriginal) {
        await prefs.remove(prefsKey);
      } else {
        await prefs.setString(
          prefsKey,
          '${pin.filter.id}|${pin.strength.toStringAsFixed(2)}',
        );
      }
    } catch (_) {}
  }
}
