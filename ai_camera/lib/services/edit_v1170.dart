import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';

import 'tone.dart';

/// v11.70 free on-device editor maths (Adjust · Retouch · Skin Tone). Pure
/// Dart on RGBA bytes so the live preview (small proxy) and the saved file
/// (full resolution) use exactly the same code. No AI, no credits.
///
/// Radii are relative to the image / face size, so a 1280 px proxy and a
/// 12 MP photo look the same. Face geometry is normalised (0..1) in the
/// upright image.

double _c1(Object? v) {
  final d = v is num ? v.toDouble() : 0.0;
  return d.isFinite ? d.clamp(-1.0, 1.0) : 0.0;
}

double _c01(Object? v) {
  final d = v is num ? v.toDouble() : 0.0;
  return d.isFinite ? d.clamp(0.0, 1.0) : 0.0;
}

// ---------------------------------------------------------------------------
// Adjust
// ---------------------------------------------------------------------------

/// One Adjust slider (id, label, range).
class AdjustSlider {
  const AdjustSlider(this.id, this.label, {this.min = -1, this.max = 1});
  final String id;
  final String label;
  final double min;
  final double max;
}

/// The 8 Adjust sliders, in display order.
const List<AdjustSlider> kAdjustSliders = [
  AdjustSlider('brightness', 'Brightness'),
  AdjustSlider('contrast', 'Contrast'),
  AdjustSlider('shadows', 'Shadows'),
  AdjustSlider('highlights', 'Highlights'),
  AdjustSlider('saturation', 'Saturation'),
  AdjustSlider('warmth', 'Warmth'),
  AdjustSlider('sharpness', 'Sharpness', min: 0),
  AdjustSlider('definition', 'Definition'),
];

/// Adjust slider values. −1..1 each (0 = unchanged); sharpness 0..1.
@immutable
class AdjustParams {
  const AdjustParams({
    this.brightness = 0,
    this.contrast = 0,
    this.shadows = 0,
    this.highlights = 0,
    this.saturation = 0,
    this.warmth = 0,
    this.sharpness = 0,
    this.definition = 0,
  });

  final double brightness;
  final double contrast;
  final double shadows;
  final double highlights;
  final double saturation;
  final double warmth;
  final double sharpness;

  /// Clarity (local mid-tone contrast). Negative = softer.
  final double definition;

  static const zero = AdjustParams();

  double value(String id) => switch (id) {
    'brightness' => brightness,
    'contrast' => contrast,
    'shadows' => shadows,
    'highlights' => highlights,
    'saturation' => saturation,
    'warmth' => warmth,
    'sharpness' => sharpness,
    'definition' => definition,
    _ => 0,
  };

  AdjustParams withValue(String id, double v) {
    final m = toJson()..[id] = v;
    return AdjustParams.fromJson(m);
  }

  Map<String, double> toJson() => {
    'brightness': brightness,
    'contrast': contrast,
    'shadows': shadows,
    'highlights': highlights,
    'saturation': saturation,
    'warmth': warmth,
    'sharpness': sharpness,
    'definition': definition,
  };

  factory AdjustParams.fromJson(Map<String, dynamic> j) => AdjustParams(
    brightness: _c1(j['brightness']),
    contrast: _c1(j['contrast']),
    shadows: _c1(j['shadows']),
    highlights: _c1(j['highlights']),
    saturation: _c1(j['saturation']),
    warmth: _c1(j['warmth']),
    sharpness: _c01(j['sharpness']),
    definition: _c1(j['definition']),
  );

  bool get isNeutral => toJson().values.every((v) => v.abs() < 1e-3);

  /// The colour / tone part (shared with the v11.69 tone curve).
  ToneParams get tone => ToneParams(
    exposure: brightness,
    contrast: contrast,
    highlights: highlights,
    shadows: shadows,
    warmth: warmth,
    saturation: saturation,
  );

  String get key => toJson().values.map((v) => v.toStringAsFixed(2)).join(',');

  @override
  bool operator ==(Object other) => other is AdjustParams && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// A preset = a set of Adjust slider values (not a colour filter).
@immutable
class AdjustPreset {
  const AdjustPreset(this.name, this.params, {this.builtIn = false});
  final String name;
  final AdjustParams params;
  final bool builtIn;

  Map<String, dynamic> toJson() => {'name': name, 'params': params.toJson()};

  static AdjustPreset? fromJson(Object? j) {
    if (j is! Map) return null;
    final n = j['name'];
    final p = j['params'];
    if (n is! String || n.trim().isEmpty || p is! Map) return null;
    return AdjustPreset(
      n.trim(),
      AdjustParams.fromJson(p.cast<String, dynamic>()),
    );
  }
}

/// Built-in presets: Clear, Bright, Punchy, Soft.
const List<AdjustPreset> kAdjustPresets = [
  AdjustPreset(
    'Clear',
    AdjustParams(
      contrast: 0.08,
      shadows: 0.12,
      highlights: -0.12,
      sharpness: 0.25,
      definition: 0.35,
    ),
    builtIn: true,
  ),
  AdjustPreset(
    'Bright',
    AdjustParams(
      brightness: 0.25,
      shadows: 0.20,
      highlights: -0.10,
      saturation: 0.05,
    ),
    builtIn: true,
  ),
  AdjustPreset(
    'Punchy',
    AdjustParams(
      contrast: 0.25,
      saturation: 0.30,
      warmth: 0.04,
      sharpness: 0.15,
      definition: 0.20,
    ),
    builtIn: true,
  ),
  AdjustPreset(
    'Soft',
    AdjustParams(
      contrast: -0.15,
      shadows: 0.10,
      highlights: -0.15,
      saturation: -0.05,
      warmth: 0.05,
      definition: -0.30,
    ),
    builtIn: true,
  ),
];

// ---------------------------------------------------------------------------
// Retouch / faces
// ---------------------------------------------------------------------------

/// A tapped blemish: centre (0..1 of width / height) and radius (0..1 of
/// the long side).
@immutable
class BlemishSpot {
  const BlemishSpot(this.x, this.y, this.r);
  final double x;
  final double y;
  final double r;

  List<double> toJson() => [x, y, r];

