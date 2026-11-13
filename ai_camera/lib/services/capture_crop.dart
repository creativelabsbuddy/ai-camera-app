import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// Integer crop rectangle in upright (EXIF-baked) pixel space.
class CropRect {
  const CropRect(this.x, this.y, this.width, this.height);

  final int x;
  final int y;
  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is CropRect &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() => 'CropRect($x,$y ${width}x$height)';
}

/// The exact region the user saw on screen, in upright pixels of the
/// captured still ([iw]×[ih]).
///
/// 1. Centre-crop to the selected frame ratio ([portraitRatio] = width /
///    height on an upright phone, e.g. 3/4, 9/16, 1), keeping the shot's own
///    orientation (portrait shot → portrait crop). This matches the
///    viewfinder's cover-fit of the preview.
/// 2. Centre-crop that frame by [digitalZoom] (zoom beyond what CameraX
///    gives = preview Transform.scale around the centre).
///
/// Pure function, unit tested. Never upscales; width/height ≥ 1.
CropRect computeCaptureCrop({
  required int iw,
  required int ih,
  required double portraitRatio,
  double digitalZoom = 1.0,
}) {
  if (iw <= 0 || ih <= 0) return const CropRect(0, 0, 1, 1);
  final ratio = (portraitRatio.isFinite && portraitRatio > 0)
      ? portraitRatio
      : 3 / 4;
  final targetLongShort = ratio >= 1 ? ratio : 1 / ratio;
  final zoom = (digitalZoom.isFinite && digitalZoom > 1.001)
      ? digitalZoom
      : 1.0;
  final targetWH = ih >= iw ? 1 / targetLongShort : targetLongShort;

  var cw = iw;
  var ch = ih;
  if (iw / ih > targetWH) {
    cw = (ih * targetWH).round().clamp(1, iw);
  } else {
    ch = (iw / targetWH).round().clamp(1, ih);
  }
  if (zoom > 1.0) {
    cw = (cw / zoom).round().clamp(1, iw);
    ch = (ch / zoom).round().clamp(1, ih);
  }
  return CropRect((iw - cw) ~/ 2, (ih - ch) ~/ 2, cw, ch);
}

/// Result of [processCapture].
class CaptureCropResult {
  const CaptureCropResult({
    required this.path,
    this.contextPath,
    this.sourceWidth,
    this.sourceHeight,
    this.crop,
    this.exifFocalMm,
    this.exifFocal35mm,
    this.exifDigitalZoom,
    this.contextBoxed = false,
    this.stepPaths = const [],
  });

  /// v11.12 Macro: the 2x / 3x / 4x step photos with the zoomed area boxed.
  final List<String> stepPaths;

  /// v11.9: [contextPath] has the zoomed region boxed in red.
  final bool contextBoxed;

  /// Photo to show / save / enhance (exact on-screen region, full res).
  final String path;

  /// Small downscaled copy of the full uncropped still (only when a digital
  /// crop was applied). Sent to the AI as scene context (second image).
  final String? contextPath;
  final int? sourceWidth;
  final int? sourceHeight;
  final CropRect? crop;

  /// Zoom calibration diagnostics read from the still's EXIF (if the HAL
  /// wrote them): lens focal length, 35mm-equivalent focal, digital zoom.
  final double? exifFocalMm;
  final double? exifFocal35mm;
  final double? exifDigitalZoom;
}

double? _exifDouble(img.ExifData exif, String tag) {
  try {
    final v = exif.exifIfd[tag] ?? exif.imageIfd[tag];
    if (v == null) return null;
    final d = v.toDouble();
    return (d.isFinite && d > 0) ? d : null;
  } catch (_) {
    return null;
  }
}

/// Long side of the context image sent alongside the crop.
const int kContextLongSide = 768;

