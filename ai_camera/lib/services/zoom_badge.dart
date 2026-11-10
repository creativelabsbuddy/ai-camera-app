import '../models/quality_tier.dart';
import 'entitlements.dart';
import 'optical_profile.dart';
import 'zoom_range.dart';

const String kHighZoomWarning = 'Extreme zoom — AI will estimate details';
const String kTryFullHdHint = 'Try Full HD for better detail';
const String kAiProOnly = 'AI is Pro only';

/// HD hint appears when zoom is more than this × the optical limit.
const double kHdHintOverOptical = 2.0;

/// What the persistent top badge shows (Pro/AI mode only).
class ZoomBadgeInfo {
  const ZoomBadgeInfo({
    this.main,
    this.locked = false,
    this.trial = false,
    this.warning,
    this.hint,
  });

  static const none = ZoomBadgeInfo();

  /// e.g. "AI 30x · Ultra HD · 4 credits" or "AI is Pro only".
  final String? main;

  /// Free user above optical with the high-zoom trial already used.
  final bool locked;

  /// This shot would be covered by a starter trial (free).
  final bool trial;

  /// Above the AI-recoverable limit (~7× optical).
  final String? warning;

  /// Soft "try Full HD" suggestion — never forced.
  final String? hint;
}

ZoomBadgeInfo computeZoomBadge({
  required bool aiMode,
  required double zoom,
  required OpticalProfile optical,
  required QualityTier tier,
  required CreditState? state,
  required DateTime now,
}) {
  if (!aiMode) return ZoomBadgeInfo.none;
  final pro = state?.isPro(now) ?? false;
  final above = optical.isAboveOptical(zoom);
  final z = formatZoom(zoom);
  final warning = optical.isBeyondRecoverable(zoom) ? kHighZoomWarning : null;

  if (above && !pro) {
    final trialOk = state?.trialAvailable(StarterTrial.highZoom) ?? true;
    if (!trialOk) {
      return ZoomBadgeInfo(main: kAiProOnly, locked: true, warning: warning);
    }
    return ZoomBadgeInfo(
      main: 'AI ${z}x · ${tier.label} · free trial',
      trial: true,
      warning: warning,
      hint: _hint(tier, zoom, optical),
    );
  }
  final premiumTrial =
      !pro &&
      tier.isPremium &&
      (state?.trialAvailable(StarterTrial.premiumQuality) ?? true);
  final cost = premiumTrial
      ? 'free trial'
      : '${tier.credits} credit${tier.credits == 1 ? '' : 's'}';
  return ZoomBadgeInfo(
    main: 'AI ${z}x · ${tier.label} · $cost',
    trial: premiumTrial,
    warning: warning,
    hint: _hint(tier, zoom, optical),
  );
}

String? _hint(QualityTier tier, double zoom, OpticalProfile optical) =>
    tier == QualityTier.hd && optical.overOptical(zoom) > kHdHintOverOptical
    ? kTryFullHdHint
    : null;

/// Short, transient notice for the camera screen (shown briefly when it
/// changes — never a persistent banner). Priority: Pro-only lock → very high
/// zoom warning → soft Full HD hint → free starter-trial note.
String? zoomNotice(ZoomBadgeInfo info) {
  if (info.main == null) return null;
  if (info.locked) return kAiProOnly;
  if (info.warning != null) return info.warning;
  if (info.hint != null) return info.hint;
  if (info.trial) return kTrialNotice;
  return null;
}

const String kTrialNotice = 'This AI photo is free (starter trial)';
