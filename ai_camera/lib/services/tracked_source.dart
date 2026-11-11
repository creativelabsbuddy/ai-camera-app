import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

import 'burst_merge.dart'
    show
        RgbFrame,
        decodeRegion,
        deleteQuietly,
        dartRegionReader,
        lumaGrey,
        nativeRegion,
        uprightSize;
import 'image_register.dart';
import 'zoom_ladder.dart' show LadderShot;
import 'zoom_root.dart' show roiTooTiny;
import 'zoom_source.dart' show ZoomSourceCandidate;
import 'zoom_tracker.dart';

/// v11.60: sharp-source candidates from TRACKED references. The final
/// region (the user's exact framing) is located inside each clear
/// reference through the accumulated tracking transforms, cut with a
/// small search margin and handed to the strict [pickZoomSource] check
/// (which must still verify the match and the sharpness gain).

/// Search margin around the tracked region (residual tracking error and
/// the motion between the analysis frame and the still).
const double kTrackedSourceMargin = 1.3;

/// Pixel rect (x, y, w, h) of a tracked region [roi] (ref-normalised
/// coords) in a W×H still, grown by [margin] about its centre and kept
/// inside the image (shifted, or the margin reduced). Also returns the
/// margin really used and the region's own long side in pixels. Pure.
((int, int, int, int), double, double) roiPixelRect(
  NRect roi,
  int w,
  int h, {
  double margin = kTrackedSourceMargin,
}) {
  final rw = roi.w * w, rh = roi.h * w;
  final m = math.max(1.0, math.min(margin, math.min(w / rw, h / rh)));
  final cw = math.min(w.toDouble(), rw * m),
      ch = math.min(h.toDouble(), rh * m);
  final cx = (roi.cx + 0.5) * w, cy = roi.cy * w + h / 2;
  final x = (cx - cw / 2).clamp(0.0, w - cw),
      y = (cy - ch / 2).clamp(0.0, h - ch);
  return ((x.round(), y.round(), cw.round(), ch.round()), m, math.max(rw, rh));
}

class TrackedCandidates {
  const TrackedCandidates(this.candidates, this.notes, this.files);
  final List<ZoomSourceCandidate> candidates;

  /// Per reference: "4x roi" / "2x outside" / "3x aspect".
  final List<String> notes;

  /// Temporary crops (delete after use).
  final List<String> files;
}

/// Builds the candidates (best first as given). [finalFrac] = (width,
/// height) of the final visible region as fractions of the still
/// (centre ratio crop + digital zoom) in the SHUTTER still's own axes;
/// [shutterRot] = that still's quarter turns from the analysis view (each
/// ref carries its own [LadderShot.stillRot]); [trackAspect] = analysis h/w.
Future<TrackedCandidates> trackedSourceCandidates({
  required List<LadderShot> refs,
  required Similarity rootToCur,
  required double trackAspect,
  required (double, double) finalFrac,
  required String outDir,
  int shutterRot = 0,
}) async {
  final cands = <ZoomSourceCandidate>[];
  final notes = <String>[];
  final files = <String>[];
  final roiCur = finalRoiInAnalysis(
    finalFrac.$1,
    finalFrac.$2,
    trackAspect,
    shutterRot,
  );
  String z(double v) => '${v.toStringAsFixed(1)}x';
  for (final r in refs) {
    final t = r.rootToRef;
    if (t == null) {
      notes.add('${z(r.cameraZoom)} untracked');
      continue;
    }
    int w, h;
    try {
      (w, h) = await uprightSize(r.path);
    } catch (_) {
      notes.add('${z(r.cameraZoom)} unreadable');
      continue;
    }
    final want = r.stillRot.isOdd ? 1 / trackAspect : trackAspect;
    if ((h / w - want).abs() > kTrackAspectTol * want) {
      notes.add('${z(r.cameraZoom)} aspect');
      continue;
    }
    final roi = roiInRef(
      rootToCur: rootToCur,
      ref: TrackedRef(
        path: r.path,
        cameraZoom: r.cameraZoom,
        rootToRef: t,
        sharpness: r.sharpness,
      ),
      finalRoi: roiCur,
      aspect: trackAspect,
    );
    if (roi == null) {
      notes.add('${z(r.cameraZoom)} outside');
      continue;
    }
    final (rect, m, longPx) = roiPixelRect(
      roiToStill(roi, trackAspect, r.stillRot, w, h),
      w,
      h,
    );
    // v11.61: REAL pixels (a digital-crop reference's upscaled pixels do
    // not count); only an absurdly tiny region is rejected here.
    final lab = r.zoomLabel;
    final realPx = longPx * lab.realScale;
    final tag = '${r.root ? 'root ' : ''}${z(r.cameraZoom)}';
    if (roiTooTiny(realPx)) {
      notes.add('$tag tiny ${realPx.round()}px');
      continue;
    }
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final rgb = '$outDir/trk_$stamp.rgb';
    final jpg = '$outDir/trk_$stamp.jpg';
    try {
      final (_, dw, dh) = await decodeRegion(r.path, rect, rgb);
      await Isolate.run(() {
        final bytes = File(rgb).readAsBytesSync();
        final im = img.Image.fromBytes(
          width: dw,
          height: dh,
          bytes: bytes.buffer,
          numChannels: 3,
        );
        File(jpg).writeAsBytesSync(img.encodeJpg(im, quality: 95), flush: true);
      });
      files.add(jpg);
      cands.add(
        ZoomSourceCandidate(
          jpg,
          r.cameraZoom,
          margin: m,
          realScale: lab.realScale,
          label: '$tag ${lab.text}',
        ),
      );
      notes.add('$tag roi ${realPx.round()}px ${lab.text}');
    } catch (_) {
      notes.add('${z(r.cameraZoom)} decode');
    } finally {
      deleteQuietly([rgb]);
    }
  }
  return TrackedCandidates(cands, notes, files);
}

/// Grey proxy of a still (upright, as saved), long side ≈ [long] px, for
/// the rotation check. Native sampled decode; Dart fallback.
Future<GreyImage> stillProxy(String path, {int long = 96}) async {
  final (w, h) = await uprightSize(path);
  var sample = 1;
  while (math.max(w, h) / (sample * 2) >= long * 2) {
    sample *= 2;
  }
  RgbFrame f;
  try {
    f = await nativeRegion(path, (0, 0, w, h), sample);
  } catch (_) {
    f = await Isolate.run(() => dartRegionReader()(path, (0, 0, w, h), sample));
  }
  final g = lumaGrey(f);
  final s = long / math.max(g.width, g.height);
  return resizeGrey(
    g,
    math.max(8, (g.width * s).round()),
    math.max(8, (g.height * s).round()),
  );
}
