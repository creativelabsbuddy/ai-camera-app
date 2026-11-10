import 'dart:io';

import 'package:flutter/material.dart';

import '../models/ai_style.dart';
import '../services/style_catalog.dart';
import '../services/style_samples.dart';
import '../theme/app_theme.dart';

/// Style display image: v11.56 real sample AFTER image (9:16 cover) →
/// disk-cached server image → bundled sample → gradient placeholder.
class StyleThumb extends StatelessWidget {
  const StyleThumb({super.key, required this.style, this.fit = BoxFit.cover});

  final AiStyle style;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, StyleSample>>(
      valueListenable: StyleSamples.instance.samples,
      builder: (context, _, _) {
        final after = StyleSamples.instance.of(style)?.after;
        if (after == null) return _base(context);
        return FutureBuilder<File?>(
          future: StyleSamples.instance.file(after),
          builder: (context, snap) {
            final f = snap.data;
            if (f == null) return _base(context);
            return Image.file(
              f,
              key: const ValueKey('style_thumb_sample'),
              fit: fit,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => _base(context),
            );
          },
        );
      },
    );
  }

  Widget _base(BuildContext context) {
    final fallback = style.imageAsset != null
        ? Image.asset(
            style.imageAsset!,
            fit: fit,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _Placeholder(style: style),
          )
        : _Placeholder(style: style);
    if (style.imageUrl == null) return fallback;
    return FutureBuilder<File?>(
      future: StyleCatalog.instance.thumbnail(style),
      builder: (context, snap) {
        final f = snap.data;
        if (f == null) return fallback;
        return Image.file(
          f,
          fit: fit,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => fallback,
        );
      },
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.style});

  final AiStyle style;

  @override
  Widget build(BuildContext context) {
    final hue = (style.id.codeUnits.fold<int>(0, (a, b) => a + b) * 37) % 360;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            HSLColor.fromAHSL(1, hue.toDouble(), 0.45, 0.35).toColor(),
            AppColors.card,
          ],
        ),
      ),
      child: const Center(
        child: Icon(Icons.auto_awesome, color: Colors.white70),
      ),
    );
  }
}
