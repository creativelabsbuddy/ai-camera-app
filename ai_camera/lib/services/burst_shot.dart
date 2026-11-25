import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// v11.69 Normal Photo burst (free, on device): long-press the shutter →
/// [kBurstFrames] stills; the app picks the best (sharpness + eyes open when
/// there are faces) and the user keeps the best / all.
const int kBurstFrames = 8;

/// Fewer frames than this → treated as a single photo.
const int kBurstMinFrames = 2;

/// Long side the frames are decoded at for scoring (native downsample).
const int kBurstScoreLong = 640;

/// One-time hint.
const kBurstTip = 'Tip: press and hold the shutter for Burst';
const kBurstTipSeenKey = 'burst_tip_seen_v1169';

/// Scores of one burst frame.
@immutable
class BurstScore {
  const BurstScore({required this.sharpness, this.eyes});

  /// Laplacian energy of luma (higher = sharper).
  final double sharpness;

  /// Faces found in this frame, each = min(left, right) eye-open
  /// probability (null = not checked / unknown; empty = no face).
  final List<double>? eyes;

  int get faces => eyes?.length ?? 0;

  /// The worst eye-open value among the faces (1 = no faces).
  double get eyesOpen =>
      (eyes == null || eyes!.isEmpty) ? 1 : eyes!.reduce(math.min);
}

/// Eye-open probability below this = eyes closed (blink).
const double kEyesClosedBelow = 0.4;

/// Combined score of a frame. Pure (unit tested).
///
/// Sharpness counts relative to the sharpest frame. When the burst has faces,
/// eyes open weigh 45 %; a frame that lost a face or has a blink is pushed
/// down hard so it never wins over a sharp open-eyed frame.
double burstScore(
  BurstScore s, {
  required double maxSharpness,
  required bool burstHasFaces,
  int maxFaces = 0,
}) {
  final sharp = maxSharpness <= 0
      ? 0.0
      : (s.sharpness / maxSharpness).clamp(0.0, 1.0);
  if (!burstHasFaces) return sharp;
  var eyes = s.eyes == null ? 0.5 : s.eyesOpen;
  if (s.eyes != null && s.faces < maxFaces) eyes *= 0.5; // a face missing
  var score = 0.55 * sharp + 0.45 * eyes;
  if (s.eyes != null && s.faces > 0 && s.eyesOpen < kEyesClosedBelow) {
    score *= 0.6; // blink
  }
  return score;
}

/// Index of the best frame (ties → the earliest). −1 when empty. Pure.
int pickBestFrame(List<BurstScore> frames) {
  if (frames.isEmpty) return -1;
  final maxSharp = frames.map((f) => f.sharpness).reduce(math.max);
  final hasFaces = frames.any((f) => f.faces > 0);
  final maxFaces = frames.map((f) => f.faces).reduce(math.max);
  var best = 0;
  var bestScore = -1.0;
  for (var i = 0; i < frames.length; i++) {
    final sc = burstScore(
      frames[i],
      maxSharpness: maxSharp,
      burstHasFaces: hasFaces,
      maxFaces: maxFaces,
    );
    if (sc > bestScore + 1e-9) {
      bestScore = sc;
      best = i;
    }
  }
  return best;
}

/// Why the best frame won (short English line).
String bestReason(List<BurstScore> frames) {
  final hasFaces = frames.any((f) => f.faces > 0);
  return hasFaces ? 'Best: sharpest with eyes open' : 'Best: sharpest photo';
}

/// Sharpness: mean energy (mean square) of the 4-neighbour Laplacian of
/// luma over the centre [centreFrac] of an RGBA frame. Higher = sharper;
/// a flat frame = 0. Pure.
double laplacianVariance(
  Uint8List rgba,
  int width,
  int height, {
  double centreFrac = 0.8,
}) {
  if (width < 3 || height < 3) return 0;
  final f = centreFrac.clamp(0.2, 1.0);
  final x0 = math.max(1, ((1 - f) / 2 * width).round());
  final x1 = math.min(width - 2, width - x0);
  final y0 = math.max(1, ((1 - f) / 2 * height).round());
  final y1 = math.min(height - 2, height - y0);
  int lum(int x, int y) {
    final i = (y * width + x) * 4;
    return (rgba[i] * 54 + rgba[i + 1] * 183 + rgba[i + 2] * 19) >> 8;
  }

  var n = 0;
  var sum2 = 0.0;
  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      final l =
          4 * lum(x, y) -
          lum(x - 1, y) -
          lum(x + 1, y) -
          lum(x, y - 1) -
          lum(x, y + 1);
      sum2 += l * l;
      n++;
    }
  }
  return n == 0 ? 0 : sum2 / n;
}

/// Decoded scoring copy of a frame: (rgba, width, height).
typedef BurstPixels = (Uint8List, int, int);

/// Real analysis on the phone (tests swap these hooks).
class BurstAnalyzer {
  static Future<BurstPixels?> Function(String path) decode = _decode;
  static Future<List<double>?> Function(String path) eyesOf = _eyes;

  static void reset() {
    decode = _decode;
    eyesOf = _eyes;
  }

  static Future<double> sharpnessOf(String path) async {
    final px = await decode(path);
    if (px == null) return 0;
    return compute(_lapl, px);
  }

  static Future<BurstPixels?> _decode(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final buf = await ui.ImmutableBuffer.fromUint8List(bytes);
      final desc = await ui.ImageDescriptor.encoded(buf);
      final w = desc.width, h = desc.height;
      final long = math.max(w, h);
      final s = long > kBurstScoreLong ? kBurstScoreLong / long : 1.0;
      final codec = await desc.instantiateCodec(
        targetWidth: math.max(1, (w * s).round()),
        targetHeight: math.max(1, (h * s).round()),
      );
      final frame = await codec.getNextFrame();
      final im = frame.image;
      final data = await im.toByteData(format: ui.ImageByteFormat.rawRgba);
      final out = data == null
          ? null
          : (data.buffer.asUint8List(), im.width, im.height);
      im.dispose();
      codec.dispose();
      desc.dispose();
      buf.dispose();
      return out;
    } catch (e) {
      debugPrint('Burst decode failed: $e');
      return null;
    }
  }

  static FaceDetector? _det;

  /// ML Kit faces with eye-open classification. Null = unavailable.
  static Future<List<double>?> _eyes(String path) async {
    if (kIsWeb || !Platform.isAndroid) return null;
    try {
      final d = _det ??= FaceDetector(
        options: FaceDetectorOptions(
          enableClassification: true,
          minFaceSize: 0.08,
          performanceMode: FaceDetectorMode.fast,
        ),
      );
      final faces = await d.processImage(InputImage.fromFilePath(path));
      return [
        for (final f in faces)
          math.min(
            f.leftEyeOpenProbability ?? 0.5,
            f.rightEyeOpenProbability ?? 0.5,
          ),
      ];
    } catch (e) {
      debugPrint('Burst faces failed: $e');
      return null;
    }
  }

  /// Frees the face detector after a burst review.
  static Future<void> close() async {
    final d = _det;
    _det = null;
    try {
      await d?.close();
    } catch (_) {}
  }
}

double _lapl(BurstPixels p) => laplacianVariance(p.$1, p.$2, p.$3);
