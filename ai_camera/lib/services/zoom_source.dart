import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

import 'ai_call.dart' show kNoSharpSourceMessage;
import 'capture_crop.dart' show fairSharpRatio;
import 'zoom_root.dart' show kRoiMinRealPx;
import 'zoom_assist.dart' show edgeMap, kSubjectMatchMin;

/// v11.59 sharp-source zoom (cheap phones, beyond the clear limit):
/// the sharpest truly usable lower-zoom checkpoint photo, cut and ALIGNED
/// to the user's exact zoomed framing, is the image the AI works from; the
/// final (blurry) zoom photo is only the framing reference. No usable,
/// matching source → no AI call, nothing charged (fail closed).

/// Reference crops are cut at the final area × this (alignment slack:
/// the source is searched ±30 % of the final area around the centre).
const double kZoomSourceMargin = 1.6;

/// Edge match of the aligned source vs the final area must reach this.
const double kZoomSourceMatchMin = kSubjectMatchMin;

/// Fewer comparable (non-clipped) proxy pixels than this = no evidence →
/// no match (fail closed; the old matcher returned 1 here).
const int kZoomSourceMinValid = 200;

/// The final area inside a source must hold at least this many REAL
/// pixels on its long side (else it is not a usable source → fail closed).
/// v11.61: real sensor pixels (a digital crop's upscaled pixels do not
/// count), lowered from 96 still pixels: beyond the clear range the shot is
/// labelled "AI-enhanced" instead of being blocked; only an absurdly tiny
/// region fails closed.
const int kZoomSourceMinPx = kRoiMinRealPx;

/// Debug label only: a source this much more detailed than the final is
/// reported "sharper".
const double kZoomSourceSharperBy = 1.15;

/// v11.61: a matched source is used when its noise-corrected detail at the
/// SAME scale is at least this share of the final's (it really holds the
/// area's detail). Clearly blurrier → not a usable source → fail closed
/// (the old "final is sharp enough, send it alone" exemption is gone).
const double kZoomSourceMinRatio = 0.8;

/// Long side of the match proxies (final area).
const int kZoomSourceProxyLong = 48;

/// Upload sizes: the source is the primary image, the final framing only.
const int kZoomSourceMainLong = 1536;
const int kZoomFramingLong = 768;

/// Shown when the zoom needs a sharp source and none matched.
const String kZoomNoSharpSource = kNoSharpSourceMessage;

enum ZoomSourceReason {
  /// Aligned, matching, sharper source found.
  ok,

  /// v11.61: matching sources exist but each is clearly blurrier than the
  /// final at the same scale (no usable sharp source → fail closed).
  sourceBlurrier,

  /// No clear lower-zoom photo exists.
  noClearRef,

  /// Clear photos exist but none matches the final area.
  noMatch,

  /// Matches only in sources too small to be usable.
  tooSmall,

  /// Files unreadable.
  error,
}

class ZoomSourceTry {
  const ZoomSourceTry(this.checkpoint, this.score, this.note);
  final double checkpoint;
  final double score;
  final String note;
}

class ZoomSourceDecision {
  const ZoomSourceDecision({
    required this.reason,
    this.path,
    this.checkpoint,
    this.score,
    this.sharpRatio,
    this.tries = const [],
  });
  final ZoomSourceReason reason;

  /// Aligned source crop (same aspect as the final area) when [ok].
  final String? path;
  final double? checkpoint;
  final double? score;

  /// Source sharpness / final sharpness at the same resolution.
  final double? sharpRatio;
  final List<ZoomSourceTry> tries;

  bool get ok => reason == ZoomSourceReason.ok && path != null;

  /// Key builds: "src 4x match 0.62 sharp 2.1x" / "src none (no match: 4x 0.21)".
  String get debugText {
    String z(double v) => v == v.roundToDouble()
        ? '${v.toStringAsFixed(0)}x'
        : '${v.toStringAsFixed(1)}x';
    final t = tries
        .map(
          (e) =>
              '${z(e.checkpoint)} ${e.score.toStringAsFixed(2)}${e.note.isEmpty ? '' : ' ${e.note}'}',
        )
        .join(', ');
    return switch (reason) {
      ZoomSourceReason.ok =>
        'src ${z(checkpoint!)} match ${score!.toStringAsFixed(2)} sharp ${sharpRatio!.toStringAsFixed(1)}x',
      ZoomSourceReason.sourceBlurrier => 'src none (blurrier: $t)',
      ZoomSourceReason.noClearRef => 'src none (no clear photo)',
      ZoomSourceReason.noMatch => 'src none (no match: $t)',
      ZoomSourceReason.tooSmall => 'src none (too small: $t)',
      ZoomSourceReason.error => 'src none (error)',
    };
  }
}

