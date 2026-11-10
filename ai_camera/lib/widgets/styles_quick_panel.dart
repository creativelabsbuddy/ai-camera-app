import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/ai_style.dart';
import '../services/saved_styles.dart';
import '../services/style_catalog.dart';
import '../services/video_service.dart';
import '../services/video_style_catalog.dart';
import '../theme/app_theme.dart';
import 'credit_icon.dart';
import 'style_thumb.dart';
import 'video_style_flow.dart';

/// v11.54 four-dot → one row above the mode strip: PHOTO group · VIDEO
/// group · gold "More ›" (full Styles sheet). 9:16 portrait cards.
/// v11.56: saved styles come FIRST in their group (saved order), then the
/// defaults without duplicates; the row scrolls horizontally.
class StylesQuickPanel extends StatelessWidget {
  const StylesQuickPanel({
    super.key,
    required this.onPhoto,
    required this.onVideo,
    required this.onMore,
    this.filters = const [],
    this.selectedId,
  });

  final void Function(AiStyle s) onPhoto;
  final void Function(AiStyle s) onVideo;
  final VoidCallback onMore;

  /// Camera filters (v11.51) shown first in the PHOTO group.
  final List<AiStyle> filters;
  final String? selectedId;

  static const double minCard = 48;
  static const double maxCard = 60;
  static const double gap = 6;
  static const double groupGap = 10;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<AiStyle>>(
      valueListenable: VideoStyleCatalog.instance.styles,
      builder: (context, videos, _) => ValueListenableBuilder<List<AiStyle>>(
        valueListenable: StyleCatalog.instance.styles,
        builder: (context, images, _) => ValueListenableBuilder<List<String>>(
          valueListenable: SavedStyles.instance.photo,
          builder: (context, savedPhoto, _) =>
              ValueListenableBuilder<List<String>>(
                valueListenable: SavedStyles.instance.video,
                builder: (context, savedVideo, _) =>
                    ValueListenableBuilder<Map<String, int>>(
                      valueListenable: VideoService.instance.credits,
                      builder: (context, _, _) => Container(
                        key: const ValueKey('styles_quick_panel'),
                        margin: const EdgeInsets.symmetric(horizontal: 8),
                        padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceElevated,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: LayoutBuilder(
                          builder: (context, c) {
                            final photoDefaults = [
                              ...filters,
                              ...images.where((s) => !s.isFilter),
                            ];
                            return _row(
                              c.maxWidth,
                              orderWithSaved(
                                savedPhoto,
                                photoDefaults,
                                photoDefaults,
                              ),
                              orderWithSaved(savedVideo, videos, videos),
                              savedPhoto.toSet(),
                              savedVideo.toSet(),
                            );
                          },
                        ),
                      ),
                    ),
              ),
        ),
      ),
    );
  }

  Widget _row(
    double width,
    List<AiStyle> photos,
    List<AiStyle> videos,
    Set<String> savedPhoto,
    Set<String> savedVideo,
  ) {
    final plan = planQuickRow(
      width: width,
      photos: photos.length,
      videos: videos.length,
    );
    final w = plan.cardWidth;
    final h = w * 16 / 9;
    final from = videoFromCredits(VideoService.instance);
    Widget group(String label, List<Widget> cards) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w800,
            color: AppColors.proGold,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 3),
        Row(mainAxisSize: MainAxisSize.min, children: cards),
      ],
    );
    final children = <Widget>[
      if (photos.isNotEmpty)
        group('PHOTO', [
          for (final s in photos)
            _QuickCard(
              key: ValueKey('quick_photo_${s.id}'),
              style: s,
              width: w,
              height: h,
              selected: s.id == selectedId,
              saved: savedPhoto.contains(s.id),
              chip: s.isFilter && s.creditCost == 0
                  ? null
                  : '$kCreditGlyph${s.creditCost}',
              onTap: () => onPhoto(s),
            ),
        ]),
      if (photos.isNotEmpty && videos.isNotEmpty)
        const SizedBox(width: groupGap - gap),
      if (videos.isNotEmpty)
        group('VIDEO', [
          for (final s in videos)
            _QuickCard(
              key: ValueKey('quick_video_${s.id}'),
              style: s,
              width: w,
              height: h,
              video: true,
              saved: savedVideo.contains(s.id),
              chip: '$kCreditGlyph$from',
              onTap: () => onVideo(s),
            ),
        ]),
    ];
    return SingleChildScrollView(
      key: const ValueKey('quick_row_scroll'),
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          ...children,
          SizedBox(
            width: math.max(w, 56),
            child: GestureDetector(
              key: const ValueKey('quick_more'),
              onTap: onMore,
              child: Container(
                height: h,
                decoration: BoxDecoration(
                  color: AppColors.card,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.proGold, width: 1.5),
                ),
                alignment: Alignment.center,
                child: const FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      'More ›',
                      style: TextStyle(
                        color: AppColors.proGold,
                        fontWeight: FontWeight.w800,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// How many photo / video cards fit in one row of [width] and how wide
/// each is, leaving at least one card width for "More".
class QuickRowPlan {
  const QuickRowPlan(this.photos, this.videos, this.cardWidth);
  final int photos;
  final int videos;
  final double cardWidth;
}

QuickRowPlan planQuickRow({
  required double width,
  required int photos,
  required int videos,
}) {
  const g = StylesQuickPanel.gap;
  const gg = StylesQuickPanel.groupGap;
  // Slots incl. More at the minimum size.
  final slots = math.max(
    1,
    ((width - gg + g) / (StylesQuickPanel.minCard + g)).floor(),
  );
  var cards = math.max(0, slots - 1);
  var p = math.min(photos, (cards + 1) ~/ 2);
  var v = math.min(videos, cards - p);
  p = math.min(photos, cards - v); // give spare slots back to photos
  cards = p + v;
  // Widen the cards to fill the row (More gets the rest; capped at max).
  final w = cards == 0
      ? StylesQuickPanel.minCard
      : ((width - gg - g * cards) / (cards + 1))
            .clamp(StylesQuickPanel.minCard, StylesQuickPanel.maxCard)
            .toDouble();
  return QuickRowPlan(p, v, w);
}

class _QuickCard extends StatelessWidget {
  const _QuickCard({
    super.key,
    required this.style,
    required this.width,
    required this.height,
    required this.onTap,
    this.chip,
    this.video = false,
    this.selected = false,
    this.saved = false,
  });
  final AiStyle style;
  final double width;
  final double height;
  final VoidCallback onTap;
  final String? chip;
  final bool video;
  final bool selected;

  /// v11.56: saved (bookmarked) style → small gold bookmark.
  final bool saved;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: width,
      height: height,
      margin: const EdgeInsets.only(right: StylesQuickPanel.gap),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: selected
            ? Border.all(color: AppColors.proGold, width: 2)
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(selected ? 8 : 10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            StyleThumb(style: style),
            if (video)
              const Positioned(
                left: 2,
                top: 2,
                child: Icon(
                  Icons.play_circle_fill_rounded,
                  size: 14,
                  color: Colors.white,
                ),
              ),
            if (saved)
              Positioned(
                left: 1,
                bottom: 16,
                child: Icon(
                  Icons.bookmark_rounded,
                  key: ValueKey('quick_saved_${style.id}'),
                  size: 13,
                  color: AppColors.proGold,
                ),
              ),
            if (chip != null)
              Positioned(
                right: 2,
                top: 2,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 3,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: CreditText(
                    chip!,
                    style: const TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(2, 3, 2, 3),
                color: const Color(0xF0101016),
                child: Text(
                  style.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 8.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// v11.54 first-run "Styles are here" tooltip (tail points down at the
/// four-dot button). Tap to dismiss.
class StylesHereTooltip extends StatelessWidget {
  const StylesHereTooltip({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    key: const ValueKey('styles_here_tooltip'),
    onTap: onTap,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.proGold,
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [BoxShadow(blurRadius: 8, color: Colors.black45)],
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.auto_awesome, size: 16, color: Colors.black),
              SizedBox(width: 6),
              Text(
                'Styles are here',
                style: TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 22),
          child: CustomPaint(size: const Size(14, 8), painter: _Tail()),
        ),
      ],
    ),
  );
}

class _Tail extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(p, Paint()..color = AppColors.proGold);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
