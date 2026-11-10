import 'dart:math' as math;

import '../models/products.dart';
import '../models/quality_tier.dart';

/// Credits / Pro / starter-trial rules. Pure Dart (no Flutter, no I/O) so the
/// exact same logic runs in [LocalLedger] (test APK) and is mirrored 1:1 in
/// enhance-server/ledger.py (production). Unit tested on both sides.
///
/// Rules (locked with Ankush):
/// * Free: 2 HD credits per day, reset at local midnight IST, no rollover,
///   no stacking. Free daily credits only pay for HD shots.
/// * Pro ₹99/month: 100 credits per 30-day period (reset, no rollover) and
///   unlocks AI above optical zoom, AI filters, prompt library, own prompt.
/// * Packs: credits that never expire; usable by anyone for any tier.
/// * Cost = quality tier only (1/2/4/8). Charged only after a successful AI
///   result; failures cost nothing.
/// * Starter pack (one per device): 1 high-zoom AI shot, 1 AI filter,
///   1 Ultra HD/4K shot. (v11.57: library style is no longer a free trial.)
///   A shot that uses a starter trial is free. Pro users never burn trials.

const int kFreeDailyCredits = 2;
const Duration kProPeriod = Duration(days: 30);
const Duration kIstOffset = Duration(hours: 5, minutes: 30);
const int kMaxCustomPromptChars = 200;

enum StarterTrial {
  highZoom('high_zoom', 'High-zoom AI shot'),
  aiFilter('ai_filter', 'AI filter'),
  libraryStyle('library_style', 'Library style'),
  premiumQuality('uhd_4k', 'Ultra HD / 4K shot');

  const StarterTrial(this.id, this.label);

  final String id;
  final String label;

  static StarterTrial? fromId(String id) {
    for (final t in StarterTrial.values) {
      if (t.id == id) return t;
    }
    return null;
  }
}

/// IST calendar date (yyyy-mm-dd) of [t]. Daily free credits reset when this
/// changes (local midnight India time, regardless of phone timezone).
String istDate(DateTime t) {
  final ist = t.toUtc().add(kIstOffset);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${ist.year.toString().padLeft(4, '0')}-${two(ist.month)}-${two(ist.day)}';
}

class CreditState {
  const CreditState({
    required this.freeDaily,
    required this.freeDailyDate,
    required this.subCredits,
    required this.proUntil,
    required this.packCredits,
    required this.trialsUsed,
  });

  /// Brand-new device: full free credits for [now]'s IST day, nothing else.
  factory CreditState.initial(DateTime now) => CreditState(
    freeDaily: kFreeDailyCredits,
    freeDailyDate: istDate(now),
    subCredits: 0,
    proUntil: null,
    packCredits: 0,
    trialsUsed: const {},
  );

  factory CreditState.fromJson(Map<String, Object?> j) {
    int i(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
    final pu = j['pro_until'];
    final trials = j['trials_used'];
    return CreditState(
      freeDaily: i(j['free_daily']),
      freeDailyDate: '${j['free_daily_date'] ?? ''}',
      subCredits: i(j['sub_credits']),
      proUntil: pu == null || '$pu'.isEmpty
          ? null
          : DateTime.tryParse('$pu')?.toUtc(),
      packCredits: i(j['pack_credits']),
      trialsUsed: trials is List
          ? trials
                .map((e) => StarterTrial.fromId('$e'))
                .whereType<StarterTrial>()
                .toSet()
          : const {},
    );
  }

  final int freeDaily;
  final String freeDailyDate;
  final int subCredits;
  final DateTime? proUntil;
  final int packCredits;
  final Set<StarterTrial> trialsUsed;

  bool isPro(DateTime now) =>
      proUntil != null && now.toUtc().isBefore(proUntil!.toUtc());

  /// Credits the user can spend right now (sub credits only while Pro).
  int total(DateTime now) =>
      freeDaily + (isPro(now) ? subCredits : 0) + packCredits;

  bool trialAvailable(StarterTrial t) => !trialsUsed.contains(t);

  CreditState copyWith({
    int? freeDaily,
    String? freeDailyDate,
    int? subCredits,
    DateTime? proUntil,
    bool clearProUntil = false,
    int? packCredits,
    Set<StarterTrial>? trialsUsed,
  }) => CreditState(
    freeDaily: freeDaily ?? this.freeDaily,
    freeDailyDate: freeDailyDate ?? this.freeDailyDate,
    subCredits: subCredits ?? this.subCredits,
    proUntil: clearProUntil ? null : (proUntil ?? this.proUntil),
    packCredits: packCredits ?? this.packCredits,
    trialsUsed: trialsUsed ?? this.trialsUsed,
  );

  Map<String, Object?> toJson() => {
    'free_daily': freeDaily,
    'free_daily_date': freeDailyDate,
    'sub_credits': subCredits,
    'pro_until': proUntil?.toUtc().toIso8601String(),
    'pack_credits': packCredits,
    'trials_used': [for (final t in trialsUsed) t.id]..sort(),
  };

  @override
  String toString() => 'CreditState(${toJson()})';
}

/// Daily reset (IST midnight, SET to 2 — never added, so no rollover /
/// stacking) and Pro expiry (unused sub credits are dropped).
CreditState refreshState(CreditState s, DateTime now) {
  var out = s;
  final today = istDate(now);
  if (out.freeDailyDate != today) {
    out = out.copyWith(freeDaily: kFreeDailyCredits, freeDailyDate: today);
  }
  if (out.proUntil != null && !out.isPro(now) && out.subCredits != 0) {
    out = out.copyWith(subCredits: 0);
  }
  return out;
}

/// What one AI enhance asks for.
class EnhanceSpec {
  const EnhanceSpec({
    required this.tier,
    this.zoom = 1.0,
    this.opticalLimit = 1.0,
    this.aiFilter = false,
    this.libraryStyle = false,
    this.customStyle = false,
    this.customPrompt = false,
    this.creditsOverride,
  });

