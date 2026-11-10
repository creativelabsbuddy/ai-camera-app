import 'package:flutter/material.dart';

import '../services/saved_styles.dart';
import '../theme/app_theme.dart';

/// v11.56 bookmark toggle on a style card corner: saved styles go first in
/// the four-dot quick row (Photo / Video group).
class SaveStyleButton extends StatelessWidget {
  const SaveStyleButton({
    super.key,
    required this.styleId,
    required this.video,
    this.size = 18,
    this.showLabel = false,
  });

  final String styleId;
  final bool video;
  final double size;

  /// Sheet variant: "Save" / "Saved" text next to the icon.
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final saved = SavedStyles.instance;
    return ValueListenableBuilder<List<String>>(
      valueListenable: saved.listFor(video: video),
      builder: (context, ids, _) {
        final on = ids.contains(styleId);
        final icon = Icon(
          on ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
          size: size,
          color: on ? AppColors.proGold : Colors.white,
        );
        return Semantics(
          button: true,
          label: on ? 'Saved' : 'Save',
          child: GestureDetector(
            key: ValueKey('save_${video ? 'video' : 'photo'}_$styleId'),
            behavior: HitTestBehavior.opaque,
            onTap: () async {
              final now = await saved.toggle(styleId, video: video);
              if (!context.mounted) return;
              ScaffoldMessenger.maybeOf(context)
                ?..hideCurrentSnackBar()
                ..showSnackBar(SnackBar(
                  duration: const Duration(milliseconds: 1400),
                  content: Text(now ? 'Saved · added to your quick styles' : 'Removed from saved'),
                ));
            },
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: showLabel ? 10 : 4, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(99),
              ),
              child: showLabel
                  ? Row(mainAxisSize: MainAxisSize.min, children: [
                      icon,
                      const SizedBox(width: 4),
                      Text(on ? 'Saved' : 'Save',
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                              color: on ? AppColors.proGold : Colors.white)),
                    ])
                  : icon,
            ),
          ),
        );
      },
    );
  }
}
