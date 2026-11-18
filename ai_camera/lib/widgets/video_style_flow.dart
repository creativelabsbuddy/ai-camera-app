import 'dart:io';

import 'package:flutter/material.dart';

import '../models/ai_style.dart';
import '../services/video_service.dart';
import '../theme/app_theme.dart';
import 'credit_icon.dart';
import 'save_style_button.dart';

/// v11.57 video style cards: last photo auto-used → confirm sheet (preview,
/// 480p / 768p, "Generate · ⚡N"). Image-to-video only. Same from the
/// quick row and the full Styles sheet. Custom still picks a photo.

/// Preset videos: 5 s · 9:16 (Phosor MiniMax H3 Turbo).
const kPresetVideoSeconds = 5;
const kDefaultVideoResolution = '480p';

/// Lowest price of a preset video ("from ⚡N" on cards).
int videoFromCredits(VideoService svc) {
  var best = -1;
  for (final r in kMiniMaxResolutions) {
    final c = svc.creditsForKey(kPresetVideoSeconds, r);
    if (best < 0 || c < best) best = c;
  }
  return best < 0 ? 0 : best;
}

/// v11.65 speed pick (Standard = Phosor, Fast ⚡ = fal). Writes the shared
/// [VideoService.preferFast]; hidden when Fast is not available.
class VideoSpeedChips extends StatelessWidget {
  const VideoSpeedChips({super.key, required this.svc, this.onChanged});
  final VideoService svc;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: svc.fastAvailable,
    builder: (context, available, _) {
      if (!available) return const SizedBox.shrink();
      return ValueListenableBuilder<bool>(
        valueListenable: svc.preferFast,
        builder: (context, fast, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 14, bottom: 6),
              child: Text('Speed', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final f in const [false, true])
                  ChoiceChip(
                    key: ValueKey('video_speed_${f ? 'fast' : 'standard'}'),
                    label: Text(f ? '$kFastVideoTitle · $kFastVideoNote' : '$kStandardVideoTitle · $kStandardVideoNote'),
                    selected: f == fast,
                    onSelected: (_) {
                      svc.preferFast.value = f;
                      onChanged?.call();
                    },
                  ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

/// True when the next video should use Fast ⚡.
bool wantsFast(VideoService svc) => svc.fastAvailable.value && svc.preferFast.value;

String videoFromLabel(int credits) => 'from $kCreditGlyph$credits';
String makeVideoLabel(int credits) => 'Generate · $kCreditGlyph$credits';

enum VideoPhotoSource { last, camera, gallery }

/// Where the photo comes from. The last shot (if any) is pre-selected.
Future<VideoPhotoSource?> showVideoPhotoSourceSheet(
  BuildContext context, {
  required String title,
  File? lastPhoto,
}) {
  return showModalBottomSheet<VideoPhotoSource>(
    context: context,
    backgroundColor: AppColors.surface,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          key: const ValueKey('video_source_sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            const Text('Pick a photo to turn into a video',
                style: TextStyle(color: AppColors.textSecondary)),
            const SizedBox(height: 12),
            if (lastPhoto != null)
              ListTile(
                key: const ValueKey('video_src_last'),
                selected: true,
                selectedTileColor: AppColors.proGold.withValues(alpha: 0.12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: AppColors.proGold),
                ),
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 27,
                    height: 48,
                    child: Image.file(lastPhoto, fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const Icon(Icons.photo)),
                  ),
                ),
                title: const Text('Use last photo'),
                trailing: const Icon(Icons.check_circle, color: AppColors.proGold),
                onTap: () => Navigator.pop(ctx, VideoPhotoSource.last),
              ),
            ListTile(
              key: const ValueKey('video_src_camera'),
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take photo'),
              onTap: () => Navigator.pop(ctx, VideoPhotoSource.camera),
            ),
            ListTile(
              key: const ValueKey('video_src_gallery'),
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(ctx, VideoPhotoSource.gallery),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Confirm sheet → chosen resolution (null = cancelled).
Future<String?> showVideoConfirmSheet(
  BuildContext context, {
  required AiStyle style,
  required File photo,
  VideoService? svc,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    builder: (_) => VideoConfirmSheet(style: style, photo: photo, svc: svc ?? VideoService.instance),
  );
}

class VideoConfirmSheet extends StatefulWidget {
  const VideoConfirmSheet({super.key, required this.style, required this.photo, required this.svc});
  final AiStyle style;
  final File photo;
  final VideoService svc;
  @override
  State<VideoConfirmSheet> createState() => _VideoConfirmSheetState();
}

class _VideoConfirmSheetState extends State<VideoConfirmSheet> {
  String _res = kDefaultVideoResolution;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, int>>(
      valueListenable: widget.svc.credits,
      builder: (context, _, _) {
        final fast = wantsFast(widget.svc);
        final c = widget.svc.creditsForKey(kPresetVideoSeconds, _res, fast: fast);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Column(
              key: const ValueKey('video_confirm_sheet'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SizedBox(
                        key: const ValueKey('video_confirm_preview'),
                        width: 90,
                        height: 160,
                        child: Image.file(widget.photo, fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const ColoredBox(
                                color: AppColors.card, child: Icon(Icons.photo))),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            const Icon(Icons.play_circle_fill_rounded, size: 18),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(widget.style.name,
                                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                            ),
                            SaveStyleButton(
                              key: const ValueKey('video_confirm_save'),
                              styleId: widget.style.id,
                              video: true,
                            ),
                          ]),
                          const SizedBox(height: 4),
                          const Text('$kPresetVideoSeconds s video · 9:16',
                              style: TextStyle(color: AppColors.textSecondary)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const Text('Resolution', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final r in kMiniMaxResolutions)
                      ChoiceChip(
                        key: ValueKey('preset_res_$r'),
                        label: CreditText('$r · $kCreditGlyph${widget.svc.creditsForKey(kPresetVideoSeconds, r, fast: fast)}'),
                        selected: r == _res,
                        onSelected: (_) => setState(() => _res = r),
                      ),
                  ],
                ),
                VideoSpeedChips(svc: widget.svc, onChanged: () => setState(() {})),
                const SizedBox(height: 16),
                FilledButton(
                  key: const ValueKey('preset_go'),
                  onPressed: () => Navigator.pop(context, _res),
                  child: CreditText(makeVideoLabel(c)),
                ),
                const SizedBox(height: 6),
                const Text('Credits are used only when your video is ready.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
          ),
        );
      },
    );
  }
}