  final QualityTier tier;

  /// v11.26 Macro: credits by level (2 / 5) instead of the tier's.
  final int? creditsOverride;

  /// Credits this shot costs.
  int get credits => creditsOverride ?? tier.credits;

  /// User-facing capture zoom (camera × digital). Gallery = 1.
  final double zoom;

  /// Device optical-quality limit (OpticalProfile.opticalLimit).
  final double opticalLimit;

  /// AI filter on the preview screen (Studio, Cinematic, …).
  final bool aiFilter;

  /// Built-in prompt-library style from the strip above the shutter.
  final bool libraryStyle;

  /// User-created library style (name + own prompt) — Pro only.
  final bool customStyle;

  /// Typed own prompt — Pro only.
  final bool customPrompt;

  /// Same 2% tolerance as OpticalProfile.isAboveOptical.
  bool get highZoom =>
      zoom.isFinite && zoom > math.max(1.0, opticalLimit) * 1.02;
}

enum DenyReason {
  /// Free user, AI above optical zoom, high-zoom trial used.
  zoomNeedsPro,
  filterNeedsPro,
  styleNeedsPro,
  promptNeedsPro,

  /// Not enough credits for the chosen tier.
  noCredits,

  /// Invalid request (e.g. variations out of range).
  badRequest,
}

class EnhanceDecision {
  const EnhanceDecision._({
    required this.allowed,
    this.reason,
    this.trials = const [],
    this.fromFree = 0,
    this.fromSub = 0,
    this.fromPack = 0,
  });

  factory EnhanceDecision.deny(DenyReason r) =>
      EnhanceDecision._(allowed: false, reason: r);

  final bool allowed;
  final DenyReason? reason;

  /// Starter trials this shot consumes (shot is then free).
  final List<StarterTrial> trials;
  final int fromFree;
  final int fromSub;
  final int fromPack;

  int get credits => fromFree + fromSub + fromPack;
}

/// Decides whether an enhance may run and what it will cost. Nothing is
/// deducted here — call [applyDecision] only after the AI call succeeded.
/// [s] should already be [refreshState]d for [now].
EnhanceDecision decideEnhance(CreditState s, EnhanceSpec spec, DateTime now) {
  final pro = s.isPro(now);
  final trials = <StarterTrial>[];
  if (!pro) {
    if (spec.customPrompt || spec.customStyle) {
      return EnhanceDecision.deny(DenyReason.promptNeedsPro);
    }
    if (spec.highZoom) {
      if (!s.trialAvailable(StarterTrial.highZoom)) {
        return EnhanceDecision.deny(DenyReason.zoomNeedsPro);
      }
      trials.add(StarterTrial.highZoom);
    }
    if (spec.libraryStyle) {
      if (!s.trialAvailable(StarterTrial.libraryStyle)) {
        return EnhanceDecision.deny(DenyReason.styleNeedsPro);
      }
      trials.add(StarterTrial.libraryStyle);
    }
    if (spec.aiFilter) {
      if (!s.trialAvailable(StarterTrial.aiFilter)) {
        return EnhanceDecision.deny(DenyReason.filterNeedsPro);
      }
      trials.add(StarterTrial.aiFilter);
    }
    if (spec.tier.isPremium && s.trialAvailable(StarterTrial.premiumQuality)) {
      trials.add(StarterTrial.premiumQuality);
    }
  }
  if (trials.isNotEmpty) {
    return EnhanceDecision._(allowed: true, trials: trials);
  }

  var remaining = spec.credits;
  final fromFree = spec.tier == QualityTier.hd
      ? math.min(s.freeDaily, remaining)
      : 0;
  remaining -= fromFree;
  final fromSub = pro ? math.min(s.subCredits, remaining) : 0;
  remaining -= fromSub;
  final fromPack = math.min(s.packCredits, remaining);
  remaining -= fromPack;
  if (remaining > 0) return EnhanceDecision.deny(DenyReason.noCredits);
  return EnhanceDecision._(
    allowed: true,
    fromFree: fromFree,
    fromSub: fromSub,
    fromPack: fromPack,
  );
}

/// Max images per look request ("4 variations").
const int kMaxLookVariations = 4;

/// One AI look generation: a library style apply or a custom
/// custom "Prompt" edit. Mirrors enhance-server/ledger.py LookSpec.
class LookSpec {
  const LookSpec({
    required this.creditCost,
    this.variations = 1,
    this.proOnly = false,
    this.isStyle = true,
    this.allowTrial = true,
  });

