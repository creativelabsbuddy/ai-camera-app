import '../models/ai_style.dart';
import '../models/style_preset.dart';

/// On-device live approximation of an AI look BEFORE the shutter (no
/// credits). The real AI result is produced after capture.
class LiveLook {
  const LiveLook({this.matrix, this.sampleAsset, this.sampleUrl, this.caption});

  /// Colour grade (Flutter ColorFilter.matrix 4×5).
  final List<double>? matrix;

  /// Big changes (outfit / place / anime): small sample thumbnail corner.
  final String? sampleAsset;
  final String? sampleUrl;

  /// e.g. "Live preview · AI applies after the shutter".
  final String? caption;

  bool get hasThumb => sampleAsset != null || sampleUrl != null;
  bool get isNone => matrix == null && !hasThumb;

  static const none = LiveLook();
}

const kLiveCaption = 'Live preview · AI applies after the shutter';

List<double> _grade({
  double sat = 1,
  double contrast = 1,
  double bright = 0,
  double r = 0,
  double g = 0,
  double b = 0,
  double rGain = 1,
  double bGain = 1,
}) {
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  final c = contrast;
  final off = 128 * (1 - c) + bright;
  double a(double l, bool d) => (d ? (1 - sat) * l + sat : (1 - sat) * l) * c;
  return [
    a(lr, true) * rGain, a(lg, false) * rGain, a(lb, false) * rGain, 0, off + r,
    a(lr, false), a(lg, true), a(lb, false), 0, off + g, //
    a(lr, false) * bGain, a(lg, false) * bGain, a(lb, true) * bGain, 0,
    off + b,
    0, 0, 0, 1, 0,
  ];
}

/// Named grades (also matched by keyword for admin-added styles).
final Map<String, List<double>> kLiveGrades = {
  'cinematic': _grade(sat: 1.05, contrast: 1.15, r: 10, b: 12, rGain: 1.04),
  'film': _grade(sat: 0.88, contrast: 0.92, bright: 8, r: 8, g: 4, b: -6),
  'moody': _grade(sat: 0.75, contrast: 1.18, bright: -10, b: 10),
  'mono': _grade(sat: 0, contrast: 1.12),
  'vintage': _grade(sat: 0.7, contrast: 0.95, bright: 6, r: 18, g: 8, b: -14),
  'warm': _grade(sat: 1.08, bright: 4, r: 14, g: 4, b: -10),
  'cool': _grade(sat: 0.95, r: -8, g: 2, b: 14),
  'studio': _grade(sat: 0.98, contrast: 1.06, bright: 6),
  'wedding': _grade(sat: 1.02, contrast: 0.95, bright: 10, r: 12, b: -6),
  'linkedin': _grade(sat: 0.95, contrast: 1.05, bright: 4),
  'night': _grade(sat: 0.95, contrast: 0.9, bright: 26, b: 8),
  'soft_beauty': _grade(sat: 0.95, contrast: 0.94, bright: 8, r: 6),
};

const _keywords = <String, List<String>>{
  'mono': [
    'b&w',
    'b & w',
    'black and white',
    'black & white',
    'mono',
    'noir',
    'grayscale',
    'greyscale',
  ],
  'cinematic': ['cinematic', 'movie', 'teal'],
  'film': ['film', 'analog', 'kodak', 'polaroid'],
  'moody': ['moody', 'rain', 'dark', 'gloomy', 'storm'],
  'vintage': ['vintage', 'retro', 'sepia', '90s', '80s', '70s'],
  'warm': ['warm', 'golden', 'sunset', 'diwali', 'autumn'],
  'cool': ['cool', 'winter', 'snow', 'ice', 'frost'],
};

/// Keyword grade for free text (style name / custom prompt).
String? gradeKeyFor(String text) {
  final t = text.toLowerCase();
  for (final e in _keywords.entries) {
    for (final k in e.value) {
      if (RegExp('(^|[^a-z])${RegExp.escape(k)}([^a-z]|\$)').hasMatch(t)) {
        return e.key;
      }
    }
  }
  return null;
}

/// Categories whose AI result changes content (outfit / place / art style):
/// colour can't preview them, so a sample thumbnail is shown.
const _bigChangeCategories = {
  'travel',
  'outfit',
  'festival',
  'anime',
  'art',
  'fantasy',
  'place',
  'places',
  'costume',
  'cartoon',
};

/// v11: colour-only live approximation (the flickery live segmentation
/// blur / smoothing were removed).
LiveLook liveLookForFilter(StylePreset f) => LiveLook(
  matrix: kLiveGrades[f.id] ?? kLiveGrades['studio'],
  caption: kLiveCaption,
);

LiveLook liveLookForStyle(AiStyle s) {
  final key = gradeKeyFor('${s.name} ${s.id.replaceAll('_', ' ')}');
  final cat = s.category.toLowerCase();
  final portrait = cat == 'portrait';
  // Content changes (outfit / place / festival / mood scenes) can't be
  // shown with colour alone → sample thumbnail; pure grades (e.g. an
  // admin-added "Film" or "B&W" style) preview live without one.
  final thumb =
      !portrait &&
      (_bigChangeCategories.contains(cat) || cat == 'mood' || key == null);
  return LiveLook(
    matrix: key == null
        ? (portrait ? kLiveGrades['studio'] : null)
        : kLiveGrades[key],
    sampleAsset: thumb ? s.imageAsset : null,
    sampleUrl: thumb && s.imageAsset == null ? s.imageUrl : null,
    caption: kLiveCaption,
  );
}

LiveLook liveLookForCustom(String prompt) {
  final key = gradeKeyFor(prompt);
  return LiveLook(
    matrix: key == null ? null : kLiveGrades[key],
    caption: key == null
        ? 'Your change applies after the shutter'
        : kLiveCaption,
  );
}

/// Composes two 4×5 colour matrices: result = [a] applied after [b].
List<double> composeMatrices(List<double> a, List<double> b) {
  final out = List<double>.filled(20, 0);
  for (var r = 0; r < 4; r++) {
    for (var c = 0; c < 5; c++) {
      var v = 0.0;
      for (var k = 0; k < 4; k++) {
        v += a[r * 5 + k] * b[k * 5 + c];
      }
      if (c == 4) v += a[r * 5 + 4];
      out[r * 5 + c] = v;
    }
  }
  return out;
}

/// Applies a 4×5 matrix to one RGB pixel (0..255) — for tests / parity.
(double, double, double) applyMatrixRgb(
  List<double> m,
  double r,
  double g,
  double b,
) => (
  m[0] * r + m[1] * g + m[2] * b + m[4],
  m[5] * r + m[6] * g + m[7] * b + m[9],
  m[10] * r + m[11] * g + m[12] * b + m[14],
);
