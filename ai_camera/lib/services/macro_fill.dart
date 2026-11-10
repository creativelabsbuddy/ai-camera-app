import 'dart:convert';

import 'macro.dart';

/// v11.32 how much of the frame the subject fills (from the detection /
/// part check): [fill] 0..1 (1 = fills or overflows), [whole] = the whole
/// object is still in frame.
class FrameFill {
  const FrameFill({this.fill, this.whole});
  final double? fill;
  final bool? whole;

  bool get isEmpty => fill == null && whole == null;

  static FrameFill? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    final f = j['fill'], w = j['whole'];
    final fill = f is num ? f.toDouble().clamp(0.0, 1.0).toDouble() : null;
    final r = FrameFill(fill: fill, whole: w is bool ? w : null);
    return r.isEmpty ? null : r;
  }

  /// Raw model reply (JSON somewhere in the text) → fill, or null.
  static FrameFill? parse(String? text) {
    final t = text ?? '';
    final a = t.indexOf('{'), b = t.lastIndexOf('}');
    if (a < 0 || b <= a) return null;
    try {
      final j = jsonDecode(t.substring(a, b + 1));
      return j is Map<String, dynamic> ? fromJson(j) : null;
    } catch (_) {
      return null;
    }
  }
}

/// Macro unlocks at about half the frame.
const double kFillMacro = 0.45;

/// Close at roughly the full frame (or overflowing).
const double kFillClose = 0.85;

/// 0 none · 1 Macro · 2 Close · 3 Microscope / Extreme / Ultra (only a part
/// of the subject in frame). Unknown fill → everything unlocked (never
/// block on a missing answer). Pure.
int fillRank(FrameFill? f) {
  if (f == null || f.isEmpty) return 3;
  if (f.whole == false) return 3;
  final v = f.fill ?? 0;
  if (v >= kFillClose) return 2;
  if (v >= kFillMacro) return 1;
  return 0;
}

int _levelRank(MacroLevel l) => switch (l) {
  MacroLevel.macro => 1,
  MacroLevel.close => 2,
  _ => 3,
};

/// Is [level] unlocked by the frame fill? Pure.
bool macroLevelUnlocked(MacroLevel level, FrameFill? f) =>
    fillRank(f) >= _levelRank(level);

/// Chip lock: 1x / 1.5x are always free; every other chip follows its
/// level. Pure.
bool macroChipLocked(double chip, FrameFill? f) =>
    chip >= 1.99 && !macroLevelUnlocked(macroLevelFor(chip), f);

/// Guide while the chip's level is still locked.
const String kGuideZoomInSubject = 'Zoom in on your subject';

/// Guide when the frame stays blurry at the max useful zoom.
const String kGuideMoveCloser = 'Move a little closer';

/// v11.32 lock at any zoom: free on-device check that the centre looks
/// clear and substantial (sharp + some contrast/detail). Pure.
const double kAutoLockSharp = 40; // = kMacroSharpReady
const double kAutoLockDetail = 4; // centre mean |gradient| (0..255 grey)

bool centreLooksClear({required double sharpness, required double detail}) =>
    sharpness >= kAutoLockSharp && detail >= kAutoLockDetail;

/// Try the auto lock at this chip? Past 1.5x, no lock yet, nothing
/// running, not already tried at this chip. Pure.
bool shouldAutoLock({
  required double chip,
  required bool locked,
  required bool busy,
  required Set<double> tried,
  required double sharpness,
  required double detail,
}) =>
    chip > kMacroDetectZoom + 0.01 &&
    !locked &&
    !busy &&
    !tried.contains(chip) &&
    centreLooksClear(sharpness: sharpness, detail: detail);

/// Blurry at (or past) the device's max useful zoom → "Move a little
/// closer". Pure.
bool showMoveCloser({
  required double chip,
  required double maxUseful,
  required double sharpness,
}) => chip >= maxUseful - 0.01 && sharpness < kMacroSharpBlur;

/// Key builds: "fill 0.62 whole · lock 3x". Pure.
String fillDebugText(FrameFill? f, double? lockZoom) {
  final parts = <String>[];
  if (f == null || f.isEmpty) {
    parts.add('fill ?');
  } else {
    final w = f.whole == null ? '' : (f.whole! ? ' whole' : ' part');
    parts.add('fill ${f.fill?.toStringAsFixed(2) ?? '?'}$w');
  }
  parts.add(
    lockZoom == null
        ? 'no lock'
        : 'lock ${lockZoom.toStringAsFixed(lockZoom % 1 == 0 ? 0 : 1)}x',
  );
  return parts.join(' · ');
}
