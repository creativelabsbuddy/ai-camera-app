import 'dart:io';

import 'package:flutter/material.dart';

import '../models/ai_style.dart';
import '../services/style_samples.dart';
import 'style_thumb.dart';

/// v11.66: "2/7" counter for the variant swiper.
String variantCountLabel(int index, int count) => '${index + 1}/$count';

/// v11.66: swipe left/right through a style's variants inside the card
/// frame; dots + "2/7" show where you are. Each page shows the variant's
/// sample photo (falls back to the style thumbnail).
class VariantPager extends StatefulWidget {
  const VariantPager({
    super.key,
    required this.style,
    required this.initial,
    required this.onChanged,
    this.showCount = true,
    this.dotsBottom = 10,
  });

  final AiStyle style;
  final int initial;
  final ValueChanged<int> onChanged;

  /// "2/7" pill (top-right). Off on library cards (the credit badge is there).
  final bool showCount;

  /// Distance of the dots from the bottom (above a name bar on cards).
  final double dotsBottom;

  @override
  State<VariantPager> createState() => _VariantPagerState();
}

class _VariantPagerState extends State<VariantPager> {
  late final PageController _pc = PageController(initialPage: widget.initial);
  late int _i = widget.initial;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  Widget _page(StyleVariant v) {
    final url = v.sampleUrl;
    if (url == null) return StyleThumb(style: widget.style);
    return FutureBuilder<File?>(
      future: StyleSamples.instance.file(url),
      builder: (context, snap) => snap.data == null
          ? StyleThumb(style: widget.style)
          : Image.file(snap.data!, fit: BoxFit.cover, gaplessPlayback: true),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vs = widget.style.variants;
    return Stack(
      fit: StackFit.expand,
      children: [
        PageView.builder(
          key: const ValueKey('look_variant_pager'),
          controller: _pc,
          itemCount: vs.length,
          onPageChanged: (i) {
            setState(() => _i = i);
            widget.onChanged(i);
          },
          itemBuilder: (_, i) => KeyedSubtree(
            key: ValueKey('look_variant_page_${vs[i].id}'),
            child: _page(vs[i]),
          ),
        ),
        if (widget.showCount)
          Positioned(
            right: 8,
            top: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text(
                variantCountLabel(_i, vs.length),
                key: const ValueKey('look_variant_count'),
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: widget.dotsBottom,
          child: Row(
            key: const ValueKey('look_variant_dots'),
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var k = 0; k < vs.length; k++)
                GestureDetector(
                  onTap: () => _pc.animateToPage(
                    k,
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut,
                  ),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: k == _i ? 16 : 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: k == _i
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(9),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