/// Crops a captured still to exactly what the viewfinder showed.
///
/// Runs off the UI isolate. Fast path: frame ratio already matches (4:3 on a
/// 4:3 sensor) and no digital zoom → original path, no decode / re-encode.
/// Otherwise EXIF orientation is baked into the pixels first (the past
/// stretch bug) so the crop happens in the upright frame the user saw.
Future<CaptureCropResult> processCapture(
  String path, {
  required double portraitRatio,
  required String label,
  double digitalZoom = 1.0,
  bool writeContext = true,
  bool macroBox = false,
  String? snapshotPath,
  double snapshotZoom = 1.0,
  List<(String, double)> stepPhotos = const [],
  double stepMaxRegion = 0,
  double stepCropMargin = 0,
}) {
  return Isolate.run(
    () => _processSync(
      path,
      portraitRatio,
      label,
      digitalZoom,
      writeContext,
      macroBox,
      snapshotPath,
      snapshotZoom,
      stepPhotos,
      stepMaxRegion,
      stepCropMargin,
    ),
  );
}

/// Back-compat wrapper (v6 API): returns only the cropped path.
Future<String> cropCaptureToRatio(
  String path, {
  required double portraitRatio,
  required String label,
  double digitalZoom = 1.0,
}) async {
  final r = await processCapture(
    path,
    portraitRatio: portraitRatio,
    label: label,
    digitalZoom: digitalZoom,
    writeContext: false,
  );
  return r.path;
}