  static BlemishSpot? fromJson(Object? j) {
    if (j is! List || j.length < 3) return null;
    final v = j.map((e) => e is num ? e.toDouble() : double.nan).toList();
    if (v.any((e) => !e.isFinite)) return null;
    return BlemishSpot(
      v[0].clamp(0.0, 1.0),
      v[1].clamp(0.0, 1.0),
      v[2].clamp(0.002, 0.08),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BlemishSpot && other.x == x && other.y == y && other.r == r;

  @override
  int get hashCode => Object.hash(x, y, r);
}

/// Retouch amounts 0..1 (moderate by design) + tapped blemish spots.
@immutable
class RetouchParams {
  const RetouchParams({
    this.smooth = 0,
    this.faceLight = 0,
    this.eyes = 0,
    this.teeth = 0,
    this.underEye = 0,
    this.spots = const [],
  });

  /// Smooth skin (pores kept: only low / mid frequencies are evened out).
  final double smooth;

  /// Brighten face.
  final double faceLight;

  /// Brighten + sharpen eyes.
  final double eyes;

  /// Teeth whiten.
  final double teeth;

  /// Under-eye dark circles.
  final double underEye;
  final List<BlemishSpot> spots;

  static const zero = RetouchParams();

  /// One-tap Auto Retouch (moderate; no face reshaping).
  static const auto = RetouchParams(
    smooth: 0.45,
    faceLight: 0.25,
    eyes: 0.35,
    teeth: 0.30,
    underEye: 0.40,
  );

  bool get faceNeutral =>
      smooth < 1e-3 &&
      faceLight < 1e-3 &&
      eyes < 1e-3 &&
      teeth < 1e-3 &&
      underEye < 1e-3;

  bool get isNeutral => faceNeutral && spots.isEmpty;

  RetouchParams copyWith({
    double? smooth,
    double? faceLight,
    double? eyes,
    double? teeth,
    double? underEye,
    List<BlemishSpot>? spots,
  }) => RetouchParams(
    smooth: smooth ?? this.smooth,
    faceLight: faceLight ?? this.faceLight,
    eyes: eyes ?? this.eyes,
    teeth: teeth ?? this.teeth,
    underEye: underEye ?? this.underEye,
    spots: spots ?? this.spots,
  );

  Map<String, dynamic> toJson() => {
    'smooth': smooth,
    'faceLight': faceLight,
    'eyes': eyes,
    'teeth': teeth,
    'underEye': underEye,
    'spots': [for (final s in spots) s.toJson()],
  };

  factory RetouchParams.fromJson(Map<String, dynamic> j) => RetouchParams(
    smooth: _c01(j['smooth']),
    faceLight: _c01(j['faceLight']),
    eyes: _c01(j['eyes']),
    teeth: _c01(j['teeth']),
    underEye: _c01(j['underEye']),
    spots: [
      for (final s in (j['spots'] as List?) ?? const [])
        ?BlemishSpot.fromJson(s),
    ],
  );
}

/// One detected face (ML Kit), normalised to the upright image (0..1).
/// Contours exist only for the most prominent face; the others have only
/// [box] (they get the colour-based skin mask inside an ellipse).
@immutable
class FaceGeom {
  const FaceGeom({
    required this.box,
    this.oval = const [],
    this.leftEye = const [],
    this.rightEye = const [],
    this.leftBrow = const [],
    this.rightBrow = const [],
    this.lipsOuter = const [],
    this.mouthInner = const [],
  });

  final Rect box;
  final List<Offset> oval;
  final List<Offset> leftEye;
  final List<Offset> rightEye;
  final List<Offset> leftBrow;
  final List<Offset> rightBrow;

  /// Outer lip outline (upper top + lower bottom).
  final List<Offset> lipsOuter;

  /// Mouth opening (upper lip bottom + lower lip top) → teeth.
  final List<Offset> mouthInner;

  bool get hasContours => oval.length >= 8;

  List<List<Offset>> get eyes => [
    if (leftEye.length >= 4) leftEye,
    if (rightEye.length >= 4) rightEye,
  ];

  static List<double> _pts(List<Offset> l) => [
    for (final o in l) ...[o.dx, o.dy],
  ];

  static List<Offset> _unpts(Object? j) {
    if (j is! List) return const [];
    final out = <Offset>[];
    for (var i = 0; i + 1 < j.length; i += 2) {
      final x = j[i], y = j[i + 1];
      if (x is num && y is num) out.add(Offset(x.toDouble(), y.toDouble()));
    }
    return out;
  }

  Map<String, dynamic> toJson() => {
    'box': [box.left, box.top, box.width, box.height],
    'oval': _pts(oval),
    'leftEye': _pts(leftEye),
    'rightEye': _pts(rightEye),
    'leftBrow': _pts(leftBrow),
    'rightBrow': _pts(rightBrow),
    'lipsOuter': _pts(lipsOuter),
    'mouthInner': _pts(mouthInner),
  };

  static FaceGeom? fromJson(Object? j) {
    if (j is! Map) return null;
    final b = j['box'];
    if (b is! List || b.length < 4 || b.any((e) => e is! num)) return null;
    final r = Rect.fromLTWH(
      (b[0] as num).toDouble(),
      (b[1] as num).toDouble(),
      (b[2] as num).toDouble(),
      (b[3] as num).toDouble(),
    );
    if (r.width <= 0 || r.height <= 0) return null;
    return FaceGeom(
      box: r,
      oval: _unpts(j['oval']),
      leftEye: _unpts(j['leftEye']),
      rightEye: _unpts(j['rightEye']),
      leftBrow: _unpts(j['leftBrow']),
      rightBrow: _unpts(j['rightBrow']),
      lipsOuter: _unpts(j['lipsOuter']),
      mouthInner: _unpts(j['mouthInner']),
    );
  }
}

// ---------------------------------------------------------------------------
// Recipe
// ---------------------------------------------------------------------------

/// Everything the editor applies. Geometry (rotate / crop) is applied last,
/// so face coordinates always refer to the uncropped upright photo.
@immutable
class EditRecipe {
  const EditRecipe({
    this.quarterTurns = 0,
    this.crop = const Rect.fromLTWH(0, 0, 1, 1),
    this.adjust = AdjustParams.zero,
    this.retouch = RetouchParams.zero,
    this.skinTone = 0,
  });

  final int quarterTurns;
  final Rect crop;
  final AdjustParams adjust;
  final RetouchParams retouch;

  /// −1 (darker) .. 1 (lighter); about 1–2 shades at the ends.
  final double skinTone;

  bool get hasGeometry =>
      quarterTurns % 4 != 0 || crop != const Rect.fromLTWH(0, 0, 1, 1);

  bool get hasPixels =>
      !adjust.isNeutral || !retouch.isNeutral || skinTone.abs() > 1e-3;

  bool get isIdentity => !hasGeometry && !hasPixels;

  EditRecipe copyWith({
    int? quarterTurns,
    Rect? crop,
    AdjustParams? adjust,
    RetouchParams? retouch,
    double? skinTone,
  }) => EditRecipe(
    quarterTurns: quarterTurns ?? this.quarterTurns,
    crop: crop ?? this.crop,
    adjust: adjust ?? this.adjust,
    retouch: retouch ?? this.retouch,
    skinTone: skinTone ?? this.skinTone,
  );

  Map<String, dynamic> toJson() => {
    'quarterTurns': quarterTurns,
    'crop': [crop.left, crop.top, crop.width, crop.height],
    'adjust': adjust.toJson(),
    'retouch': retouch.toJson(),
    'skinTone': skinTone,
  };

  factory EditRecipe.fromJson(Map<String, dynamic> j) {
    final c = j['crop'];
    var crop = const Rect.fromLTWH(0, 0, 1, 1);
    if (c is List && c.length == 4 && c.every((e) => e is num)) {
      crop = Rect.fromLTWH(
        (c[0] as num).toDouble(),
        (c[1] as num).toDouble(),
        (c[2] as num).toDouble(),
        (c[3] as num).toDouble(),
      );
    }
    return EditRecipe(
      quarterTurns: ((j['quarterTurns'] as num?)?.toInt() ?? 0) % 4,
      crop: crop,
      adjust: AdjustParams.fromJson(
        ((j['adjust'] as Map?) ?? const {}).cast<String, dynamic>(),
      ),
      retouch: RetouchParams.fromJson(
        ((j['retouch'] as Map?) ?? const {}).cast<String, dynamic>(),
      ),
      skinTone: _c1(j['skinTone']),
    );
  }

  /// Pixel part only (no geometry) — the preview cache key.
  String get pixelKey => [
    adjust.key,
    retouch.toJson().toString(),
    skinTone.toStringAsFixed(2),
  ].join('|');
}

/// Skin Tone strength at ±1: gamma 2^∓[kSkinToneGamma] → about 1–2 shades.
const double kSkinToneGamma = 0.28;

/// Default blemish radius (0..1 of the long side) — from the face width
/// when a face is known.
double blemishRadiusFor(List<FaceGeom> faces, double imageAspect) {
  if (faces.isEmpty) return 0.012;
  final f = faces.first.box;
  // box.width is a fraction of the width; convert to the long side.
  final longIsW = imageAspect >= 1;
  final fw = longIsW ? f.width : f.width * imageAspect;
  return (fw * 0.035).clamp(0.004, 0.03);
}

// ---------------------------------------------------------------------------
// Rendering (pure, in place on RGBA bytes)
// ---------------------------------------------------------------------------

/// Applies the pixel part of [r] (retouch → skin tone → adjust) to [px]
/// (RGBA, [w]×[h]) in place. Geometry is not applied here.
void renderEditPixels(
  Uint8List px,
  int w,
  int h,
  EditRecipe r, {
  List<FaceGeom> faces = const [],
}) {
  if (w <= 0 || h <= 0 || px.length < w * h * 4) return;
  final rt = r.retouch;
  for (final s in rt.spots) {
    _healSpot(px, w, h, s);
  }
  if (!rt.faceNeutral) {
    for (final f in faces) {
      _retouchFace(px, w, h, f, rt);
    }
  }
  if (r.skinTone.abs() > 1e-3) {
    applySkinTone(px, w, h, r.skinTone, faces: faces);
  }
  final a = r.adjust;
  if (!a.tone.isNeutral) applyToneRgbaInPlace(px, a.tone);
  final long = math.max(w, h);
  if (a.definition.abs() > 1e-3) {
    final rad = math.max(2, (long * 0.012).round());
    _localContrast(px, w, h, rad, a.definition * 0.55, midWeight: true);
  }
  if (a.sharpness > 1e-3) {
    final rad = math.max(1, (long / 1600).round());
    _localContrast(px, w, h, rad, a.sharpness * 1.1, midWeight: false);
  }
}

// ---- small helpers ---------------------------------------------------------

int _clamp255(double v) => v <= 0 ? 0 : (v >= 255 ? 255 : v.round());

double _smooth(double e0, double e1, double x) {
  final t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// Separable box blur (running sums, edge-normalised) of a float plane.
Float32List boxBlurPlane(Float32List src, int w, int h, int r) {
  if (r <= 0) return Float32List.fromList(src);
  final tmp = Float32List(w * h);
  final out = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    var sum = 0.0;
    var n = 0;
    for (var x = 0; x <= math.min(r, w - 1); x++) {
      sum += src[row + x];
      n++;
    }
    for (var x = 0; x < w; x++) {
      tmp[row + x] = sum / n;
      final add = x + r + 1, rem = x - r;
      if (add < w) {
        sum += src[row + add];
        n++;
      }
      if (rem >= 0) {
        sum -= src[row + rem];
        n--;
      }
    }
  }
  for (var x = 0; x < w; x++) {
    var sum = 0.0;
    var n = 0;
    for (var y = 0; y <= math.min(r, h - 1); y++) {
      sum += tmp[y * w + x];
      n++;
    }
    for (var y = 0; y < h; y++) {
      out[y * w + x] = sum / n;
      final add = y + r + 1, rem = y - r;
      if (add < h) {
        sum += tmp[add * w + x];
        n++;
      }
      if (rem >= 0) {
        sum -= tmp[rem * w + x];
        n--;
      }
    }
  }
  return out;
}

/// Same box blur on a byte plane (big full-resolution planes: 1 byte/px).
Uint8List _boxBlurU8(Uint8List src, int w, int h, int r) {
  final tmp = Uint8List(w * h);
  final out = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    var sum = 0, n = 0;
    for (var x = 0; x <= math.min(r, w - 1); x++) {
      sum += src[row + x];
      n++;
    }
    for (var x = 0; x < w; x++) {
      tmp[row + x] = (sum + (n >> 1)) ~/ n;
      final add = x + r + 1, rem = x - r;
      if (add < w) {
        sum += src[row + add];
        n++;
      }
      if (rem >= 0) {
        sum -= src[row + rem];
        n--;
      }
    }
  }
  for (var x = 0; x < w; x++) {
    var sum = 0, n = 0;
    for (var y = 0; y <= math.min(r, h - 1); y++) {
      sum += tmp[y * w + x];
      n++;
    }
    for (var y = 0; y < h; y++) {
      out[y * w + x] = (sum + (n >> 1)) ~/ n;
      final add = y + r + 1, rem = y - r;
      if (add < h) {
        sum += tmp[add * w + x];
        n++;
      }
      if (rem >= 0) {
        sum -= tmp[rem * w + x];
        n--;
      }
    }
  }
  return out;
}

/// Fills [poly] (pixel coords) into [mask] (max with [value]); even-odd.
void fillPolygon(
  Float32List mask,
  int w,
  int h,
  List<Offset> poly, {
  double value = 1,
}) {
  if (poly.length < 3) return;
  var minY = double.infinity, maxY = -double.infinity;
  for (final p in poly) {
    minY = math.min(minY, p.dy);
    maxY = math.max(maxY, p.dy);
  }
  final y0 = math.max(0, minY.floor()), y1 = math.min(h - 1, maxY.ceil());
  final xs = <double>[];
  for (var y = y0; y <= y1; y++) {
    final cy = y + 0.5;
    xs.clear();
    for (var i = 0; i < poly.length; i++) {
      final a = poly[i], b = poly[(i + 1) % poly.length];
      if ((a.dy <= cy && b.dy > cy) || (b.dy <= cy && a.dy > cy)) {
        xs.add(a.dx + (cy - a.dy) / (b.dy - a.dy) * (b.dx - a.dx));
      }
    }
    xs.sort();
    for (var k = 0; k + 1 < xs.length; k += 2) {
      final xa = math.max(0, (xs[k] - 0.5).ceil());
      final xb = math.min(w - 1, (xs[k + 1] - 0.5).floor());
      for (var x = xa; x <= xb; x++) {
        final i = y * w + x;
        if (mask[i] < value) mask[i] = value;
      }
    }
  }
}

/// Soft ellipse (1 inside, feathered over the outer 30 %) into [mask] (max).
void fillEllipse(
  Float32List mask,
  int w,
  int h,
  double cx,
  double cy,
  double rx,
  double ry, {
  double value = 1,
}) {
  if (rx <= 0 || ry <= 0) return;
  final x0 = math.max(0, (cx - rx).floor()),
      x1 = math.min(w - 1, (cx + rx).ceil());
  final y0 = math.max(0, (cy - ry).floor()),
      y1 = math.min(h - 1, (cy + ry).ceil());
  for (var y = y0; y <= y1; y++) {
    final dy = (y + 0.5 - cy) / ry;
    for (var x = x0; x <= x1; x++) {
      final dx = (x + 0.5 - cx) / rx;
      final d = math.sqrt(dx * dx + dy * dy);
      if (d >= 1) continue;
      final v = value * (1 - _smooth(0.7, 1.0, d));
      final i = y * w + x;
      if (mask[i] < v) mask[i] = v;
    }
  }
}

double _sample(Float32List p, int w, int h, double x, double y) {
  final fx = x.clamp(0.0, w - 1.0), fy = y.clamp(0.0, h - 1.0);
  final x0 = fx.floor(), y0 = fy.floor();
  final x1 = math.min(w - 1, x0 + 1), y1 = math.min(h - 1, y0 + 1);
  final tx = fx - x0, ty = fy - y0;
  final a = p[y0 * w + x0], b = p[y0 * w + x1];
  final c = p[y1 * w + x0], d = p[y1 * w + x1];
  return (a + (b - a) * tx) + ((c + (d - c) * tx) - (a + (b - a) * tx)) * ty;
}

/// Self-guided filter (He et al.): edge-preserving smoothing of [p].
Float32List guidedSmooth(Float32List p, int w, int h, int r, double eps) {
  final n = w * h;
  final pp = Float32List(n);
  for (var i = 0; i < n; i++) {
    pp[i] = p[i] * p[i];
  }
  final mI = boxBlurPlane(p, w, h, r);
  final mII = boxBlurPlane(pp, w, h, r);
  final a = Float32List(n), b = Float32List(n);
  for (var i = 0; i < n; i++) {
    final v = math.max(0.0, mII[i] - mI[i] * mI[i]);
    final ai = v / (v + eps);
    a[i] = ai;
    b[i] = mI[i] - ai * mI[i];
  }
  final ma = boxBlurPlane(a, w, h, r), mb = boxBlurPlane(b, w, h, r);
  final q = Float32List(n);
  for (var i = 0; i < n; i++) {
    q[i] = ma[i] * p[i] + mb[i];
  }
  return q;
}

/// Unsharp mask / local contrast on the luma (added equally to R, G, B, so
/// colours don't shift). [midWeight] = clarity (less in deep shadows /
/// bright highlights → no halos at the extremes).
void _localContrast(
  Uint8List px,
  int w,
  int h,
  int radius,
  double amount, {
  required bool midWeight,
}) {
  final n = w * h;
  final l = Uint8List(n);
  for (var i = 0, j = 0; i < n; i++, j += 4) {
    l[i] = (px[j] * 54 + px[j + 1] * 183 + px[j + 2] * 19) >> 8;
  }
  var b = _boxBlurU8(l, w, h, radius);
  if (midWeight) b = _boxBlurU8(b, w, h, radius);
  for (var i = 0, j = 0; i < n; i++, j += 4) {
    final li = l[i];
    var d = (li - b[i]) * amount;
    if (midWeight) d *= 1 - ((li - 128).abs() / 128) * 0.6;
    if (d.abs() < 0.25) continue;
    px[j] = _clamp255(px[j] + d);
    px[j + 1] = _clamp255(px[j + 1] + d);
    px[j + 2] = _clamp255(px[j + 2] + d);
  }
}

// ---- skin model --------------------------------------------------------------

/// Skin colour model in YCbCr chroma (robust median / MAD of the face).
@immutable
class SkinModel {
  const SkinModel(this.cb, this.cr, this.sb, this.sr, {this.fromFace = true});
  final double cb;
  final double cr;
  final double sb;
  final double sr;
  final bool fromFace;

