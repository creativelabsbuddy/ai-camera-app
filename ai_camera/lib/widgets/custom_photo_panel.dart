import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MaxLengthEnforcement;

import '../models/quality_tier.dart';
import '../screens/look_screen.dart';
import '../services/custom_prompt_policy.dart';
import '../services/enhance_policy.dart';
import '../services/look_service.dart';
import '../theme/app_theme.dart';
import 'credit_icon.dart';

/// v11.56 Custom window → "AI Photo" section: Prompt field, quality, the
/// photo (given, taken with the camera, or from the gallery) and Apply.
/// Always ONE image; credits are used only when the AI photo is ready.
class CustomPhotoPanel extends StatefulWidget {
  const CustomPhotoPanel({
    super.key,
    this.photo,
    this.tier = QualityTier.hd,
    this.onTakePhoto,
  });

  final File? photo;
  final QualityTier tier;

  /// Camera screen: close the window and take a photo; the prompt is then
  /// applied to the shot. Null → no "Take photo" button.
  final void Function(String prompt, QualityTier tier)? onTakePhoto;

  @override
  State<CustomPhotoPanel> createState() => _CustomPhotoPanelState();
}

class _CustomPhotoPanelState extends State<CustomPhotoPanel> {
  final _prompt = TextEditingController();
  late QualityTier _tier = lookTierFor(widget.tier);
  late File? _photo = widget.photo;

  String? get _blocked => blockedCustomPromptReason(_prompt.text);
  bool get _enhanceOnly => isEnhanceOnlyPrompt(_prompt.text);
  bool get _promptOk => _prompt.text.trim().isNotEmpty && _blocked == null && !_enhanceOnly;

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _gallery() async {
    final f = await LookFlowDeps.galleryPicker();
    if (f != null && mounted) setState(() => _photo = f);
  }

  Future<void> _apply() async {
    final photo = _photo;
    if (photo == null || !_promptOk) return;
    final job = LookJob(
      image: photo,
      customPrompt: normalizeCustomPrompt(_prompt.text),
      tier: _tier,
    );
    if (!await confirmPersonForLook(context, job) || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => LookScreen(original: photo, job: job)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const ValueKey('custom_photo_panel'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 6, bottom: 8),
          child: Text('Prompt', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
        TextField(
          key: const ValueKey('custom_prompt_field'),
          controller: _prompt,
          maxLength: kCustomPromptMaxChars,
          maxLengthEnforcement: MaxLengthEnforcement.enforced,
          maxLines: 3,
          minLines: 2,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'Prompt',
            hintText: 'Write your prompt…',
            errorText: _blocked,
            errorMaxLines: 2,
            helperText: _enhanceOnly ? kEnhanceOnlyTip : null,
            helperMaxLines: 3,
            helperStyle: const TextStyle(color: AppColors.proGold),
            border: const OutlineInputBorder(),
          ),
        ),
        Wrap(
          spacing: 6,
          children: [
            for (final t in kLookTiers)
              ChoiceChip(
                key: ValueKey('custom_tier_${t.id}'),
                label: CreditText('${t.shortLabel} · 🪙${t.credits}'),
                selected: t == _tier,
                onSelected: (_) => setState(() => _tier = t),
              ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.only(top: 4, bottom: 10),
          child: Text('Your face and identity are always kept the same.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
        ),
        if (_photo != null) ...[
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                key: const ValueKey('custom_photo_frame'),
                width: 150,
                height: 150 * 16 / 9,
                child: Image.file(_photo!, fit: BoxFit.cover),
              ),
            ),
          ),
          TextButton(
            key: const ValueKey('custom_change_photo'),
            onPressed: () => unawaited(_gallery()),
            child: const Text('Change photo'),
          ),
          FilledButton(
            key: const ValueKey('look_apply'),
            onPressed: _promptOk ? () => unawaited(_apply()) : null,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: CreditText('Apply · 🪙${_tier.credits}',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('Credits are used only if the AI photo is ready.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary, fontSize: 11.5)),
          ),
        ] else ...[
          const Text('Add your photo', textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary)),
          const SizedBox(height: 10),
          Row(
            children: [
              if (widget.onTakePhoto != null) ...[
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey('look_take_photo'),
                    onPressed: _promptOk
                        ? () => widget.onTakePhoto!(normalizeCustomPrompt(_prompt.text), _tier)
                        : null,
                    icon: const Icon(Icons.photo_camera_rounded),
                    label: const Text('Take photo'),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('look_pick_gallery'),
                  onPressed: () => unawaited(_gallery()),
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Choose from gallery'),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