CaptureCropResult _processSync(
  String path,
  double portraitRatio,
  String label,
  double digitalZoom,
  bool writeContext, [
  bool macroBox = false,
  String? snapshotPath,
  double snapshotZoom = 1.0,
  List<(String, double)> stepPhotos = const [],
  double stepMaxRegion = 0,
  double stepCropMargin = 0,
]) {
  final bytes = File(path).readAsBytesSync();
  final ratio = (portraitRatio.isFinite && portraitRatio > 0)
      ? portraitRatio
      : 3 / 4;
  final targetLongShort = ratio >= 1 ? ratio : 1 / ratio;
  final zoom = (digitalZoom.isFinite && digitalZoom > 1.001)
      ? digitalZoom
      : 1.0;

  if (zoom == 1.0 && !macroBox && stepPhotos.isEmpty) {
    try {
      final info = img.JpegDecoder().startDecode(bytes);
      if (info != null && info.width > 0 && info.height > 0) {
        final longShort =
            math.max(info.width, info.height) /
            math.min(info.width, info.height);
        if ((longShort - targetLongShort).abs() / targetLongShort < 0.01) {
          return CaptureCropResult(path: path);
        }
      }
    } catch (_) {
      // Not a JPEG / unreadable header: fall through to full decode.
    }
  }

  final decoded = img.decodeImage(bytes);
  if (decoded == null) return CaptureCropResult(path: path);

  final exif = decoded.exif;
  final focal = _exifDouble(exif, 'FocalLength');
  final focal35 = _exifDouble(exif, 'FocalLengthIn35mmFilm');
  final exifDigital = _exifDouble(exif, 'DigitalZoomRatio');
  final upright = img.bakeOrientation(decoded);
  final rect = computeCaptureCrop(
    iw: upright.width,
    ih: upright.height,
    portraitRatio: ratio,
    digitalZoom: zoom,
  );
  final cropped = img.copyCrop(
    upright,
    x: rect.x,
    y: rect.y,
    width: rect.width,
    height: rect.height,
  );
  cropped.exif.imageIfd.orientation = null;

  final base = p.join(
    p.dirname(path),
    '${p.basenameWithoutExtension(path)}_${label.replaceAll(':', 'x')}',
  );
  final outPath = '$base.jpg';
  File(
    outPath,
  ).writeAsBytesSync(img.encodeJpg(cropped, quality: 95), flush: true);

  String? contextPath;
  var boxed = false;
  img.Image? snap;
  if (writeContext && snapshotPath != null && snapshotZoom > 1.0) {
    try {
      final raw = img.decodeImage(File(snapshotPath).readAsBytesSync());
      if (raw != null) snap = img.bakeOrientation(raw);
    } catch (_) {
      snap = null;
    }
  }
  if (snap != null) {
    // v11.9: sharp low-zoom snapshot with the user's zoomed region boxed.
    final r2 = computeCaptureCrop(
      iw: snap.width,
      ih: snap.height,
      portraitRatio: ratio,
      digitalZoom: snapshotZoom,
    );
    contextPath = '${base}_boxed.jpg';
    boxed = true;
    File(contextPath).writeAsBytesSync(
      img.encodeJpg(boxedContext(snap, r2), quality: 88),
      flush: true,
    );
  } else if (writeContext && macroBox) {
    boxed = true;
    // v11.5 Macro: full sharp frame with the zoomed region boxed in red.
    contextPath = '${base}_boxed.jpg';
    File(contextPath).writeAsBytesSync(
      img.encodeJpg(boxedContext(upright, rect), quality: 88),
      flush: true,
    );
  } else if (writeContext && zoom > 1.0) {
    final long = math.max(upright.width, upright.height);
    final small = long > kContextLongSide
        ? img.copyResize(
            upright,
            width: upright.width >= upright.height ? kContextLongSide : null,
            height: upright.height > upright.width ? kContextLongSide : null,
            interpolation: img.Interpolation.average,
          )
        : upright;
    small.exif.imageIfd.orientation = null;
    contextPath = '${base}_context.jpg';
    File(
      contextPath,
    ).writeAsBytesSync(img.encodeJpg(small, quality: 85), flush: true);
  }

  // v11.12 Macro step photos: each boxed where the zoomed crop sits.
  final stepPaths = <String>[];
  if (writeContext) {
    for (var i = 0; i < stepPhotos.length; i++) {
      final (sp, regionZoom) = stepPhotos[i];
      try {
        final raw = img.decodeImage(File(sp).readAsBytesSync());
        if (raw == null) continue;
        var up = img.bakeOrientation(raw);
        var rz = regionZoom;
        if (stepCropMargin >= 1) {
          // v11.31 zoom ladder: ONLY the final-frame area (+ a small margin)
          // cut out of the reference, no drawn box.
          final r = computeCaptureCrop(
            iw: up.width,
            ih: up.height,
            portraitRatio: ratio,
            digitalZoom: math.max(1.0, rz / stepCropMargin),
          );
          final cut = img.copyCrop(
            up,
            x: r.x,
            y: r.y,
            width: r.width,
            height: r.height,
          );
          cut.exif.imageIfd.orientation = null;
          final out = '${base}_ref${i}_crop.jpg';
          File(
            out,
          ).writeAsBytesSync(img.encodeJpg(cut, quality: 92), flush: true);
          stepPaths.add(out);
          continue;
        }
        // v11.30 zoom ladder: crop around the box first so it stays big
        // enough to see (box = 1/[stepMaxRegion] of the reference).
        if (stepMaxRegion > 1 && rz > stepMaxRegion) {
          final pre = computeCaptureCrop(
            iw: up.width,
            ih: up.height,
            portraitRatio: ratio,
            digitalZoom: rz / stepMaxRegion,
          );
          up = img.copyCrop(
            up,
            x: pre.x,
            y: pre.y,
            width: pre.width,
            height: pre.height,
          );
          rz = stepMaxRegion;
        }
        final r = computeCaptureCrop(
          iw: up.width,
          ih: up.height,
          portraitRatio: ratio,
          digitalZoom: rz,
        );
        final out = '${base}_step${i}_boxed.jpg';
        File(out).writeAsBytesSync(
          img.encodeJpg(boxedContext(up, r), quality: 88),
          flush: true,
        );
        stepPaths.add(out);
      } catch (_) {
        // a missing step photo: work with what exists
      }
    }
  }

  return CaptureCropResult(
    path: outPath,
    stepPaths: stepPaths,
    contextPath: contextPath,
    contextBoxed: boxed,
    sourceWidth: upright.width,
    sourceHeight: upright.height,
    crop: rect,
    exifFocalMm: focal,
    exifFocal35mm: focal35,
    exifDigitalZoom: exifDigital,
  );
}

/// Long side of the v11.5 macro "boxed" full frame.
const int kMacroBoxedLongSide = 1280;

/// Full frame (downscaled to [kMacroBoxedLongSide]) with [rect] outlined in
/// red — the AI's map of WHERE to magnify. Pure → unit tested.
img.Image boxedContext(img.Image upright, CropRect rect) {
  final long = math.max(upright.width, upright.height);
  final s = long > kMacroBoxedLongSide ? kMacroBoxedLongSide / long : 1.0;
  final small = s < 1
      ? img.copyResize(
          upright,
          width: (upright.width * s).round(),
          height: (upright.height * s).round(),
          interpolation: img.Interpolation.average,
        )
      : img.Image.from(upright);
  small.exif.imageIfd.orientation = null;
  final t = math.max(3, (math.max(small.width, small.height) / 220).round());
  final x1 = (rect.x * s).round(), y1 = (rect.y * s).round();
  final x2 = ((rect.x + rect.width) * s).round() - 1;
  final y2 = ((rect.y + rect.height) * s).round() - 1;
  final red = img.ColorRgb8(255, 32, 32);
  for (var i = 0; i < t; i++) {
    img.drawRect(
      small,
      x1: (x1 - i).clamp(0, small.width - 1),
      y1: (y1 - i).clamp(0, small.height - 1),
      x2: (x2 + i).clamp(0, small.width - 1),
      y2: (y2 + i).clamp(0, small.height - 1),
      color: red,
    );
  }
  return small;
}

