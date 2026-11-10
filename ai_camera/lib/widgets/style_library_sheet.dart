import 'package:flutter/material.dart';

import '../models/ai_style.dart';
import '../models/style_category.dart';
import '../services/account_service.dart';
import '../services/entitlements.dart';
import '../services/style_catalog.dart';
import '../services/video_service.dart';
import '../services/video_style_catalog.dart';
import '../theme/app_theme.dart';
import 'credit_icon.dart';
import 'style_card_strip.dart' show CoinBadge;
import 'save_style_button.dart';
import 'style_thumb.dart';
import 'video_style_flow.dart';

/// Result of the full Styles sheet.
class StylePick {
  const StylePick.style(AiStyle this.style) : custom = false, video = false;
  const StylePick.video(AiStyle this.style) : custom = false, video = true;
  const StylePick.custom() : style = null, custom = true, video = false;
  const StylePick.customVideo() : style = null, custom = true, video = true;

  final AiStyle? style;
  final bool custom;

  /// A video style (or Custom → Video).
  final bool video;
}

/// v11.54 full Styles sheet: Photo | Video tabs (Photo first), a row of
/// category chips with icons, and a grid of big 9:16 portrait cards.
Future<StylePick?> showStyleLibrarySheet(BuildContext context, {bool videoFirst = false}) {
  return showModalBottomSheet<StylePick>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (ctx, scroll) => StylesLibrary(scroll: scroll, videoFirst: videoFirst),
    ),
  );
}

/// Columns for 9:16 cards: 3 only when cards stay ≥ 120 dp wide.
int styleGridColumns(double width) {
  const spacing = 10.0;
  final three = (width - 2 * spacing) / 3;
  return three >= 120 ? 3 : 2;
}

class StylesLibrary extends StatefulWidget {
  const StylesLibrary({super.key, required this.scroll, this.videoFirst = false});
  final ScrollController scroll;
  final bool videoFirst;
  @override
  State<StylesLibrary> createState() => _StylesLibraryState();
}

class _StylesLibraryState extends State<StylesLibrary> {
  late bool _video = widget.videoFirst;
  String _cat = kCategoryNew;

  void _setTab(bool video) => setState(() {
    _video = video;
    _cat = kCategoryNew;
  });

  /// v11.56: Custom opens straight into the Custom window (no "photo or
  /// video?" step): AI Photo from the Photo tab, AI Video from the Video tab.
  void _custom() => Navigator.pop(
    context,
    _video ? const StylePick.customVideo() : const StylePick.custom(),
  );

