import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

import 'macro.dart' show isClearPhoto;

/// v11.30 100x zoom ladder (cheap phones): while the user zooms, a normal
/// camera photo (free, no AI) is kept at each checkpoint passed. At the
/// shutter ONE AI call gets ≤3 boxed reference photos + the final photo.
const List<double> kLadderCheckpoints = [
  2,
  3,
  4,
  6,
  8,
  12,
  16,
  24,
  32,
  48,
  64,
  100,
];

/// Most reference photos sent (plus the final photo = 4 images).
const int kLadderMaxRefs = 3;

/// Reference crops are sent at this long side (v11.31).
const int kLadderImageLong = 768;

/// v11.31 the final photo goes FIRST, at this long side (or native).
const int kLadderMainLong = 1536;

/// v11.31 references = only the final-frame area of each reference photo,
/// plus this margin (1.15 = 15 % wider), no drawn box.
const double kLadderRefMargin = 1.15;

/// Long side actually uploaded for an image of [w]×[h] capped at [cap].
String sentSize(int w, int h, int cap) {
  final long = math.max(w, h);
  if (long <= cap || long == 0) return '${w}x$h';
  final s = cap / long;
  return '${(w * s).round()}x${(h * s).round()}';
}

/// Key builds: "sizes 1536x1152 (final) + 768x576, 640x480".
String ladderSizesText((int, int) finalWh, List<(int, int)> refs) {
  final f = sentSize(finalWh.$1, finalWh.$2, kLadderMainLong);
  if (refs.isEmpty) return 'sizes $f (final)';
  final r = refs.map((e) => sentSize(e.$1, e.$2, kLadderImageLong)).join(', ');
  return 'sizes $f (final) + $r';
}

/// Zoom must rest this long past a checkpoint before its photo.
const Duration kLadderSettle = Duration(milliseconds: 350);

/// One-time note (SharedPreferences key + text).
const String kLadderNoteKey = 'zoom_ladder_note_v1';
const String kLadderNote = 'Small text may not be accurate at high zoom.';

/// Ladder photos only exist where the camera really zooms: checkpoints
/// above the camera's own max would be the same photo (digital crop), so
/// they collapse into one checkpoint at [hardwareMax]. Pure.
List<double> ladderCheckpoints(double hardwareMax) {
  final hw = hardwareMax.isFinite && hardwareMax > 1 ? hardwareMax : 1.0;
  final out = [
    for (final c in kLadderCheckpoints)
      if (c <= hw + 0.01) c,
  ];
  if (hw > 1.5 && (out.isEmpty || hw - out.last > 0.25)) out.add(hw);
  return out;
}

class LadderShot {
  const LadderShot({
    required this.checkpoint,
    required this.path,
    required this.cameraZoom,
    required this.sharpness,
  });

  final double checkpoint;
  final String path;

  /// Camera zoom of the photo (the photo covers 1/cameraZoom of 1x FOV).
  final double cameraZoom;
  final double sharpness;
}

String _x(double z) =>
    '${z == z.roundToDouble() ? z.toStringAsFixed(0) : z.toStringAsFixed(1)}x';

/// Checkpoint photos for one zoom session. Not thread-safe; UI isolate.
class ZoomLadder {
  ZoomLadder({required double hardwareMax})
    : checkpoints = ladderCheckpoints(hardwareMax);

  final List<double> checkpoints;
  final Map<double, LadderShot> _shots = {};

  List<LadderShot> get shots =>
      (_shots.values.toList()
        ..sort((a, b) => a.checkpoint.compareTo(b.checkpoint)));

  /// Highest checkpoint passed at [zoom] that has no photo yet, or null.
  /// (Lower missed checkpoints are skipped: the photo is taken where the
  /// zoom actually is.)
  double? due(double zoom) {
    double? best;
    for (final c in checkpoints) {
      if (c <= zoom + 0.01 && !_shots.containsKey(c)) best = c;
    }
    if (best == null) return null;
    // A photo of a higher checkpoint already covers this zoom.
    if (_shots.keys.any((k) => k > best!)) return null;
    return best;
  }

  /// Zoomed back out: photos above [zoom] are dropped (retaken on the next
  /// zoom-in). Returns the dropped photo paths (to delete).
  List<String> zoomedTo(double zoom) {
    final gone = [
      for (final k in _shots.keys)
        if (k > zoom + 0.01) k,
    ];
    return [for (final k in gone) _shots.remove(k)!.path];
  }

  void add(LadderShot s) => _shots[s.checkpoint] = s;

  /// v11.34 checkpoints that already have a photo.
  Set<double> get takenCheckpoints => _shots.keys.toSet();

  /// v11.34 a lower checkpoint than [cp] has no photo (it was skipped).
  /// Only counts checkpoints above the lowest photo of this chain.
  bool missedBelow(double cp) {
    if (_shots.isEmpty) return false;
    final lo = shots.first.checkpoint;
    return checkpoints.any(
      (c) => c > lo + 0.01 && c < cp - 0.01 && !_shots.containsKey(c),
    );
  }