/// Grey values (0..255, NaN never) of [im] resized to [w]×[h]. Pure.
List<double> greyOf(img.Image im, int w, int h) {
  final r = img.copyResize(
    im,
    width: w,
    height: h,
    interpolation: img.Interpolation.average,
  );
  return [
    for (var y = 0; y < h; y++)
      for (var x = 0; x < w; x++)
        () {
          final p = r.getPixel(x, y);
          return 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
        }(),
  ];
}

/// Masked NCC that FAILS (returns -1) without enough evidence. Pure.
double strictNcc(
  List<double> a,
  List<double> b, {
  int minValid = kZoomSourceMinValid,
}) {
  var n = 0;
  var ma = 0.0, mb = 0.0;
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i].isNaN || b[i].isNaN) continue;
    ma += a[i];
    mb += b[i];
    n++;
  }
  if (n < math.min(minValid, (a.length * 0.6).round())) return -1;
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
  if (da < 1e-6 || db < 1e-6) return -1; // flat (no structure) → no evidence
  return num / math.sqrt(da * db);
}

/// Best alignment of [close] (cw×ch, the final area) inside [wide]
/// (ww×wh, the source crop with slack): (score, ox, oy) in proxy px.
/// Edges, clipped pixels masked, every offset tried. Pure.
(double, int, int) alignInWide(
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
  var bx = (ww - cw) ~/ 2, by = (wh - ch) ~/ 2;
  final win = List<double>.filled(cw * ch, 0);
  for (var oy = 0; oy + ch <= wh; oy++) {
    for (var ox = 0; ox + cw <= ww; ox++) {
      for (var y = 0; y < ch; y++) {
        for (var x = 0; x < cw; x++) {
          win[y * cw + x] = we[(oy + y) * ww + ox + x];
        }
      }
      final s = strictNcc(
        win,
        ce,
        minValid: math.min(kZoomSourceMinValid, cw * ch ~/ 2),
      );
      if (s > best) {
        best = s;
        bx = ox;
        by = oy;
      }
    }
  }
  return (best, bx, by);
}

/// Proxy size of the final area (long side [kZoomSourceProxyLong]).
(int, int) proxySize(int w, int h) {
  final long = math.max(w, h);
  final s = kZoomSourceProxyLong / math.max(1, long);
  return (math.max(8, (w * s).round()), math.max(8, (h * s).round()));
}

/// One candidate: [refCropPath] = the reference cut at the final area ×
/// [kZoomSourceMargin] (see processCapture), [checkpoint] its zoom.
class ZoomSourceCandidate {
  const ZoomSourceCandidate(
    this.refCropPath,
    this.checkpoint, {
    this.margin = kZoomSourceMargin,
    this.realScale = 1.0,
    this.label = '',
  });
  final String refCropPath;
  final double checkpoint;

  /// v11.61: real sensor pixels per crop pixel (< 1 = digital crop).
  final double realScale;

  /// v11.61: "root 1x opt 1x" / "4x opt 1x + dig 4.0x" (diagnostics).
  final String label;

  /// Actual crop margin (smaller when the reference is only a little
  /// wider than the final: [effectiveSourceMargin]).
  final double margin;
}

/// The crop margin processCapture really used for a reference whose
/// region zoom is [regionZoom]. Pure.
double effectiveSourceMargin(
  double regionZoom, {
  double margin = kZoomSourceMargin,
}) => math.max(1.0, math.min(margin, regionZoom));