  @override
  Widget build(BuildContext context) {
    final account = AccountService.instance;
    return ValueListenableBuilder<List<AiStyle>>(
      valueListenable: _video ? VideoStyleCatalog.instance.styles : StyleCatalog.instance.styles,
      builder: (context, all, _) => ValueListenableBuilder<CreditState?>(
        valueListenable: account.state,
        builder: (context, st, _) => ValueListenableBuilder<Map<String, int>>(
          valueListenable: VideoService.instance.credits,
          builder: (context, _, _) {
            final pro = st?.isPro(account.now) ?? false;
            final list = stylesInCategory(
              [for (final s in all) if (!s.isFilter) s],
              _cat,
              video: _video,
            );
            final from = videoFromCredits(VideoService.instance);
            return CustomScrollView(
              key: const ValueKey('style_library_sheet'),
              controller: widget.scroll,
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  sliver: SliverList.list(
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text('Styles', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 10),
                      _Tabs(video: _video, onChanged: _setTab),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 64,
                        child: ListView(
                          key: const ValueKey('style_category_row'),
                          scrollDirection: Axis.horizontal,
                          children: [
                            for (final c in categoriesFor(video: _video))
                              _CategoryChip(
                                cat: c,
                                selected: c.id == _cat,
                                onTap: () => setState(() => _cat = c.id),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _video
                            ? 'Pick a style · uses your last photo · credits only when ready'
                            : 'Pick a look · credits are used only when it is ready',
                        style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
                      ),
                      const SizedBox(height: 10),
                    ],
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  sliver: SliverLayoutBuilder(
                    builder: (context, c) => SliverGrid.count(
                      crossAxisCount: styleGridColumns(c.crossAxisExtent),
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 9 / 16,
                      children: [
                        _CustomTile(onTap: _custom),
                        for (final s in list)
                          _PortraitCard(
                            key: ValueKey('${_video ? 'video' : 'photo'}_card_${s.id}'),
                            style: s,
                            video: _video,
                            badge: _video
                                ? _Chip(child: CreditText(videoFromLabel(from),
                                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)))
                                : CoinBadge(cost: s.creditCost),
                            pro: s.proOnly && !pro,
                            onTap: () => Navigator.pop(
                              context,
                              _video ? StylePick.video(s) : StylePick.style(s),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (list.isEmpty)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.only(bottom: 24),
                      child: Center(
                        child: Text('No styles in this category yet',
                            key: ValueKey('style_category_empty'),
                            style: TextStyle(color: AppColors.textSecondary)),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs({required this.video, required this.onChanged});
  final bool video;
  final ValueChanged<bool> onChanged;

  Widget _tab(String label, bool on, VoidCallback tap, String key) => Expanded(
    child: GestureDetector(
      key: ValueKey(key),
      onTap: tap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? AppColors.proGold : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: on ? Colors.black : AppColors.textPrimary,
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(23)),
    child: Row(
      children: [
        _tab('Photo', !video, () => onChanged(false), 'styles_tab_photo'),
        _tab('Video', video, () => onChanged(true), 'styles_tab_video'),
      ],
    ),
  );
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({required this.cat, required this.selected, required this.onTap});
  final StyleCategory cat;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.proGold : AppColors.textSecondary;
    return GestureDetector(
      key: ValueKey('style_cat_${cat.id}'),
      onTap: onTap,
      child: Container(
        width: 74,
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppColors.proGold.withValues(alpha: 0.14) : AppColors.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? AppColors.proGold : Colors.transparent, width: 1.2),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(cat.icon, size: 22, color: color),
            const SizedBox(height: 3),
            Text(
              cat.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: selected ? AppColors.proGold : AppColors.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.62), borderRadius: BorderRadius.circular(99)),
    child: child,
  );
}

/// Big 9:16 card: image, name on a dark gradient, credit chip.
class _PortraitCard extends StatelessWidget {
  const _PortraitCard({
    super.key,
    required this.style,
    required this.video,
    required this.badge,
    required this.pro,
    required this.onTap,
  });
  final AiStyle style;
  final bool video;
  final Widget badge;
  final bool pro;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Stack(
        fit: StackFit.expand,
        children: [
          StyleThumb(style: style),
          Positioned(top: 6, right: 6, child: badge),
          if (video)
            const Positioned(top: 6, left: 6, child: Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 22)),
          if (pro && !video)
            Positioned(
              left: 6,
              top: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(color: AppColors.proGold, borderRadius: BorderRadius.circular(6)),
                child: const Text('PRO', style: TextStyle(color: Colors.black, fontSize: 9, fontWeight: FontWeight.w900)),
              ),
            ),
          // v11.56 Save (bookmark) toggle on the card corner.
          Positioned(
            left: 4,
            top: video || pro ? 34 : 4,
            child: SaveStyleButton(styleId: style.id, video: video, size: 20),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 9),
              // Solid bar: sample images may carry their own caption.
              color: const Color(0xF0101016),
              child: Text(
                style.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _CustomTile extends StatelessWidget {
  const _CustomTile({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(
    key: const ValueKey('style_card_custom'),
    onTap: onTap,
    child: Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.accentSoft.withValues(alpha: 0.6)),
        color: AppColors.card,
      ),
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.edit_note_rounded, color: AppColors.accentSoft, size: 30),
          SizedBox(height: 6),
          Text('Custom', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
          SizedBox(height: 2),
          Text('AI Photo · AI Video', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
        ],
      ),
    ),
  );
}