  /// Credits per image (style cost set by the admin, or tier credits for a
  /// custom change).
  final int creditCost;
  final int variations;
  final bool proOnly;
  final bool isStyle;

  /// False when committing a partial batch of a multi-variation request.
  final bool allowTrial;

  int get totalCost => math.max(0, creditCost) * math.max(1, variations);
}

/// Looks are open to everyone (Free + Pro) and always cost credits, paid
/// from free daily → Pro → pack credits. v11.57: no free-first style trial.
/// Pro-only styles need Pro. Nothing is deducted here.
EnhanceDecision decideLook(CreditState s, LookSpec spec, DateTime now) {
  final pro = s.isPro(now);
  if (spec.variations < 1 || spec.variations > kMaxLookVariations) {
    return EnhanceDecision.deny(DenyReason.badRequest);
  }
  if (spec.proOnly && !pro) {
    return EnhanceDecision.deny(DenyReason.styleNeedsPro);
  }
  // v11.57: no free-first-style trial — every style costs its creditCost.
  var remaining = spec.totalCost;
  final fromFree = math.min(s.freeDaily, remaining);
  remaining -= fromFree;
  final fromSub = pro ? math.min(s.subCredits, remaining) : 0;
  remaining -= fromSub;
  final fromPack = math.min(s.packCredits, remaining);
  remaining -= fromPack;
  if (remaining > 0) return EnhanceDecision.deny(DenyReason.noCredits);
  return EnhanceDecision._(
    allowed: true,
    fromFree: fromFree,
    fromSub: fromSub,
    fromPack: fromPack,
  );
}

/// Commits a successful enhance: deducts credits and locks used trials.
CreditState applyDecision(CreditState s, EnhanceDecision d) {
  if (!d.allowed) return s;
  return s.copyWith(
    freeDaily: math.max(0, s.freeDaily - d.fromFree),
    subCredits: math.max(0, s.subCredits - d.fromSub),
    packCredits: math.max(0, s.packCredits - d.fromPack),
    trialsUsed: {...s.trialsUsed, ...d.trials},
  );
}

/// Applies a (test-mode or real) purchase.
/// * Subscription: Pro until max(now, proUntil) + 30 days; sub credits SET
///   to 100 (no rollover from the previous period).
/// * Pack: credits added (never expire).
CreditState applyPurchase(CreditState s, Product p, DateTime now) {
  switch (p.kind) {
    case ProductKind.subscription:
      final base = (s.proUntil != null && s.isPro(now))
          ? s.proUntil!.toUtc()
          : now.toUtc();
      return s.copyWith(proUntil: base.add(kProPeriod), subCredits: p.credits);
    case ProductKind.pack:
      return s.copyWith(packCredits: s.packCredits + p.credits);
  }
}

/// Short explanation for a denial (snackbar / upsell sheet).
String denyMessage(DenyReason r) {
  switch (r) {
    case DenyReason.zoomNeedsPro:
      return 'AI at this zoom is Pro only — photo kept without AI';
    case DenyReason.filterNeedsPro:
      return 'AI filters are Pro only';
    case DenyReason.styleNeedsPro:
      return 'This AI style is Pro only';
    case DenyReason.promptNeedsPro:
      return 'Custom prompts / styles are Pro only';
    case DenyReason.noCredits:
      return 'Out of credits — buy a pack, or get 2 free HD tomorrow';
    case DenyReason.badRequest:
      return 'Something went wrong — please try again';
  }
}