  /// Generic model when no face was found (weaker, see [applySkinTone]).
  static const generic = SkinModel(108, 152, 9, 9, fromFace: false);

  /// 0..1 skin likelihood of one pixel.
  double prob(int r, int g, int b) {
    final y = 0.299 * r + 0.587 * g + 0.114 * b;
    if (y < 28 || y > 250) return 0;
    final cbv = 128 - 0.168736 * r - 0.331264 * g + 0.5 * b;
    final crv = 128 + 0.5 * r - 0.418688 * g - 0.081312 * b;
    final dx = (cbv - cb) / sb, dy = (crv - cr) / sr;
    final d = math.sqrt(dx * dx + dy * dy);
    final yGate = _smooth(28, 45, y) * (1 - _smooth(235, 250, y));
    return (1 - _smooth(1.8, 3.4, d)) * yGate;
  }
}

double _median(List<double> v) {
  if (v.isEmpty) return 0;
  v.sort();
  return v[v.length ~/ 2];
}

/// Skin model from the faces' inner area (cheeks / forehead / nose).
SkinModel skinModelFor(Uint8List px, int w, int h, List<FaceGeom> faces) {
  final cbs = <double>[], crs = <double>[];
  for (final f in faces) {
    final cx = (f.box.center.dx) * w, cy = (f.box.center.dy) * h;
    final rx = f.box.width * w * 0.30, ry = f.box.height * h * 0.34;
    final step = math.max(1, (math.max(rx, ry) / 40).round());
    for (var y = (cy - ry).floor(); y <= (cy + ry).ceil(); y += step) {
      if (y < 0 || y >= h) continue;
      for (var x = (cx - rx).floor(); x <= (cx + rx).ceil(); x += step) {
        if (x < 0 || x >= w) continue;
        final dx = (x - cx) / rx, dy = (y - cy) / ry;
        if (dx * dx + dy * dy > 1) continue;
        final j = (y * w + x) * 4;
        final r = px[j], g = px[j + 1], b = px[j + 2];
        final yy = 0.299 * r + 0.587 * g + 0.114 * b;
        if (yy < 40 || yy > 245) continue;
        cbs.add(128 - 0.168736 * r - 0.331264 * g + 0.5 * b);
        crs.add(128 + 0.5 * r - 0.418688 * g - 0.081312 * b);
      }
    }
  }
  if (cbs.length < 30) return SkinModel.generic;
  final mcb = _median(List.of(cbs)), mcr = _median(List.of(crs));
  final madB = _median([for (final v in cbs) (v - mcb).abs()]) * 1.4826;
  final madR = _median([for (final v in crs) (v - mcr).abs()]) * 1.4826;
  return SkinModel(mcb, mcr, madB.clamp(3.5, 12.0), madR.clamp(3.5, 12.0));
}

/// Downscaled copy (area average) of RGBA → 3 float planes.
(Float32List, Float32List, Float32List) _downPlanes(
  Uint8List px,
  int w,
  int h,
  int x0,
  int y0,
  int ww,
  int wh,
  int sw,
  int sh,
) {
  final r = Float32List(sw * sh), g = Float32List(sw * sh);
  final b = Float32List(sw * sh);
  final fx = ww / sw, fy = wh / sh;
  for (var sy = 0; sy < sh; sy++) {
    final ya = y0 + (sy * fy).floor();
    final yb = math.max(ya + 1, y0 + ((sy + 1) * fy).floor());
    for (var sx = 0; sx < sw; sx++) {
      final xa = x0 + (sx * fx).floor();
      final xb = math.max(xa + 1, x0 + ((sx + 1) * fx).floor());
      var sr = 0, sg = 0, sb = 0, n = 0;
      final stepY = math.max(1, (yb - ya) ~/ 4);
      final stepX = math.max(1, (xb - xa) ~/ 4);
      for (var y = ya; y < yb && y < h; y += stepY) {
        for (var x = xa; x < xb && x < w; x += stepX) {
          final j = (y * w + x) * 4;
          sr += px[j];
          sg += px[j + 1];
          sb += px[j + 2];
          n++;
        }
      }
      final i = sy * sw + sx;
      if (n == 0) continue;
      r[i] = sr / n;
      g[i] = sg / n;
      b[i] = sb / n;
    }
  }
  return (r, g, b);
}

/// Skin mask of the whole photo at a small size (long side ≤ 384), eyes /
/// brows / lips cut out, feathered. Returns (mask, sw, sh).
(Float32List, int, int) skinMaskSmall(
  Uint8List px,
  int w,
  int h,
  List<FaceGeom> faces,
  SkinModel model,
) {
  final s = math.min(1.0, 384 / math.max(w, h));
  final sw = math.max(1, (w * s).round()), sh = math.max(1, (h * s).round());
  final (r, g, b) = _downPlanes(px, w, h, 0, 0, w, h, sw, sh);
  final m = Float32List(sw * sh);
  for (var i = 0; i < m.length; i++) {
    m[i] = model.prob(r[i].round(), g[i].round(), b[i].round());
  }
  final cut = Float32List(sw * sh);
  for (final f in faces) {
    for (final poly in [...f.eyes, f.leftBrow, f.rightBrow, f.lipsOuter]) {
      if (poly.length < 3) continue;
      fillPolygon(cut, sw, sh, [
        for (final p in poly) Offset(p.dx * sw, p.dy * sh),
      ]);
    }
  }
  final cutB = boxBlurPlane(cut, sw, sh, 1);
  for (var i = 0; i < m.length; i++) {
    m[i] *= 1 - math.min(1.0, cutB[i] * 1.6);
  }
  final fr = math.max(1, (math.max(sw, sh) / 200).round());
  return (boxBlurPlane(boxBlurPlane(m, sw, sh, fr), sw, sh, fr), sw, sh);
}

/// Skin Tone: lighter / darker by a gamma on R, G, B inside the skin mask
/// (shading, pores and detail kept; face and neck use one colour model so
/// they stay consistent). [t] −1..1 → about ±1–2 shades.
void applySkinTone(
  Uint8List px,
  int w,
  int h,
  double t, {
  List<FaceGeom> faces = const [],
}) {
  final tt = t.clamp(-1.0, 1.0);
  if (tt.abs() < 1e-3) return;
  final model = skinModelFor(px, w, h, faces);
  final (m, sw, sh) = skinMaskSmall(px, w, h, faces, model);
  // Without a face the colour-only mask is less sure → weaker.
  final strength = model.fromFace ? 1.0 : 0.6;
  final gamma = math.pow(2, -kSkinToneGamma * tt).toDouble();
  final lut = Float32List(256);
  for (var i = 0; i < 256; i++) {
    lut[i] = math.pow(i / 255, gamma).toDouble() * 255;
  }
  final satK = tt > 0 ? 1 - 0.06 * tt : 1 + 0.03 * -tt;
  final warm = tt < 0 ? 1.5 * -tt : 0.0;
  final fx = sw / w, fy = sh / h;
  for (var y = 0; y < h; y++) {
    final sy = (y + 0.5) * fy - 0.5;
    for (var x = 0; x < w; x++) {
      final k = _sample(m, sw, sh, (x + 0.5) * fx - 0.5, sy) * strength;
      if (k < 0.01) continue;
      final j = (y * w + x) * 4;
      final r0 = px[j], g0 = px[j + 1], b0 = px[j + 2];
      var r = lut[r0], g = lut[g0], b = lut[b0];
      final l = 0.2126 * r + 0.7152 * g + 0.0722 * b;
      r = l + (r - l) * satK + warm;
      g = l + (g - l) * satK;
      b = l + (b - l) * satK - warm;
      px[j] = _clamp255(r0 + (r - r0) * k);
      px[j + 1] = _clamp255(g0 + (g - g0) * k);
      px[j + 2] = _clamp255(b0 + (b - b0) * k);
    }
  }
}

// ---- retouch ---------------------------------------------------------------

/// Low / mid-frequency face work at a small scale (face ≈ 256 px wide):
/// smooth skin (guided filter on a low-passed copy → pores, which live in
/// the higher frequencies, are untouched), brighten face, under-eye. The
/// change is upsampled and added to the full-resolution pixels.
void _retouchFace(Uint8List px, int w, int h, FaceGeom f, RetouchParams rt) {
  final bw = f.box.width * w, bh = f.box.height * h;
  if (bw < 12 || bh < 12) return;
  final x0 = math.max(0, (f.box.left * w - bw * 0.25).floor());
  final x1 = math.min(w, (f.box.right * w + bw * 0.25).ceil());
  final y0 = math.max(0, (f.box.top * h - bh * 0.30).floor());
  final y1 = math.min(h, (f.box.bottom * h + bh * 0.55).ceil());
  final ww = x1 - x0, wh = y1 - y0;
  if (ww < 8 || wh < 8) return;
  final s = math.min(1.0, 256 / bw);
  final sw = math.max(4, (ww * s).round()), sh = math.max(4, (wh * s).round());
  final sx = sw / ww, sy = sh / wh;
  final fw = bw * sx; // face width in small px
  Offset toS(Offset p) => Offset((p.dx * w - x0) * sx, (p.dy * h - y0) * sy);

  final (r, g, b) = _downPlanes(px, w, h, x0, y0, ww, wh, sw, sh);
  final n = sw * sh;
  final model = skinModelFor(px, w, h, [f]);

  // Region: face oval (or box ellipse) + neck.
  final region = Float32List(n);
  final cx = (f.box.center.dx * w - x0) * sx;
  final cy = (f.box.center.dy * h - y0) * sy;
  if (f.hasContours) {
    fillPolygon(region, sw, sh, [for (final p in f.oval) toS(p)]);
  } else {
    fillEllipse(region, sw, sh, cx, cy, fw * 0.5, bh * sy * 0.58);
  }
  final neck = Float32List(n);
  fillEllipse(neck, sw, sh, cx, cy + bh * sy * 0.62, fw * 0.36, bh * sy * 0.42);
  final cut = Float32List(n);
  for (final poly in [...f.eyes, f.leftBrow, f.rightBrow, f.lipsOuter]) {
    if (poly.length >= 3) {
      fillPolygon(cut, sw, sh, [for (final p in poly) toS(p)]);
    }
  }
  final featherR = math.max(1, (fw / 40).round());
  final cutB = boxBlurPlane(cut, sw, sh, featherR);
  final regB = boxBlurPlane(region, sw, sh, featherR);
  final faceMask = Float32List(n), skinMask = Float32List(n);
  for (var i = 0; i < n; i++) {
    final sk = model.prob(r[i].round(), g[i].round(), b[i].round());
    final keep = 1 - math.min(1.0, cutB[i] * 1.6);
    faceMask[i] = regB[i] * keep * (0.35 + 0.65 * sk);
    skinMask[i] = math.max(regB[i], neck[i]) * keep * sk;
  }

  // Low-pass copy (removes the pore-scale band) + its edge-aware smooth.
  final lpR = math.max(1, (fw / 128).round());
  final lr = boxBlurPlane(r, sw, sh, lpR), lg = boxBlurPlane(g, sw, sh, lpR);
  final lb = boxBlurPlane(b, sw, sh, lpR);
  final dr = Float32List(n), dg = Float32List(n), db = Float32List(n);

  if (rt.smooth > 1e-3) {
    final gr = math.max(2, (fw / 30).round());
    const eps = 0.045 * 255 * 0.045 * 255;
    final qr = guidedSmooth(lr, sw, sh, gr, eps);
    final qg = guidedSmooth(lg, sw, sh, gr, eps);
    final qb = guidedSmooth(lb, sw, sh, gr, eps);
    final k = rt.smooth * 0.85;
    for (var i = 0; i < n; i++) {
      final m = skinMask[i] * k;
      if (m < 1e-3) continue;
      dr[i] += (qr[i] - lr[i]) * m;
      dg[i] += (qg[i] - lg[i]) * m;
      db[i] += (qb[i] - lb[i]) * m;
    }
  }

  if (rt.underEye > 1e-3 && f.eyes.isNotEmpty) {
    final ue = Float32List(n);
    final refs = <double>[];
    for (final eye in f.eyes) {
      final pts = [for (final p in eye) toS(p)];
      var ex0 = double.infinity, ex1 = -double.infinity;
      var ey1 = -double.infinity;
      for (final p in pts) {
        ex0 = math.min(ex0, p.dx);
        ex1 = math.max(ex1, p.dx);
        ey1 = math.max(ey1, p.dy);
      }
      final ew = ex1 - ex0;
      if (ew < 3) continue;
      final ecx = (ex0 + ex1) / 2;
      fillEllipse(ue, sw, sh, ecx, ey1 + ew * 0.30, ew * 0.55, ew * 0.27);
      // Cheek reference brightness just below.
      final ry = (ey1 + ew * 0.80).round(), rx0 = (ecx - ew * 0.3).round();
      for (var yy = ry - 1; yy <= ry + 1; yy++) {
        for (var xx = rx0; xx <= rx0 + (ew * 0.6).round(); xx++) {
          if (xx < 0 || yy < 0 || xx >= sw || yy >= sh) continue;
          final i = yy * sw + xx;
          refs.add(0.299 * lr[i] + 0.587 * lg[i] + 0.114 * lb[i]);
        }
      }
    }
    if (refs.isNotEmpty) {
      final ref = _median(refs);
      final k = rt.underEye * 0.8;
      for (var i = 0; i < n; i++) {
        final m = ue[i] * k * (0.3 + 0.7 * math.min(1.0, skinMask[i] * 2));
        if (m < 1e-3) continue;
        final l = 0.299 * lr[i] + 0.587 * lg[i] + 0.114 * lb[i];
        final lift = math.max(0.0, ref - l);
        // Lift the darkness and take a little of its purple / grey cast out.
        dr[i] += lift * m + (l - lr[i]) * 0.12 * m;
        dg[i] += lift * m + (l - lg[i]) * 0.12 * m;
        db[i] += lift * m + (l - lb[i]) * 0.12 * m;
      }
    }
  }

  if (rt.faceLight > 1e-3) {
    final gm = math.pow(2, -0.32 * rt.faceLight).toDouble();
    for (var i = 0; i < n; i++) {
      final m = faceMask[i];
      if (m < 1e-3) continue;
      double up(double v) => math.pow(v / 255, gm).toDouble() * 255 - v;
      dr[i] += up(lr[i]) * m;
      dg[i] += up(lg[i]) * m;
      db[i] += up(lb[i]) * m;
    }
  }

  // Upsample the change into the full-resolution window.
  for (var y = y0; y < y1; y++) {
    final py = (y - y0 + 0.5) * sy - 0.5;
    for (var x = x0; x < x1; x++) {
      final pxs = (x - x0 + 0.5) * sx - 0.5;
      final a = _sample(dr, sw, sh, pxs, py);
      final c = _sample(dg, sw, sh, pxs, py);
      final d = _sample(db, sw, sh, pxs, py);
      if (a.abs() < 0.2 && c.abs() < 0.2 && d.abs() < 0.2) continue;
      final j = (y * w + x) * 4;
      px[j] = _clamp255(px[j] + a);
      px[j + 1] = _clamp255(px[j + 1] + c);
      px[j + 2] = _clamp255(px[j + 2] + d);
    }
  }

  if (rt.eyes > 1e-3) {
    for (final eye in f.eyes) {
      _eye(px, w, h, eye, rt.eyes);
    }
  }
  if (rt.teeth > 1e-3 && f.mouthInner.length >= 6) {
    _teeth(px, w, h, f.mouthInner, rt.teeth);
  }
}

/// Window (full-res pixels) around a normalised polygon, padded by [pad]
/// of its width.
(int, int, int, int, List<Offset>) _window(
  List<Offset> poly,
  int w,
  int h,
  double pad,
) {
  final pts = [for (final p in poly) Offset(p.dx * w, p.dy * h)];
  var a = double.infinity, b = double.infinity;
  var c = -double.infinity, d = -double.infinity;
  for (final p in pts) {
    a = math.min(a, p.dx);
    b = math.min(b, p.dy);
    c = math.max(c, p.dx);
    d = math.max(d, p.dy);
  }
  final pw = (c - a) * pad;
  final x0 = math.max(0, (a - pw).floor()), y0 = math.max(0, (b - pw).floor());
  final x1 = math.min(w, (c + pw).ceil()), y1 = math.min(h, (d + pw).ceil());
  return (x0, y0, x1, y1, [for (final p in pts) Offset(p.dx - x0, p.dy - y0)]);
}

/// Eyes: a little brighter and crisper inside the eye outline.
void _eye(Uint8List px, int w, int h, List<Offset> eye, double amount) {
  final (x0, y0, x1, y1, pts) = _window(eye, w, h, 0.25);
  final ww = x1 - x0, wh = y1 - y0;
  if (ww < 4 || wh < 3) return;
  final mask = Float32List(ww * wh);
  fillPolygon(mask, ww, wh, pts);
  final ew = ww / 1.5;
  final m = boxBlurPlane(mask, ww, wh, math.max(1, (ew / 25).round()));
  final l = Float32List(ww * wh);
  for (var y = 0; y < wh; y++) {
    for (var x = 0; x < ww; x++) {
      final j = ((y0 + y) * w + x0 + x) * 4;
      l[y * ww + x] = 0.299 * px[j] + 0.587 * px[j + 1] + 0.114 * px[j + 2];
    }
  }
  final bl = boxBlurPlane(l, ww, wh, math.max(1, (ew / 40).round()));
  final gm = math.pow(2, -0.22 * amount).toDouble();
  for (var y = 0; y < wh; y++) {
    for (var x = 0; x < ww; x++) {
      final i = y * ww + x;
      final k = m[i];
      if (k < 0.01) continue;
      final j = ((y0 + y) * w + x0 + x) * 4;
      final sharp = (l[i] - bl[i]) * amount * 0.9;
      for (var c = 0; c < 3; c++) {
        final v = px[j + c].toDouble();
        final bright = math.pow(v / 255, gm).toDouble() * 255;
        px[j + c] = _clamp255(v + (bright - v + sharp) * k);
      }
    }
  }
}

/// Teeth: less yellow, a little brighter — only bright, not-red pixels in
/// the mouth opening (gums / tongue / dark mouth untouched).
void _teeth(Uint8List px, int w, int h, List<Offset> mouth, double amount) {
  final (x0, y0, x1, y1, pts) = _window(mouth, w, h, 0.05);
  final ww = x1 - x0, wh = y1 - y0;
  if (ww < 6 || wh < 2) return;
  final mask = Float32List(ww * wh);
  fillPolygon(mask, ww, wh, pts);
  final m = boxBlurPlane(mask, ww, wh, math.max(1, (ww / 40).round()));
  for (var y = 0; y < wh; y++) {
    for (var x = 0; x < ww; x++) {
      final k0 = m[y * ww + x];
      if (k0 < 0.01) continue;
      final j = ((y0 + y) * w + x0 + x) * 4;
      final r = px[j].toDouble(), g = px[j + 1].toDouble();
      final b = px[j + 2].toDouble();
      final yy = 0.299 * r + 0.587 * g + 0.114 * b;
      var cb = 128 - 0.168736 * r - 0.331264 * g + 0.5 * b;
      var cr = 128 + 0.5 * r - 0.418688 * g - 0.081312 * b;
      final k = k0 * _smooth(70, 120, yy) * (1 - _smooth(150, 168, cr));
      if (k < 0.01) continue;
      final a = amount * k;
      if (cb < 128) cb += (128 - cb) * 0.65 * a;
      cr += (128 - cr) * 0.30 * a;
      final y2 = yy + (255 - yy) * 0.12 * a;
      px[j] = _clamp255(y2 + 1.402 * (cr - 128));
      px[j + 1] = _clamp255(y2 - 0.344136 * (cb - 128) - 0.714136 * (cr - 128));
      px[j + 2] = _clamp255(y2 + 1.772 * (cb - 128));
    }
  }
}

/// Blemish heal: the spot is filled from the skin around it (inverse
/// distance from a ring of samples) with the original fine texture kept at
/// half strength, feathered edge.
void _healSpot(Uint8List px, int w, int h, BlemishSpot s) {
  final long = math.max(w, h);
  final rad = s.r * long;
  if (rad < 1.5) return;
  final cx = s.x * w, cy = s.y * h;
  final ring = rad * 1.4;
  final x0 = math.max(0, (cx - ring - 2).floor());
  final x1 = math.min(w, (cx + ring + 2).ceil());
  final y0 = math.max(0, (cy - ring - 2).floor());
  final y1 = math.min(h, (cy + ring + 2).ceil());
  final ww = x1 - x0, wh = y1 - y0;
  if (ww < 3 || wh < 3) return;
  // Ring samples (small patch averages).
  const k = 16;
  final sx = <double>[], sy = <double>[], sc = <List<double>>[];
  final pr = math.max(1, (rad / 5).round());
  for (var i = 0; i < k; i++) {
    final ang = i * 2 * math.pi / k;
    final ax = cx + math.cos(ang) * ring, ay = cy + math.sin(ang) * ring;
    var tr = 0.0, tg = 0.0, tb = 0.0, n = 0;
    for (var yy = (ay - pr).round(); yy <= (ay + pr).round(); yy++) {
      for (var xx = (ax - pr).round(); xx <= (ax + pr).round(); xx++) {
        if (xx < 0 || yy < 0 || xx >= w || yy >= h) continue;
        final j = (yy * w + xx) * 4;
        tr += px[j];
        tg += px[j + 1];
        tb += px[j + 2];
        n++;
      }
    }
    if (n == 0) continue;
    sx.add(ax);
    sy.add(ay);
    sc.add([tr / n, tg / n, tb / n]);
  }
  if (sc.length < 4) return;
  // Local texture = pixel − local mean.
  final planes = List.generate(3, (_) => Float32List(ww * wh));
  for (var y = 0; y < wh; y++) {
    for (var x = 0; x < ww; x++) {
      final j = ((y0 + y) * w + x0 + x) * 4;
      for (var c = 0; c < 3; c++) {
        planes[c][y * ww + x] = px[j + c].toDouble();
      }
    }
  }
  final tr = math.max(1, (rad / 4).round());
  final means = [for (final p in planes) boxBlurPlane(p, ww, wh, tr)];
  for (var y = 0; y < wh; y++) {
    for (var x = 0; x < ww; x++) {
      final gx = x0 + x + 0.5, gy = y0 + y + 0.5;
      final d = math.sqrt((gx - cx) * (gx - cx) + (gy - cy) * (gy - cy));
      if (d > rad * 1.15) continue;
      final alpha = 1 - _smooth(rad * 0.7, rad * 1.15, d);
      var wsum = 0.0;
      final fill = [0.0, 0.0, 0.0];
      for (var i = 0; i < sc.length; i++) {
        final dx = gx - sx[i], dy = gy - sy[i];
        final wt = 1 / (dx * dx + dy * dy + 1);
        wsum += wt;
        for (var c = 0; c < 3; c++) {
          fill[c] += sc[i][c] * wt;
        }
      }
      final i = y * ww + x;
      final j = ((y0 + y) * w + x0 + x) * 4;
      for (var c = 0; c < 3; c++) {
        final tex = planes[c][i] - means[c][i];
        final v = fill[c] / wsum + tex * 0.5;
        px[j + c] = _clamp255(planes[c][i] + (v - planes[c][i]) * alpha);
      }
    }
  }
}
