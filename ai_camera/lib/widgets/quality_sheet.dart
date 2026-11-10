import 'package:flutter/material.dart';

import '../models/quality_tier.dart';
import '../services/account_service.dart';
import '../services/entitlements.dart';
import '../services/macro.dart'
    show
        kMacroCredits,
        kMacroQualities,
        kMacroLockedQualities,
        kComingSoonLabel,
        MacroLevel;
import '../theme/app_theme.dart';
import 'pro_upgrade_sheet.dart';
import 'credit_icon.dart';

/// True when [tier] can currently be paid for (credits or starter trial).
bool tierSelectable(QualityTier tier, CreditState? s, DateTime now) {
  if (tier == QualityTier.hd || s == null) return true;
  if (s.isPro(now) || s.packCredits > 0) return true;
  return tier.isPremium && s.trialAvailable(StarterTrial.premiumQuality);
}

/// Bottom sheet to pre-select the output quality (tap on the top badge).
/// Returns the chosen tier, or null when dismissed.
Future<QualityTier?> showQualitySheet(
  BuildContext context,
  QualityTier current,
) {
  return showModalBottomSheet<QualityTier>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      final account = AccountService.instance;
      final s = account.state.value;
      final now = account.now;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Choose AI quality',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              const Text(
                'Nothing is asked after capture — credits are used only for successful AI photos.',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12.5,
                ),
              ),
              const SizedBox(height: 10),
              for (final t in QualityTier.picker)
                _TierTile(
                  tier: t,
                  selected: t == current,
                  selectable: tierSelectable(t, s, now),
                  trial:
                      t.isPremium &&
                      s != null &&
                      !s.isPro(now) &&
                      s.trialAvailable(StarterTrial.premiumQuality),
                  onTap: () async {
                    if (!tierSelectable(t, s, now)) {
                      Navigator.pop(ctx);
                      await showProUpgradeSheet(
                        context,
                        reason: '${t.label} needs a credit pack or Pro',
                      );
                      return;
                    }
                    Navigator.pop(ctx, t);
                  },
                ),
              // v11.39: 4K removed; 2K shown locked (no credits, not
              // selectable).
              const Opacity(
                opacity: 0.5,
                child: ListTile(
                  key: ValueKey('tier_2k_coming_soon'),
                  enabled: false,
                  leading: Icon(Icons.lock_outline),
                  title: Text(
                    '2K',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  trailing: Text(
                    kComingSoonLabel,
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _TierTile extends StatelessWidget {
  const _TierTile({
    required this.tier,
    required this.selected,
    required this.selectable,
    required this.trial,
    required this.onTap,
  });

  final QualityTier tier;
  final bool selected;
  final bool selectable;
  final bool trial;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? AppColors.accent.withValues(alpha: 0.22)
            : AppColors.card,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          key: ValueKey('tier_${tier.id}'),
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: selected
                      ? AppColors.accentSoft
                      : AppColors.textSecondary,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${tier.label}  ·  ${tier.targetLabel}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                ),
                if (trial)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: Text(
                      '1 free trial',
                      style: TextStyle(color: AppColors.proGold, fontSize: 12),
                    ),
                  ),
                if (!selectable)
                  const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: Icon(
                      Icons.lock_rounded,
                      size: 16,
                      color: AppColors.proGold,
                    ),
                  ),
                Text(
                  '${tier.credits} credit${tier.credits == 1 ? '' : 's'}',
                  style: const TextStyle(
                    color: AppColors.proGold,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// v11.33 Macro quality: HD / Full HD, and 2K shown locked ("Coming
/// soon"). Rows show the level credits. Returns the chosen tier or null.
Future<QualityTier?> showMacroQualitySheet(
  BuildContext context,
  QualityTier current,
) {
  return showModalBottomSheet<QualityTier>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Macro quality',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              const Text(
                'Credits per photo: Macro / Close / Microscope / Extreme / Ultra. Used only for successful photos.',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12.5,
                ),
              ),
              const SizedBox(height: 10),
              for (final (id, label, _) in kMacroQualities)
                _MacroQualityTile(
                  id: id,
                  label: label,
                  selected: id == current.id,
                  locked: kMacroLockedQualities.contains(id),
                  onTap: () => Navigator.pop(ctx, QualityTier.fromId(id)),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _MacroQualityTile extends StatelessWidget {
  const _MacroQualityTile({
    required this.id,
    required this.label,
    required this.selected,
    required this.locked,
    required this.onTap,
  });

  final String id;
  final String label;
  final bool selected;
  final bool locked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final row = kMacroCredits[id]!;
    final costs = MacroLevel.values.map((l) => row[l.id]).join(' / ');
    return Opacity(
      opacity: locked ? 0.5 : 1,
      child: ListTile(
        key: ValueKey('macro_quality_$id'),
        enabled: !locked,
        onTap: locked ? null : onTap,
        leading: Icon(
          locked
              ? Icons.lock_outline
              : (selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked),
          color: selected ? AppColors.accent : AppColors.textSecondary,
        ),
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: CreditText('🪙 $costs'),
        trailing: locked
            ? const Text(
                kComingSoonLabel,
                key: ValueKey('macro_quality_coming_soon'),
                style: TextStyle(fontWeight: FontWeight.w700),
              )
            : null,
      ),
    );
  }
}