// ---------------------------------------------------------------------------
// v11.13 Extreme: centre ~1/3 of the region, on the darkest spot near the
// middle, upscaled (cubic) to ~1024 px (step photos still sent first).
// ---------------------------------------------------------------------------

const double kExtremeSpotFraction = 1 / 3;
const int kExtremeSpotLongSide = 1024;

/// Window (side fraction [frac] of w/h) centred on the darkest smoothed
/// spot within the middle third of [gray] (w×h, row-major). Pure.
CropRect extremeSpotRect(
  List<double> gray,
  int w,
  int h, {
  double frac = kExtremeSpotFraction,
}) {
  final rw = math.max(1, (w * frac).round()),
      rh = math.max(1, (h * frac).round());
  // Search centres within ±1/6 of the middle on a coarse grid.
  final k = math.max(1, math.min(w, h) ~/ 12); // blob size
  var bestX = w ~/ 2, bestY = h ~/ 2;
  var best = double.infinity;
  final step = math.max(1, k ~/ 2);
  for (var cy = (h * 2) ~/ 6 + k; cy <= (h * 4) ~/ 6 - k; cy += step) {
    for (var cx = (w * 2) ~/ 6 + k; cx <= (w * 4) ~/ 6 - k; cx += step) {
      var s = 0.0;
      var n = 0;
      for (var y = cy - k; y <= cy + k; y += math.max(1, k ~/ 3)) {
        for (var x = cx - k; x <= cx + k; x += math.max(1, k ~/ 3)) {
          s += gray[y * w + x];
          n++;
        }
      }
      // Slight pull to the exact centre so flat areas stay centred.
      final d = ((cx - w / 2).abs() + (cy - h / 2).abs()) / (w + h);
      final v = s / math.max(1, n) + 20 * d;
      if (v < best) {
        best = v;
        bestX = cx;
        bestY = cy;
      }
    }
  }
  final x = (bestX - rw ~/ 2).clamp(0, w - rw);
  final y = (bestY - rh ~/ 2).clamp(0, h - rh);
  return CropRect(x, y, rw, rh);
}

/// Writes `<crop>_spot.jpg` (Extreme AI input). Background isolate.
Future<String> writeExtremeSpot(String cropPath) =>
    Isolate.run(() => _spotSync(cropPath));

String _spotSync(String cropPath) {
  final raw = img.decodeImage(File(cropPath).readAsBytesSync());
  if (raw == null) return cropPath;
  final im = img.bakeOrientation(raw);
  final g = List<double>.filled(im.width * im.height, 0);
  for (final p in im) {
    g[p.y * im.width + p.x] = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
  }
  final r = extremeSpotRect(g, im.width, im.height);
  final spot = img.copyCrop(
    im,
    x: r.x,
    y: r.y,
    width: r.width,
    height: r.height,
  );
  final long = math.max(spot.width, spot.height);
  final s = kExtremeSpotLongSide / long;
  final up = img.copyResize(
    spot,
    width: (spot.width * s).round(),
    height: (spot.height * s).round(),
    interpolation: img.Interpolation.cubic,
  );
  up.exif.imageIfd.orientation = null;
  final out = '${cropPath.replaceFirst(RegExp(r'\.jpg$'), '')}_spot.jpg';
  File(out).writeAsBytesSync(img.encodeJpg(up, quality: 95), flush: true);
  return out;
}

// ---------------------------------------------------------------------------
// v11.15: step photo with the centre (where the user zooms) boxed in red,
// for the cloud "which part" check.
// ---------------------------------------------------------------------------

const double kStepBoxFraction = 0.5;

