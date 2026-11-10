import 'package:flutter/material.dart';

/// v11.54: credits are shown with a gold lightning bolt (PNG asset,
/// 1x/2x/3x) instead of a coin. Label strings keep [kCreditGlyph] as a
/// token; [CreditText] renders each token as the bolt image.
const kCreditGlyph = '🪙';
const kCreditIconAsset = 'assets/icons/credit_bolt.png';

class CreditIcon extends StatelessWidget {
  const CreditIcon({super.key, this.size = 14});
  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
    kCreditIconAsset,
    key: const ValueKey('credit_icon'),
    width: size,
    height: size,
    filterQuality: FilterQuality.medium,
  );
}

/// Text where every [kCreditGlyph] is drawn as [CreditIcon].
class CreditText extends StatelessWidget {
  const CreditText(this.text, {super.key, this.style, this.textAlign, this.maxLines, this.overflow});

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    if (!text.contains(kCreditGlyph)) {
      return Text(text, style: style, textAlign: textAlign, maxLines: maxLines, overflow: overflow);
    }
    final eff = DefaultTextStyle.of(context).style.merge(style);
    final size = (eff.fontSize ?? 14) * 1.05;
    final parts = text.split(kCreditGlyph);
    final spans = <InlineSpan>[];
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].isNotEmpty) spans.add(TextSpan(text: parts[i]));
      if (i < parts.length - 1) {
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(padding: const EdgeInsets.only(right: 1), child: CreditIcon(size: size)),
        ));
      }
    }
    return Text.rich(TextSpan(children: spans), style: style, textAlign: textAlign, maxLines: maxLines, overflow: overflow);
  }
}

/// Test/helper: finds a [CreditText] showing exactly [text].
bool isCreditText(Widget w, String text) => w is CreditText && w.text == text;
