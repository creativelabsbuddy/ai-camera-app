import 'package:flutter/material.dart';

import '../models/pose_photo.dart';
import '../theme/app_theme.dart';

/// v11 Pose mode: category chips + REAL photo thumbnails (no outline, no
/// auto-capture). Tapping a photo selects it; the camera shows it as a
/// floating reference thumbnail.
class PoseStrip extends StatelessWidget {
  const PoseStrip({
    super.key,
    required this.categories,
    required this.category,
    required this.poses,
    required this.selected,
    required this.onCategory,
    required this.onPose,
  });

  final List<String> categories;
  final String category;
  final List<PosePhoto> poses;
  final PosePhoto? selected;
  final ValueChanged<String> onCategory;
  final ValueChanged<PosePhoto?> onPose;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 36,
          child: ListView(
            key: const ValueKey('pose_categories'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final c in categories)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    key: ValueKey('pose_cat_$c'),
                    label: Text(c),
                    selected: c == category,
                    onSelected: (_) => onCategory(c),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 92,
          child: poses.isEmpty
              ? const Center(
                  child: Text(
                    'No poses in this category',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                )
              : ListView(
                  key: const ValueKey('pose_photos'),
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  children: [
                    for (final p in poses)
                      _Thumb(
                        key: ValueKey('pose_${p.id}'),
                        pose: p,
                        selected: p.id == selected?.id,
                        onTap: () => onPose(p.id == selected?.id ? null : p),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({
    super.key,
    required this.pose,
    required this.selected,
    required this.onTap,
  });

  final PosePhoto pose;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          children: [
            Container(
              width: 60,
              height: 72,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected ? AppColors.proGold : Colors.white24,
                  width: selected ? 2.2 : 1,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: PoseImage(pose: pose, fit: BoxFit.cover),
              ),
            ),
            const SizedBox(height: 2),
            SizedBox(
              width: 64,
              child: Text(
                pose.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 9.5,
                  color: selected ? AppColors.proGold : AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bundled asset or server photo.
class PoseImage extends StatelessWidget {
  const PoseImage({super.key, required this.pose, this.fit = BoxFit.cover});

  final PosePhoto pose;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final url = pose.url;
    if (url != null && url.startsWith('http')) {
      return Image.network(
        url,
        fit: fit,
        errorBuilder: (_, _, _) => _fallback(),
        loadingBuilder: (c, child, prog) => prog == null
            ? child
            : const ColoredBox(
                color: Colors.black26,
                child: Center(
                  child: SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                ),
              ),
      );
    }
    return _fallback();
  }

  Widget _fallback() {
    final asset = pose.asset;
    if (asset == null) {
      return const ColoredBox(
        color: Colors.black26,
        child: Icon(Icons.image_outlined, color: Colors.white38, size: 18),
      );
    }
    return Image.asset(asset, fit: fit);
  }
}

/// Full-size reference (tap the floating thumbnail).
Future<void> showPoseLarge(BuildContext context, PosePhoto pose) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 3 / 4,
            child: PoseImage(pose: pose, fit: BoxFit.contain),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: Column(
              children: [
                Text(
                  pose.name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                if (pose.credit.isNotEmpty)
                  Text(
                    pose.credit,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