/// Centre box (side [frac] of w/h). Pure.
CropRect centreBoxRect(int w, int h, {double frac = kStepBoxFraction}) {
  final bw = math.max(1, (w * frac).round()),
      bh = math.max(1, (h * frac).round());
  return CropRect((w - bw) ~/ 2, (h - bh) ~/ 2, bw, bh);
}

/// Writes `<photo>_detect_boxed.jpg` (≤1024 px). Background isolate.
Future<String> writeBoxedStep(String path) => Isolate.run(() {
  final raw = img.decodeImage(File(path).readAsBytesSync());
  if (raw == null) return path;
  var im = img.bakeOrientation(raw);
  if (math.max(im.width, im.height) > 1024) {
    im = img.copyResize(
      im,
      width: im.width >= im.height ? 1024 : null,
      height: im.height > im.width ? 1024 : null,
    );
  }
  final out = '${path.replaceFirst(RegExp(r'\.jpg$'), '')}_detect_boxed.jpg';
  File(out).writeAsBytesSync(
    img.encodeJpg(
      boxedContext(im, centreBoxRect(im.width, im.height)),
      quality: 85,
    ),
    flush: true,
  );
  return out;
});

// ---------------------------------------------------------------------------
// v11.19: "last clear photo" beyond 4x + shutter spot box
// ---------------------------------------------------------------------------

/// Laplacian variance over the centre half of [path] (≤512 px grey).
/// Background isolate; 0 when unreadable.
Future<double> photoSharpness(String path) => Isolate.run(() {
  final raw = img.decodeImage(File(path).readAsBytesSync());
  if (raw == null) return 0.0;
  var im = img.bakeOrientation(raw);
  if (math.max(im.width, im.height) > 512) {
    im = img.copyResize(
      im,
      width: im.width >= im.height ? 512 : null,
      height: im.height > im.width ? 512 : null,
    );
  }
  return sharpnessOf(im);
});

/// Laplacian variance of the centre half of [im]. Pure.
double sharpnessOf(img.Image im) {
  final x0 = im.width ~/ 4, y0 = im.height ~/ 4;
  final x1 = im.width - x0, y1 = im.height - y0;
  double g(int x, int y) {
    final p = im.getPixel(x, y);
    return 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
  }

  var sum = 0.0, sum2 = 0.0;
  var n = 0;
  for (var y = math.max(1, y0); y < math.min(im.height - 1, y1); y++) {
    for (var x = math.max(1, x0); x < math.min(im.width - 1, x1); x++) {
      final l =
          g(x - 1, y) + g(x + 1, y) + g(x, y - 1) + g(x, y + 1) - 4 * g(x, y);
      sum += l;
      sum2 += l * l;
      n++;
    }
  }
  if (n == 0) return 0;
  final m = sum / n;
  return sum2 / n - m * m;
}

/// v11.61 FAIR detail measure for comparing two crops of the SAME area:
/// Laplacian variance over the whole image minus the part that is just
/// sensor noise (noise σ from the low tail of Immerkær's noise filter; the
/// Laplacian of white noise has variance 20σ²). Noise never poses as detail.
/// Call it on images resized to the same size. Pure.
double fairSharpnessOf(img.Image im) {
  final w = im.width, h = im.height;
  if (w < 3 || h < 3) return 0;
  final g = Float64List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = im.getPixel(x, y);
      g[y * w + x] = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
    }
  }
  var sum = 0.0, sum2 = 0.0;
  final nres = <double>[];
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x;
      final l = g[i - 1] + g[i + 1] + g[i - w] + g[i + w] - 4 * g[i];
      sum += l;
      sum2 += l * l;
      // Immerkær mask [1 -2 1; -2 4 -2; 1 -2 1]: ~0 on smooth structure,
      // σ·6 on white noise.
      final n =
          g[i - w - 1] -
          2 * g[i - w] +
          g[i - w + 1] -
          2 * g[i - 1] +
          4 * g[i] -
          2 * g[i + 1] +
          g[i + w - 1] -
          2 * g[i + w] +
          g[i + w + 1];
      nres.add(n.abs());
    }
  }
  final n = nres.length;
  if (n == 0) return 0;
  final m = sum / n;
  final lapVar = sum2 / n - m * m;
  // Noise σ from the LOW tail of the noise-filter response (fine texture and
  // edges inflate the upper part; the 10th percentile of a half-normal is
  // 0.1257 σ_N, σ_N = 6σ). Never removes more than 90 % (no 0/∞ ratios).
  nres.sort();
  final sigma = nres[n ~/ 10] / (0.1257 * 6);
  return math.max(lapVar * 0.1, lapVar - 20 * sigma * sigma);
}

