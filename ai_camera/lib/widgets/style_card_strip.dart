import 'package:flutter/material.dart';

import '../models/ai_style.dart';
import '../theme/app_theme.dart';
import 'credit_icon.dart';
import 'save_style_button.dart';
import 'style_thumb.dart';

/// Small "🪙2" style cost badge (coin icon + number, like the credits pill).
class CoinBadge extends StatelessWidget {
  const CoinBadge({super.key, required this.cost, this.free = false});

  final int cost;

  /// Deprecated (v11.57): Free labels removed; cost is always shown.
  final bool free;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CreditIcon(size: 12),
          const SizedBox(width: 2),
          Text(
            '$cost',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

/// One style card: sample image, name, coin cost badge, PRO tag.
class StyleCard extends StatelessWidget {
  const StyleCard({
    super.key,
    required this.style,
    required this.onTap,
    this.isPro = false,
    this.trialAvailable = false,
    this.width = 100,
    this.height = 178,
  });

  final AiStyle style;
  final VoidCallback? onTap;
  final bool isPro;
  final bool trialAvailable;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: ValueKey('style_card_${style.id}'),
      onTap: onTap,
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: width,
              height: height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    StyleThumb(style: style),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: CoinBadge(cost: style.creditCost),
                    ),
                    // v11.56 Save (bookmark) toggle.
                    Positioned(
                      left: 4,
                      bottom: 4,
                      child: SaveStyleButton(styleId: style.id, video: false, size: 16),
                    ),
                    if (style.proOnly && !isPro)
                      Positioned(
                        left: 4,
                        top: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.proGold,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'PRO',
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 9,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              style.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Custom "Prompt" card (custom prompt look).
class CustomChangeCard extends StatelessWidget {
  const CustomChangeCard({
    super.key,
    required this.onTap,
    this.width = 100,
    this.height = 178,
  });

  final VoidCallback? onTap;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey('style_card_custom'),
      onTap: onTap,
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: width,
              height: height,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: AppColors.accentSoft.withValues(alpha: 0.6),
                ),
                color: AppColors.card,
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.edit_note_rounded, color: AppColors.accentSoft),
                  SizedBox(height: 4),
                  Text(
                    'Write a\nprompt',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, height: 1.15),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Custom',
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

/// Horizontal "Styles" strip of image cards (post-capture preview, gallery,
/// result screen).
class StyleCardStrip extends StatelessWidget {
  const StyleCardStrip({
    super.key,
    required this.styles,
    required this.onStyle,
    this.onCustom,
    this.onSeeAll,
    this.isPro = false,
    this.trialAvailable = false,
    this.enabled = true,
  });

  final List<AiStyle> styles;
  final ValueChanged<AiStyle> onStyle;
  final VoidCallback? onCustom;
  final VoidCallback? onSeeAll;
  final bool isPro;
  final bool trialAvailable;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('style_card_strip'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 6),
          child: Row(
            children: [
              const Icon(
                Icons.auto_awesome,
                size: 14,
                color: AppColors.accentSoft,
              ),
              const SizedBox(width: 5),
              const Text(
                'Styles',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              if (onSeeAll != null)
                GestureDetector(
                  key: const ValueKey('styles_see_all'),
                  onTap: enabled ? onSeeAll : null,
                  child: const Text(
                    'See all',
                    style: TextStyle(fontSize: 12, color: AppColors.accentSoft),
                  ),
                ),
            ],
          ),
        ),
        SizedBox(
          height: 206,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: styles.length + (onCustom != null ? 1 : 0),
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              if (onCustom != null && i == 0) {
                return CustomChangeCard(onTap: enabled ? onCustom : null);
              }
              final s = styles[i - (onCustom != null ? 1 : 0)];
              return StyleCard(
                style: s,
                isPro: isPro,
                trialAvailable: trialAvailable,
                onTap: enabled ? () => onStyle(s) : null,
              );
            },
          ),
        ),
      ],
    );
  }
}
