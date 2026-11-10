import 'package:flutter/material.dart';

import '../models/ai_style.dart';
import 'style_card_strip.dart' show CoinBadge;
import 'style_thumb.dart';

/// v11.51 camera filter row (Snapchat-lens style) shown just above the
/// shutter when Styles is tapped: small rounded boxes with a before/after
/// preview, name and credit badge, then a "View more" pill that opens the
/// full Styles library. Tap = select (highlighted), tap again = deselect.
class FilterCarousel extends StatelessWidget {
  const FilterCarousel({
    super.key,
    required this.filters,
    required this.selectedId,
    required this.onSelect,
    required this.onViewMore,
  });

  final List<AiStyle> filters;
  final String? selectedId;

  /// Called with the tapped filter, or null when the selected one is tapped.
  final ValueChanged<AiStyle?> onSelect;
  final VoidCallback onViewMore;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const ValueKey('filter_carousel'),
      height: 106,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final f in filters) _box(f),
          Center(
            child: GestureDetector(
              key: const ValueKey('filter_view_more'),
              onTap: onViewMore,
              child: Container(
                margin: const EdgeInsets.only(left: 4, right: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(color: Colors.white38),
                ),
                child: const Text(
                  'View more',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _box(AiStyle f) {
    final sel = f.id == selectedId;
    return GestureDetector(
      key: ValueKey('filter_box_${f.id}'),
      onTap: () => onSelect(sel ? null : f),
      child: Container(
        width: 80,
        margin: const EdgeInsets.only(right: 8),
        child: Column(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 74,
              height: 74,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: sel ? Colors.amberAccent : Colors.white30,
                  width: sel ? 3 : 1,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    StyleThumb(style: f),
                    Positioned(
                      right: 2,
                      top: 2,
                      child: CoinBadge(cost: f.creditCost),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              f.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: sel ? Colors.amberAccent : Colors.white,
                fontSize: 11,
                fontWeight: sel ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
