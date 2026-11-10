import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../models/quality_tier.dart';
import 'night_pipeline.dart' show mergeFrames;

/// v11.9 context snapshot: a full-quality still taken silently while the
/// user is at low zoom (≤3x). On shutter at a higher zoom the AI gets this
/// sharp low-zoom frame with the zoomed region boxed, plus the crop.
class ContextSnapshot {
  const ContextSnapshot({
    required this.path,
    required this.cameraZoom,
    required this.at,
    this.thumb,
  });

  final String path;

  /// Camera zoom of the still (the still covers 1/cameraZoom of 1x FOV).
  final double cameraZoom;
  final DateTime at;

  /// Analysis thumbnail at that moment (scene-change refresh).
  final Uint8List? thumb;
}

/// Snapshots are taken at or below this user zoom.
const double kSnapshotMaxZoom = 3.0;

/// Refresh an old snapshot after this long at low zoom.
const Duration kSnapshotMaxAge = Duration(seconds: 20);

/// Zoom must settle this long before a snapshot.
const Duration kSnapshotSettle = Duration(milliseconds: 900);

/// Use the snapshot only when the shot is clearly zoomed past it.
const double kSnapshotMinRatio = 1.5;

bool atSnapshotZoom(double zoom) => zoom <= kSnapshotMaxZoom + 0.01;

/// Take (or refresh) a snapshot now?
bool shouldTakeSnapshot({
  required double zoom,
  required ContextSnapshot? existing,
  required DateTime now,
  double sceneChange = 0,
  double sceneChangeLimit = 0.16,
}) {
  if (!atSnapshotZoom(zoom)) return false;
  if (existing == null) return true;
  if (now.difference(existing.at) > kSnapshotMaxAge) return true;
  return sceneChange >= sceneChangeLimit;
}

/// Where the user's zoom region sits inside the snapshot: a centred crop
/// with this digital-zoom factor (user zoom ÷ snapshot camera zoom).
double snapshotRegionZoom(double userZoom, double snapCameraZoom) =>
    userZoom / math.max(0.3, snapCameraZoom);

/// Send the snapshot (boxed) instead of the plain context?
bool useSnapshot(ContextSnapshot? s, double userZoom) =>
    s != null &&
    snapshotRegionZoom(userZoom, s.cameraZoom) >= kSnapshotMinRatio;

/// Default Full HD from 30x unless the user picked a quality.
QualityTier tierForZoom(QualityTier tier, double zoom, {bool picked = false}) =>
    !picked && zoom >= 30 - 0.01 && tier == QualityTier.hd
    ? QualityTier.fullHd
    : tier;

/// Multi-frame merge for high zoom on low-end phones (≥2x past optical).
bool shouldMergeZoom({
  required bool lowEnd,
  required double zoom,
  required double opticalLimit,
}) =>
    // v11.39: cheap phones merge from 2x (2x–10x and beyond), not only 2x
    // past the optical lens.
    lowEnd && (zoom >= 2.0 || zoom / math.max(1.0, opticalLimit) >= 2.0);

/// Frames for the low-end high-zoom merge (8–10).
const int kZoomMergeFrames = 4; // v11.30 (was 8): shorter hold

/// Sharpest frames kept for the average.
const int kZoomMergeKeep = 4; // v11.30

/// Indices of the [keep] sharpest frames, sharpest first.
List<int> sharpestFirst(List<double> scores, {int keep = kZoomMergeKeep}) {
  final idx = List<int>.generate(scores.length, (i) => i)
    ..sort((a, b) => scores[b].compareTo(scores[a]));
  return idx.take(math.max(1, keep)).toList();
}

/// "Hold steady · N" countdown text (frames left).
String holdSteadyCountdown(int left) => 'Hold steady · $left';

/// Aligns + averages the zoomed region (centre 1/[crop], with margin) of
/// [paths] (sharpest first) and pastes it into the sharpest full frame.
/// Returns (path, frames used). Background isolate.
Future<(String, int, List<double>)> mergeZoomRegion(
  List<String> paths,
  double crop,
  String outDir,
) => Isolate.run(() => _mergeRegionSync(paths, crop, outDir));

(String, int, List<double>) _mergeRegionSync(
  List<String> paths,
  double crop,
  String outDir,
) {
  final raw = img.decodeImage(File(paths.first).readAsBytesSync());
  if (raw == null) return (paths.first, 1, const <double>[]);
  final full = img.bakeOrientation(raw);
  final f = math.min(1.0, 1.25 / math.max(1.0, crop));
  final rw = math.max(16, (full.width * f).round());
  final rh = math.max(16, (full.height * f).round());
  final x = (full.width - rw) ~/ 2, y = (full.height - rh) ~/ 2;
  final crops = <img.Image>[
    img.copyCrop(full, x: x, y: y, width: rw, height: rh),
  ];
  for (final path in paths.skip(1)) {
    final r = img.decodeImage(File(path).readAsBytesSync());
    if (r == null) continue;
    final u = img.bakeOrientation(r);
    if (u.width != full.width || u.height != full.height) continue;
    crops.add(img.copyCrop(u, x: x, y: y, width: rw, height: rh));
  }
  if (crops.length < 2) return (paths.first, 1, const <double>[]);
  // v11.30: edge alignment, sub-pixel, median; < 2 good → sharpest alone.
  final m = mergeFrames(crops, median: true);
  if (m.used < 2) return (paths.first, 1, m.errors);
  img.compositeImage(full, m.image, dstX: x, dstY: y);
  full.exif.imageIfd.orientation = null;
  final out = p.join(
    outDir,
    'zoommerge_${DateTime.now().millisecondsSinceEpoch}.jpg',
  );
  File(out).writeAsBytesSync(img.encodeJpg(full, quality: 95), flush: true);
  return (out, m.used, m.errors);
}
