import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

import 'capture_crop.dart' show computeCaptureCrop;

// v11.67 CLEAR REFERENCE (undo: set [kClearRefEnabled] to false, or revert
// the "v11.67 item 5" commit). Pro AI photos zoomed past the phone's clear
// limit (S24 Ultra ~10x, cheap phones ~2–3x): while zooming, ONE silent
// photo is taken when the zoom reaches the clear limit (no merge). At the
// shutter (e.g. 22x) the exact area of the final frame is cut from that
// reference (centred, ratio clearLimit / finalZoom) and sent FIRST as the
// detail source; the final frame goes second for the framing only. Missing
// or stale reference (zoomed back below the limit, too old, subject
// changed) → the final frame alone, as before. Pure helpers (tested).
// v11.68: switched off. On a single-lens tablet the clear limit equals
// the hardware max, so the reference added no detail and Flare could
// erase sticker text. Flip to true to turn the path back on.

/// Single on/off switch for the whole feature (no remote config).
const bool kClearRefEnabled = false;

/// Prompt line added to the sharp-source zoom prompt (= server
/// prompts.CLEAR_REF_LINE).
const String kClearRefLine =
    'Use the first image for real detail; keep the framing of the second image.';

/// A reference older than this is not used.
const Duration kClearRefMaxAge = Duration(seconds: 45);

/// Used only when the final zoom is clearly past the limit.
const double kClearRefMinRatio = 1.05;

/// Reference crop vs final frame (32 px grey, blurred alike): below this
/// normalised correlation the subject changed / moved → final only.
const double kClearRefMinMatch = 0.45;

/// Long side of the reference crop sent to the AI.
const int kClearRefCropLong = 1536;

/// The phone's clear limit: flagships the optical limit up to its 2x
/// in-sensor crop (S24 Ultra 5x tele → 10x), within the camera max; cheap
/// phones the observed / real-pixel clear limit (~2–3x). Never below 1x.
double clearRefLimit({
  required bool lowEnd,
  required double opticalLimit,
  required double hardwareMax,
  double? observedClear,
  required double pixelClear,
}) {
  final hw = hardwareMax.isFinite && hardwareMax >= 1 ? hardwareMax : 1.0;
  final opt = opticalLimit.isFinite && opticalLimit >= 1 ? opticalLimit : 1.0;
  double lim;
  if (lowEnd) {
    final o = observedClear;
    lim = o != null && o.isFinite && o >= 1 ? o : pixelClear;
    if (!lim.isFinite) lim = opt;
  } else {
    lim = math.max(opt, math.min(hw, opt * 2));
  }
  return lim.clamp(1.0, hw).toDouble();
}

/// The final zoom is past the clear limit (a reference helps).
bool clearRefNeeded(double finalZoom, double limit) =>
    finalZoom.isFinite && limit >= 1 && finalZoom > limit * kClearRefMinRatio;

/// Camera zoom to hold while the reference is not taken yet: the clear
/// limit when the zoom is above it and the camera would go past it (the
/// rest is a centre digital crop on the preview meanwhile); null = no hold.
double? clearRefHold({
  required bool active,
  required double selected,
  required double cameraZoom,
  required double limit,
}) {
  if (!active || limit < 1) return null;
  if (selected <= limit + 0.01 || cameraZoom <= limit + 0.01) return null;
  return limit;
}

/// One silent reference photo.
class ClearRef {
  const ClearRef({
    required this.path,
    required this.cameraZoom,
    required this.at,
  });

  final String path;

  /// Camera zoom of the still (no digital crop in the file).
  final double cameraZoom;
  final DateTime at;
}

/// Why a reference is not used ('' = usable).
String clearRefStaleReason(ClearRef? ref, DateTime now, double finalZoom) {
  if (ref == null) return 'none';
  if (now.difference(ref.at) > kClearRefMaxAge) return 'old';
  if (finalZoom < ref.cameraZoom * kClearRefMinRatio) return 'not past';
  if (!File(ref.path).existsSync()) return 'missing';
  return '';
}

/// Normalised cross-correlation of two equal-size grey images (−1…1).
double greyMatch(List<double> a, List<double> b) {
  final n = math.min(a.length, b.length);
  if (n == 0) return 0;
  var ma = 0.0, mb = 0.0;
  for (var i = 0; i < n; i++) {
    ma += a[i];
    mb += b[i];
  }
  ma /= n;
  mb /= n;
  var sab = 0.0, saa = 0.0, sbb = 0.0;
  for (var i = 0; i < n; i++) {
    final x = a[i] - ma, y = b[i] - mb;
    sab += x * y;
    saa += x * x;
    sbb += y * y;
  }
  if (saa < 1e-6 || sbb < 1e-6) return saa < 1e-6 && sbb < 1e-6 ? 1 : 0;
  return sab / math.sqrt(saa * sbb);
}

List<double> _grey32(img.Image im) {
  final s = img.gaussianBlur(
    img.copyResize(
      im,
      width: 32,
      height: 32,
      interpolation: img.Interpolation.average,
    ),
    radius: 1,
  );
  return [
    for (final p in s) (p.r * 0.299 + p.g * 0.587 + p.b * 0.114).toDouble(),
  ];
}

/// Cuts the final frame's area from the reference still and checks it
/// against the final crop. Returns (path or null, match score).
Future<(String?, double)> writeClearRefCrop({
  required String refPath,
  required double refCameraZoom,
  required double finalZoom,
  required double portraitRatio,
  required String finalCropPath,
  required String outPath,
}) => Isolate.run(() {
  final raw = img.decodeImage(File(refPath).readAsBytesSync());
  final fin = img.decodeImage(File(finalCropPath).readAsBytesSync());
  if (raw == null || fin == null) return (null, 0.0);
  final ref = img.bakeOrientation(raw);
  final r = computeCaptureCrop(
    iw: ref.width,
    ih: ref.height,
    portraitRatio: portraitRatio,
    digitalZoom: finalZoom / refCameraZoom,
  );
  var cut = img.copyCrop(
    ref,
    x: r.x,
    y: r.y,
    width: r.width,
    height: r.height,
  );
  final score = greyMatch(_grey32(cut), _grey32(img.bakeOrientation(fin)));
  if (score < kClearRefMinMatch) return (null, score);
  if (math.max(cut.width, cut.height) > kClearRefCropLong) {
    cut = img.copyResize(
      cut,
      width: cut.width >= cut.height ? kClearRefCropLong : null,
      height: cut.height > cut.width ? kClearRefCropLong : null,
      interpolation: img.Interpolation.average,
    );
  }
  File(outPath).writeAsBytesSync(img.encodeJpg(cut, quality: 92), flush: true);
  return (outPath, score);
});

/// Key-build debug text, e.g. "clear ref 10x · match 0.82" / "clear ref
/// none (final only)".
String clearRefDebug({
  double? refZoom,
  double? match,
  String reason = '',
}) {
  if (reason.isEmpty && refZoom != null) {
    final z = refZoom == refZoom.roundToDouble()
        ? refZoom.toStringAsFixed(0)
        : refZoom.toStringAsFixed(1);
    return 'clear ref ${z}x${match == null ? '' : ' · match ${match.toStringAsFixed(2)}'}';
  }
  return 'clear ref $reason${match == null ? '' : ' ${match.toStringAsFixed(2)}'} (final only)';
}
