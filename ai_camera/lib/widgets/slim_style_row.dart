import 'package:flutter/material.dart';

import '../models/ai_style.dart';
import '../models/style_preset.dart';
import '../theme/app_theme.dart';
import 'style_card_strip.dart' show CoinBadge;
import 'style_thumb.dart';

/// v11.70 post-capture Styles: one slim row of small thumbnails (Custom,
/// the credit AI filters on Pro AI captures, then the styles) and a
/// "See all" button that opens the full style library.
class SlimStyleRow extends StatelessWidget {
  const SlimStyleRow({
    super.key,
    required this.styles,
    required this.onStyle,
    required this.onSeeAll,
    this.onCustom,
    this.aiFilters = const [],
    this.onAiFilter,
    this.aiFilterCost = 1,
    this.aiFilterLocked = false,
    this.aiFilterTrial = false,
    this.isPro = false,
    this.enabled = true,
  });

  final List<AiStyle> styles;
  final ValueChanged<AiStyle> onStyle;
  final VoidCallback onSeeAll;
  final VoidCallback? onCustom;

  /// Credit AI filters (same prompts / credits as the old Filters panel).
  final List<StylePreset> aiFilters;
  final ValueChanged<StylePreset>? onAiFilter;
  final int aiFilterCost;

  /// Not Pro and no starter trial left → lock badge (tap shows the upsell).
  final bool aiFilterLocked;

  /// Not Pro, one free trial left → gift badge.
  final bool aiFilterTrial;
  final bool isPro;
  final bool enabled;

  static const double thumb = 52;

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[
      if (onCustom != null)
        _Tile(
          key: const ValueKey('slim_custom'),
          label: 'Custom',
          onTap: enabled ? onCustom : null,
          child: Container(
            color: AppColors.card,
            child: const Icon(
              Icons.edit_note_rounded,
              color: AppColors.accentSoft,
              size: 24,
            ),
          ),
        ),
      for (final f in aiFilters)
        _Tile(
          key: ValueKey('ai_${f.id}'),
          label: f.label,
          onTap: enabled && onAiFilter != null ? () => onAiFilter!(f) : null,
          badge: CoinBadge(cost: aiFilterCost),
          corner: aiFilterLocked
              ? Icons.lock
              : (aiFilterTrial ? Icons.card_giftcard : null),
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF2A2340), Color(0xFF14121C)],
              ),
            ),
            child: Icon(f.icon, color: AppColors.proGold, size: 22),
          ),
        ),
      for (final s in styles)
        _Tile(
          key: ValueKey('style_card_${s.id}'),
          label: s.name,
          onTap: enabled ? () => onStyle(s) : null,
          badge: CoinBadge(cost: s.creditCost),
          corner: s.proOnly && !isPro ? Icons.workspace_premium : null,
          child: StyleThumb(style: s),
        ),
    ];
    return SizedBox(
      key: const ValueKey('slim_style_row'),
      height: thumb + 22,
      child: Row(
        children: [
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.only(left: 12, right: 4),
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) => items[i],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8, bottom: 16),
            child: TextButton(
              key: const ValueKey('styles_see_all'),
              onPressed: enabled ? onSeeAll : null,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                foregroundColor: AppColors.accentSoft,
              ),
              child: const Text(
                'See all',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    super.key,
    required this.label,
    required this.onTap,
    required this.child,
    this.badge,
    this.corner,
  });

  final String label;
  final VoidCallback? onTap;
  final Widget child;
  final Widget? badge;
  final IconData? corner;

  @override
  Widget build(BuildContext context) {
    const t = SlimStyleRow.thumb;
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: t,
        child: Column(
          children: [
            SizedBox(
              width: t,
              height: t,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    child,
                    if (badge != null)
                      Positioned(
                        right: 2,
                        bottom: 2,
                        child: Transform.scale(
                          scale: 0.85,
                          alignment: Alignment.bottomRight,
                          child: badge,
                        ),
                      ),
                    if (corner != null)
                      Positioned(
                        left: 3,
                        top: 3,
                        child: Icon(corner, size: 12, color: AppColors.proGold),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
