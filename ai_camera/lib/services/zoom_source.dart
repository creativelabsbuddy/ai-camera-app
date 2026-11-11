import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

import 'ai_call.dart' show kNoSharpSourceMessage;
import 'capture_crop.dart' show sharpnessOf;
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

/// The final area inside a source must hold at least this many real
/// pixels on its long side (else it is not a usable source).
const int kZoomSourceMinPx = 96;

/// The source must be this much sharper than the final area (both at the
/// source's resolution); otherwise the final already holds the detail and
/// is enhanced alone (phones with a good lens at that zoom).
const double kZoomSourceSharperBy = 1.15;

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

  /// The final itself is as sharp as any matching source (use it alone).
  finalSharp,

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
      ZoomSourceReason.finalSharp =>
        'src final (sharp enough${t.isEmpty ? '' : ': $t'})',
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
  });
  final String refCropPath;
  final double checkpoint;

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
ZoomSourceDecision pickZoomSourceImages({
  required img.Image finalArea,
  required List<(img.Image, double, double)> refs,
  required String Function(img.Image) writeSource,
}) {
  if (refs.isEmpty) {
    return const ZoomSourceDecision(reason: ZoomSourceReason.noClearRef);
  }
  final (pw, ph) = proxySize(finalArea.width, finalArea.height);
  final fg = greyOf(finalArea, pw, ph);
  final tries = <ZoomSourceTry>[];
  var anyMatchSmall = false;
  var anyMatchNotSharper = false;
  for (final (ref, cp, m) in refs) {
    final margin = math.max(1.0, m);
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
    if (math.max(cw, chh) < kZoomSourceMinPx) {
      anyMatchSmall = true;
      tries.add(ZoomSourceTry(cp, score, 'small'));
      continue;
    }
    final src = img.copyCrop(ref, x: x, y: y, width: cw, height: chh);
    // Sharpness at the SAME resolution (the source's): does the source
    // really hold more detail than the final area?
    final fin = img.copyResize(
      finalArea,
      width: cw,
      height: chh,
      interpolation: img.Interpolation.average,
    );
    final ss = sharpnessOf(_cap512(src));
    final fs = sharpnessOf(_cap512(fin));
    final ratio = fs <= 0 ? (ss > 0 ? 99.0 : 1.0) : ss / fs;
    if (ratio < kZoomSourceSharperBy) {
      anyMatchNotSharper = true;
      tries.add(ZoomSourceTry(cp, score, 'not sharper'));
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
    reason: anyMatchNotSharper
        ? ZoomSourceReason.finalSharp
        : anyMatchSmall
        ? ZoomSourceReason.tooSmall
        : ZoomSourceReason.noMatch,
    tries: tries,
  );
}

img.Image _cap512(img.Image im) => math.max(im.width, im.height) > 512
    ? img.copyResize(
        im,
        width: im.width >= im.height ? 512 : null,
        height: im.height > im.width ? 512 : null,
      )
    : im;

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
      for (final c in candidates) {
        final r = load(c.refCropPath);
        if (r != null) refs.add((r, c.checkpoint, c.margin));
      }
      if (refs.isEmpty) {
        return const ZoomSourceDecision(reason: ZoomSourceReason.noClearRef);
      }
      return pickZoomSourceImages(
        finalArea: fin,
        refs: refs,
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
/// and the final itself is not a clear photo. Pure.
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