/// v11.61 fair comparison of two crops of the same area: both resized
/// (box average) to the SAME size — the smaller real resolution of the two,
/// capped at [cap] — so neither gains from a downscale (averaging) the other
/// did not get, and a 3×3 sharpen at full resolution is averaged away;
/// noise-corrected. Returns detail(a) / detail(b). Pure.
double fairSharpRatio(
  img.Image a,
  img.Image b, {
  double aRealScale = 1.0,
  int cap = 256,
}) {
  final aLong = math.max(a.width, a.height) * aRealScale.clamp(0.05, 1.0);
  final bLong = math.max(b.width, b.height).toDouble();
  final long = math
      .max(24, math.min(cap.toDouble(), math.min(aLong, bLong)))
      .round();
  img.Image fit(img.Image im) {
    final s = long / math.max(im.width, im.height);
    return img.copyResize(
      im,
      width: math.max(3, (im.width * s).round()),
      height: math.max(3, (im.height * s).round()),
      interpolation: img.Interpolation.average,
    );
  }

  final fa = fairSharpnessOf(fit(a));
  final fb = fairSharpnessOf(fit(b));
  if (fb <= 1e-6) return fa > 1e-6 ? 99.0 : 1.0;
  return fa / fb;
}

/// Centred box of the final zoom inside a photo whose region zoom is
/// [regionZoom] (= final zoom / photo camera zoom). Pure.
CropRect zoomBoxRect(int w, int h, double regionZoom) {
  final f = (1 / (regionZoom <= 0 ? 1 : regionZoom)).clamp(0.03, 1.0);
  return centreBoxRect(w, h, frac: f);
}

/// Writes `<photo>_spot_boxed.jpg` (≤1024 px) with a small red box where
/// the final zoom lies. Background isolate.
Future<String> writeZoomBoxed(String path, double regionZoom) =>
    Isolate.run(() {
      final raw = img.decodeImage(File(path).readAsBytesSync());
      if (raw == null) return path;
      var im = img.bakeOrientation(raw);
      if (math.max(im.width, im.height) > 1024) {
        im = img.copyResize(
          im,
          width: im.width >= im.height ? 1024 : null,
          height: im.height > im.width ? 1024 : null,
        );
      }
      final r = zoomBoxRect(im.width, im.height, regionZoom);
      final t = math.max(3, math.max(im.width, im.height) ~/ 200);
      final red = img.ColorRgb8(255, 0, 0);
      for (var i = 0; i < t; i++) {
        img.drawRect(
          im,
          x1: r.x - i,
          y1: r.y - i,
          x2: r.x + r.width + i,
          y2: r.y + r.height + i,
          color: red,
        );
      }
      final out = '${path.replaceFirst(RegExp(r'\.jpg$'), '')}_spot_boxed.jpg';
      File(out).writeAsBytesSync(img.encodeJpg(im, quality: 85), flush: true);
      return out;
    });

/// v11.64 the zoomed area itself (the red-box region of [writeZoomBoxed],
/// cut out) for the Microscope / Extreme / Ultra naming step.
Future<String> writeZoomCrop(String path, double regionZoom) =>
    Isolate.run(() {
      final raw = img.decodeImage(File(path).readAsBytesSync());
      if (raw == null) return path;
      var im = img.bakeOrientation(raw);
      final r = zoomBoxRect(im.width, im.height, regionZoom);
      im = img.copyCrop(im, x: r.x, y: r.y, width: r.width, height: r.height);
      if (math.max(im.width, im.height) > 1024) {
        im = img.copyResize(
          im,
          width: im.width >= im.height ? 1024 : null,
          height: im.height > im.width ? 1024 : null,
        );
      }
      final out = '${path.replaceFirst(RegExp(r'\.jpg$'), '')}_spot_crop.jpg';
      File(out).writeAsBytesSync(img.encodeJpg(im, quality: 85), flush: true);
      return out;
    });
