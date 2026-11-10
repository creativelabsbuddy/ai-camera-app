import 'dart:math' as math;

import '../models/camera_options.dart';
import '../models/capture_mode.dart';

/// v11 Night tone: "bright" = NORMAL Night (Samsung-like bright, free),
/// "natural" = PRO AI Night before the AI (keeps a real night look).
enum NightTone { bright, natural }

/// What one Night shot does. Pure → unit tested.
class NightPlan {
  const NightPlan({
    required this.frames,
    required this.countdownSeconds,
    required this.tone,
    required this.boost,
    required this.maxFrameMs,
    required this.fallbackEv,
    required this.useFlash,
  });

  /// Burst length (8–15; 1 when the flash fires).
  final int frames;

  /// "Hold still" countdown before the burst (1–3 s; 0 with flash).
  final int countdownSeconds;
  final NightTone tone;

  /// Total exposure multiplier vs. the metered exposure (manual sensor).
  final double boost;

  /// Longest per-frame shutter for the manual burst (hand-held limit).
  final int maxFrameMs;

  /// Exposure compensation for the plugin fallback burst.
  final double fallbackEv;

  /// Flash single shot instead of a burst (Flash On, or Auto in the dark).
  final bool useFlash;

  bool get burst => frames > 1;

  @override
  String toString() =>
      'NightPlan(frames=$frames, countdown=${countdownSeconds}s, '
      'tone=${tone.name}, boost=$boost, maxFrame=${maxFrameMs}ms, '
      'ev=$fallbackEv, flash=$useFlash)';
}

/// Live luma below this = "very dark" (Flash Auto fires, longest burst).
const double kNightVeryDarkLuma = 0.06;

/// Plans a Night shot from the live preview brightness [luma] (0..1, the
/// preview is already auto-exposed so this only separates "dark" from
/// "very dark"), the capture tab and the Night flash choice.
/// v11.48: Pro Night frame count (Normal keeps 8–15).
const int kProNightFrames = 4;

NightPlan planNight({
  required double luma,
  required CaptureMode mode,
  FlashChoice flash = FlashChoice.off,
  double maxExposureOffset = 0,
}) {
  final pro = mode == CaptureMode.pro;
  final l = luma.isFinite ? luma.clamp(0.0, 1.0) : 0.5;
  final useFlash =
      flash == FlashChoice.on ||
      (flash == FlashChoice.auto && l < kNightVeryDarkLuma);
  final maxEv = maxExposureOffset.isFinite && maxExposureOffset > 0
      ? maxExposureOffset
      : 0.0;
  if (useFlash) {
    return NightPlan(
      frames: 1,
      countdownSeconds: 0,
      tone: pro ? NightTone.natural : NightTone.bright,
      boost: 1,
      maxFrameMs: 66,
      fallbackEv: 0,
      useFlash: true,
    );
  }
  final int frames;
  final int countdown;
  final int maxFrameMs;
  if (l < kNightVeryDarkLuma) {
    frames = 15;
    countdown = 3;
    maxFrameMs = 125;
  } else if (l < 0.12) {
    frames = 12;
    countdown = 2;
    maxFrameMs = 110;
  } else if (l < 0.22) {
    frames = 10;
    countdown = 2;
    maxFrameMs = 90;
  } else {
    frames = 8;
    countdown = 1;
    maxFrameMs = 70;
  }
  return NightPlan(
    // v11.48: Pro Night stacks ~4 frames (the AI cleans up the rest).
    frames: pro ? kProNightFrames : frames,
    countdownSeconds: pro ? math.min(countdown, 1) : countdown,
    tone: pro ? NightTone.natural : NightTone.bright,
    boost: pro ? 1.15 : 1.6,
    maxFrameMs: maxFrameMs,
    fallbackEv: math.min(pro ? 1.0 : 2.0, maxEv),
    useFlash: false,
  );
}

// ---------------------------------------------------------------------------
// Tone curve (mirrors NightTone in android/.../NightMerge.kt)
// ---------------------------------------------------------------------------

class NightToneParams {
  const NightToneParams({
    required this.targetMean,
    required this.maxShadowGain,
  });
  final double targetMean;
  final double maxShadowGain;

  static const bright = NightToneParams(targetMean: 0.38, maxShadowGain: 6);
  static const natural = NightToneParams(targetMean: 0.20, maxShadowGain: 2.5);

  static NightToneParams of(NightTone t) =>
      t == NightTone.natural ? natural : bright;
}

/// S(y) = (1 − e^(−a·y)) / (1 − e^(−a)): lifts shadows, never clips.
double nightCurve(double y, double a) =>
    a < 1e-3 ? y : (1 - math.exp(-a * y)) / (1 - math.exp(-a));

/// Shadow gain S'(0).
double nightSlope0(double a) => a < 1e-3 ? 1 : a / (1 - math.exp(-a));

double nightMaxA(double maxGain) {
  var lo = 0.0, hi = 40.0;
  for (var i = 0; i < 50; i++) {
    final mid = (lo + hi) / 2;
    if (nightSlope0(mid) > maxGain) {
      hi = mid;
    } else {
      lo = mid;
    }
  }
  return lo;
}

/// Solves `a` so the mean of S over [luma] samples (0..1) reaches the
/// tone's target (never darkens; shadow gain capped).
double solveNightA(List<double> luma, NightTone tone) {
  final p = NightToneParams.of(tone);
  if (luma.isEmpty) return 0;
  double meanFor(double a) =>
      luma.fold<double>(0, (s, y) => s + nightCurve(y, a)) / luma.length;
  final aMax = nightMaxA(p.maxShadowGain);
  if (meanFor(0) >= p.targetMean) return 0;
  if (meanFor(aMax) <= p.targetMean) return aMax;
  var lo = 0.0, hi = aMax;
  for (var i = 0; i < 40; i++) {
    final mid = (lo + hi) / 2;
    if (meanFor(mid) < p.targetMean) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return (lo + hi) / 2;
}