  /// v11.34 nearest photo below [cp] (to compare the subject), or null.
  LadderShot? below(double cp) {
    LadderShot? best;
    for (final s in shots) {
      if (s.checkpoint < cp - 0.01) best = s;
    }
    return best;
  }

  /// Removes everything (lens change / mode change). Returns the paths.
  List<String> clear() {
    final p = [for (final s in _shots.values) s.path];
    _shots.clear();
    return p;
  }

  /// Sharpness reference = the lowest checkpoint photo.
  double get _ref => shots.isEmpty ? 0 : shots.first.sharpness;

  bool isClear(LadderShot s) => isClearPhoto(s.sharpness, _ref);

  /// Highest-zoom clear photo.
  LadderShot? get lastClear {
    LadderShot? best;
    for (final s in shots) {
      if (isClear(s)) best = s;
    }
    return best;
  }

  /// References for a shutter at [finalZoom]: the last clear photo + the
  /// 1–2 photos nearest below the final zoom, ≤[kLadderMaxRefs], lowest
  /// zoom first. Only photos zoomed clearly wider than the final shot.
  List<LadderShot> selectRefs(double finalZoom) {
    final below = [
      for (final s in shots)
        if (finalZoom / math.max(0.3, s.cameraZoom) >= 1.05) s,
    ];
    if (below.isEmpty) return const [];
    final lc = lastClear;
    final pick = <LadderShot>{};
    if (lc != null && below.contains(lc)) pick.add(lc);
    for (final s in below.reversed) {
      if (pick.length >= kLadderMaxRefs) break;
      if (pick.where((p) => p != lc).length >= 2) break;
      pick.add(s);
    }
    return pick.toList()..sort((a, b) => a.cameraZoom.compareTo(b.cameraZoom));
  }

  /// v11.59: lowest-checkpoint sharpness (the chain's clear reference).
  double get refSharpness => _ref;

  /// v11.59 nearest CLEAR photo below [cp] (subject checks compare clear
  /// photos only; a blurry checkpoint never breaks the chain).
  LadderShot? lastClearBelow(double cp) {
    LadderShot? best;
    for (final s in shots) {
      if (s.checkpoint < cp - 0.01 && isClear(s)) best = s;
    }
    return best;
  }

  /// v11.59 sharp-source candidates for a shutter at [finalZoom]: CLEAR
  /// photos only, clearly wider than the final, best first (highest zoom =
  /// most real pixels on the final area; tie → sharper), at most [max].
  List<LadderShot> sourceCandidates(
    double finalZoom, {
    int max = kLadderMaxRefs,
  }) {
    final c =
        [
          for (final s in shots)
            if (isClear(s) && finalZoom / math.max(0.3, s.cameraZoom) >= 1.05)
              s,
        ]..sort((a, b) {
          final z = b.cameraZoom.compareTo(a.cameraZoom);
          return z != 0 ? z : b.sharpness.compareTo(a.sharpness);
        });
    return c.take(max).toList();
  }

  /// Key builds: "Ladder: 2x✓ 3x✓ 4x✗ · last clear 3x · sent 3x, 4x + final".
  String debugText({List<LadderShot>? sent}) {
    final caps = shots.isEmpty
        ? 'none'
        : shots
              .map((s) => '${_x(s.checkpoint)}${isClear(s) ? '✓' : '✗'}')
              .join(' ');
    final lc = lastClear;
    final b = StringBuffer('Ladder: $caps · last clear ')
      ..write(lc == null ? '–' : _x(lc.checkpoint));
    if (sent != null) {
      b.write(' · sent ');
      b.write(
        sent.isEmpty
            ? 'final only'
            : '${sent.map((s) => _x(s.checkpoint)).join(', ')} + final',
      );
    }
    return b.toString();
  }
}

/// Which 100x flow at the shutter. Pure.
enum ZoomFlow { normal, flagshipSingle, ladder }

/// From the first checkpoint (2x) up: flagship phones send one photo
/// (no context / step photos, no merge); cheap phones use the ladder.
ZoomFlow zoomFlowFor({
  required bool ai,
  required bool lowEnd,
  required double zoom,
}) {
  if (!ai || zoom < kLadderCheckpoints.first - 0.01) return ZoomFlow.normal;
  return lowEnd ? ZoomFlow.ladder : ZoomFlow.flagshipSingle;
}

(int, int) _jpegSize(String path) {
  try {
    final info = img.JpegDecoder().startDecode(File(path).readAsBytesSync());
    if (info != null) return (info.width, info.height);
  } catch (_) {}
  return (0, 0);
}

/// Sizes of the files about to be sent (header read only).
String ladderSizesFor(String finalPath, List<String> refPaths) =>
    ladderSizesText(_jpegSize(finalPath), [
      for (final p in refPaths) _jpegSize(p),
    ]);