/// Pure core (images already decoded + upright): tries [refs] in order
/// (best first) and returns the first aligned, matching, sharper source.
/// [writeSource] stores the chosen crop and returns its path.
///
/// v11.61: [realScales] (index-aligned with [refs], default 1) = real sensor
/// pixels per reference pixel (< 1 for a digital-crop reference). The size
/// gate counts REAL pixels; sharpness is compared fairly ([fairSharpRatio]).
ZoomSourceDecision pickZoomSourceImages({
  required img.Image finalArea,
  required List<(img.Image, double, double)> refs,
  required String Function(img.Image) writeSource,
  List<double>? realScales,
}) {
  if (refs.isEmpty) {
    return const ZoomSourceDecision(reason: ZoomSourceReason.noClearRef);
  }
  final (pw, ph) = proxySize(finalArea.width, finalArea.height);
  final fg = greyOf(finalArea, pw, ph);
  final tries = <ZoomSourceTry>[];
  var anyMatchSmall = false;
  var anyMatchBlurrier = false;
  for (var k = 0; k < refs.length; k++) {
    final (ref, cp, m) = refs[k];
    final real =
        (realScales != null && k < realScales.length ? realScales[k] : 1.0)
            .clamp(0.01, 1.0)
            .toDouble();
    final margin = math.max(1.0, m);
    // Real pixels of the final area inside this reference (known before
    // matching: the reference was cut at the area × margin).
    final realLong = math.max(ref.width, ref.height) / margin * real;
    if (realLong < kZoomSourceMinPx) {
      anyMatchSmall = true;
      tries.add(ZoomSourceTry(cp, -1, 'small ${realLong.round()}px'));
      continue;
    }
    final ww = (pw * margin).round(), wh = (ph * margin).round();
    final rg = greyOf(ref, ww, wh);
    final (score, ox, oy) = alignInWide(rg, ww, wh, fg, pw, ph);
    if (score < kZoomSourceMatchMin) {
      tries.add(ZoomSourceTry(cp, score, ''));
      continue;
    }
    // Map the proxy window back to the reference's real pixels.
    final sx = ref.width / ww, sy = ref.height / wh;
    final cw = (pw * sx).round().clamp(1, ref.width);
    final chh = (ph * sy).round().clamp(1, ref.height);
    final x = (ox * sx).round().clamp(0, ref.width - cw);
    final y = (oy * sy).round().clamp(0, ref.height - chh);
    final src = img.copyCrop(ref, x: x, y: y, width: cw, height: chh);
    // v11.61 fair check: both at the SAME scale (the smaller real
    // resolution), noise-corrected — does the source really hold the
    // area's detail?
    final ratio = fairSharpRatio(src, finalArea, aRealScale: real);
    if (ratio < kZoomSourceMinRatio) {
      anyMatchBlurrier = true;
      tries.add(
        ZoomSourceTry(cp, score, 'blurrier ${ratio.toStringAsFixed(2)}'),
      );
      continue;
    }
    src.exif.imageIfd.orientation = null;
    return ZoomSourceDecision(
      reason: ZoomSourceReason.ok,
      path: writeSource(src),
      checkpoint: cp,
      score: score,
      sharpRatio: ratio,
      tries: tries,
    );
  }
  return ZoomSourceDecision(
    reason: anyMatchBlurrier
        ? ZoomSourceReason.sourceBlurrier
        : anyMatchSmall
        ? ZoomSourceReason.tooSmall
        : ZoomSourceReason.noMatch,
    tries: tries,
  );
}

/// File version (background isolate). [candidates] best first.
Future<ZoomSourceDecision> pickZoomSource({
  required String finalAreaPath,
  required List<ZoomSourceCandidate> candidates,
}) {
  if (candidates.isEmpty) {
    return Future.value(
      const ZoomSourceDecision(reason: ZoomSourceReason.noClearRef),
    );
  }
  return Isolate.run(() {
    try {
      img.Image? load(String p) {
        final raw = img.decodeImage(File(p).readAsBytesSync());
        return raw == null ? null : img.bakeOrientation(raw);
      }

      final fin = load(finalAreaPath);
      if (fin == null) {
        return const ZoomSourceDecision(reason: ZoomSourceReason.error);
      }
      final refs = <(img.Image, double, double)>[];
      final reals = <double>[];
      for (final c in candidates) {
        final r = load(c.refCropPath);
        if (r != null) {
          refs.add((r, c.checkpoint, c.margin));
          reals.add(c.realScale);
        }
      }
      if (refs.isEmpty) {
        return const ZoomSourceDecision(reason: ZoomSourceReason.noClearRef);
      }
      return pickZoomSourceImages(
        finalArea: fin,
        refs: refs,
        realScales: reals,
        writeSource: (im) {
          final out = '${finalAreaPath}_source.jpg';
          File(
            out,
          ).writeAsBytesSync(img.encodeJpg(im, quality: 100), flush: true);
          return out;
        },
      );
    } catch (_) {
      return const ZoomSourceDecision(reason: ZoomSourceReason.error);
    }
  });
}

/// Does this shot need a sharp source? Cheap-phone ladder flow, past the
/// phone's own clear limit (observed per phone, else its optical limit),
/// and the final itself is not a clear photo. v11.61: the caller never
/// counts the final as clear past the per-device real-pixel clear limit.
/// Pure.
bool zoomNeedsSource({
  required bool ladderFlow,
  required double zoom,
  required double opticalLimit,
  double? clearLimit,
  required bool finalClear,
}) {
  if (!ladderFlow || finalClear) return false;
  final lim = math.max(
    opticalLimit.isFinite && opticalLimit >= 1 ? opticalLimit : 1.0,
    clearLimit ?? 0,
  );
  return zoom > lim + 0.01;
}
