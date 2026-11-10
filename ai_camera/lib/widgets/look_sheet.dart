import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MaxLengthEnforcement;

import '../services/custom_prompt_policy.dart';
import '../services/enhance_policy.dart';
import '../services/look_service.dart' show kLookTiers, lookTierFor;
import '../models/ai_style.dart';
import '../models/quality_tier.dart';
import '../services/account_service.dart';
import '../services/entitlements.dart';
import '../theme/app_theme.dart';
import 'pro_upgrade_sheet.dart';
import 'style_thumb.dart';
import 'credit_icon.dart';
import 'compare_slider.dart';
import 'save_style_button.dart';
import '../services/style_samples.dart';

enum LookSheetAction { apply, takePhoto, pickGallery }

/// What the user chose in the look sheet. Nothing is charged by the sheet.
class LookSheetResult {
  const LookSheetResult(
    this.action, {
    this.customPrompt,
    this.tier = QualityTier.hd,
  });

  final LookSheetAction action;
  final String? customPrompt;
  final QualityTier tier;
}

/// v11.57: styles are never free — always show the credit cost.
bool lookIsFree({
  required AiStyle? style,
  required bool isPro,
  required bool trialAvailable,
}) => false;

/// "Apply · 🪙N" (v11.57: no Free label; always ONE image).
String lookApplyLabel({required int cost, required bool free}) =>
    'Apply · 🪙$cost';

/// v11.55: every style preview is a portrait reel frame (9:16).
const double kReelAspect = 9 / 16;

/// Size of each of the two side-by-side 9:16 frames (Look → Your photo) in
/// the apply sheet: fills [contentWidth] minus the arrow gap, capped so the
/// frames never exceed [maxHeight] (keeps options visible below).
Size lookPairFrameSize(double contentWidth, double maxHeight,
    {double arrowGap = 28}) {
  var w = (contentWidth - arrowGap) / 2;
  var h = w / kReelAspect;
  if (h > maxHeight) {
    h = maxHeight;
    w = h * kReelAspect;
  }
  return Size(w, h);
}

/// Single 9:16 frame (photo-source sheet): at most [maxHeight] tall
/// (~45% of the screen) and never wider than [contentWidth].
Size lookSingleFrameSize(double contentWidth, double maxHeight) {
  var h = maxHeight;
  var w = h * kReelAspect;
  if (w > contentWidth) {
    w = contentWidth;
    h = w / kReelAspect;
  }
  return Size(w, h);
}

/// Bottom sheet for a style (sample look on top, the user's photo below) or
/// a custom "Prompt" (style == null). Without a photo it asks
/// "Take photo" / "Choose from gallery".
Future<LookSheetResult?> showLookSheet(
  BuildContext context, {
  AiStyle? style,
  File? photo,
  QualityTier tier = QualityTier.hd,
  String? initialPrompt,
}) {
  return showModalBottomSheet<LookSheetResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => _LookSheet(
      style: style,
      photo: photo,
      tier: tier,
      initialPrompt: initialPrompt,
    ),
  );
}

class _LookSheet extends StatefulWidget {
  const _LookSheet({
    required this.style,
    required this.photo,
    required this.tier,
    this.initialPrompt,
  });

  final AiStyle? style;
  final File? photo;
  final QualityTier tier;
  final String? initialPrompt;

  @override
  State<_LookSheet> createState() => _LookSheetState();
}

class _LookSheetState extends State<_LookSheet> {
  late QualityTier _tier = lookTierFor(widget.tier);
  late final TextEditingController _prompt = TextEditingController(
    text: widget.initialPrompt ?? '',
  );

  bool get _custom => widget.style == null;

  /// Tiny safety list (no relevance checks — users may type anything).
  String? get _blocked =>
      _custom ? blockedCustomPromptReason(_prompt.text) : null;

  /// "enhance / clear / HD / sharp" only → tip instead of an AI call.
  bool get _enhanceOnly => _custom && isEnhanceOnlyPrompt(_prompt.text);

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final account = AccountService.instance;
    final media = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: media.size.height * 0.92),
        child: ValueListenableBuilder<CreditState?>(
          valueListenable: account.state,
          builder: (context, st, _) {
            final pro = st?.isPro(account.now) ?? false;
            final trial = st?.trialAvailable(StarterTrial.libraryStyle) ?? true;
            final cost = widget.style?.creditCost ?? _tier.credits;
            final free = lookIsFree(
              style: widget.style,
              isPro: pro,
              trialAvailable: trial,
            );
            final needsPro = (widget.style?.proOnly ?? false) && !pro;
            final sample = _custom ? null : StyleSamples.instance.of(widget.style!);
            final hasSample = sample?.hasSlider ?? false;
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
              child: Column(
                key: const ValueKey('look_sheet'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppColors.textSecondary.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(9),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _custom ? 'Prompt' : widget.style!.name,
                          key: const ValueKey('look_sheet_title'),
                          style: const TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      if (!_custom)
                        SaveStyleButton(
                          key: const ValueKey('look_sheet_save'),
                          styleId: widget.style!.id,
                          video: false,
                          showLabel: true,
                        ),
                    ],
                  ),
                  if (!_custom)
                    Text(
                      '${widget.style!.category}${widget.style!.proOnly ? ' · Pro' : ''}',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                  const SizedBox(height: 12),
                  if (hasSample) ...[
                    Center(
                      child: _Framed(
                        key: const ValueKey('look_sample_slider'),
                        size: lookSingleFrameSize(
                            media.size.width - 36, media.size.height * 0.40),
                        label: 'Sample',
                        child: _SampleSlider(sample: sample!),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (!_custom && !hasSample && widget.photo != null)
                    Builder(builder: (_) {
                      final sz = lookPairFrameSize(
                          media.size.width - 36, media.size.height * 0.40);
                      return Row(
                        key: const ValueKey('look_pair'),
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _Framed(
                            key: const ValueKey('look_frame_look'),
                            size: sz,
                            label: 'Look',
                            child: StyleThumb(style: widget.style!),
                          ),
                          const SizedBox(
                            width: 28,
                            child: Icon(
                              Icons.arrow_forward_rounded,
                              size: 18,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          _Framed(
                            key: const ValueKey('look_frame_photo'),
                            size: sz,
                            label: 'Your photo',
                            child: Image.file(widget.photo!, fit: BoxFit.cover),
                          ),
                        ],
                      );
                    }),
                  if (!_custom && !hasSample && widget.photo == null)
                    Center(
                      child: _Framed(
                        key: const ValueKey('look_frame_look'),
                        size: lookSingleFrameSize(
                            media.size.width - 36, media.size.height * 0.42),
                        label: 'Look',
                        child: StyleThumb(style: widget.style!),
                      ),
                    ),
                  if (_custom) ...[
                    TextField(
                      key: const ValueKey('custom_prompt_field'),
                      controller: _prompt,
                      maxLength: kCustomPromptMaxChars,
                      maxLengthEnforcement: MaxLengthEnforcement.enforced,
                      maxLines: 3,
                      minLines: 2,
                      autofocus: widget.photo != null,
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
                      padding: EdgeInsets.only(top: 4),
                      child: Text(
                        'Your face and identity are always kept the same.',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  if (widget.photo != null) ...[
                    if (_custom || hasSample)
                      Center(
                        child: _Framed(
                          key: const ValueKey('look_frame_photo'),
                          size: lookSingleFrameSize(
                              media.size.width - 36, media.size.height * 0.30),
                          label: 'Your photo',
                          child: Image.file(widget.photo!, fit: BoxFit.cover),
                        ),
                      ),
                    const SizedBox(height: 10),
                    if (needsPro)
                      FilledButton.icon(
                        key: const ValueKey('look_get_pro'),
                        onPressed: () => showProUpgradeSheet(
                          context,
                          reason: 'This style is Pro only',
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.proGold,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: const Icon(Icons.workspace_premium),
                        label: const Text('Pro only · Get Pro'),
                      )
                    else
                      FilledButton(
                        key: const ValueKey('look_apply'),
                        onPressed:
                            _custom &&
                                (_prompt.text.trim().isEmpty ||
                                    _blocked != null ||
                                    _enhanceOnly)
                            ? null
                            : () => Navigator.pop(
                                context,
                                LookSheetResult(
                                  LookSheetAction.apply,
                                  customPrompt: _custom
                                      ? normalizeCustomPrompt(_prompt.text)
                                      : null,
                                  tier: _tier,
                                ),
                              ),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: CreditText(
                          lookApplyLabel(cost: cost, free: free),
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    if (!free && !needsPro)
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Text(
                          'Credits are used only if the AI photo is ready.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                  ] else ...[
                    const Text(
                      'Add your photo to try this look',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            key: const ValueKey('look_take_photo'),
                            onPressed: () => Navigator.pop(
                              context,
                              LookSheetResult(
                                LookSheetAction.takePhoto,
                                customPrompt: _custom
                                    ? _prompt.text.trim()
                                    : null,
                                tier: _tier,
                              ),
                            ),
                            icon: const Icon(Icons.photo_camera_rounded),
                            label: const Text('Take photo'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            key: const ValueKey('look_pick_gallery'),
                            onPressed: () => Navigator.pop(
                              context,
                              LookSheetResult(
                                LookSheetAction.pickGallery,
                                customPrompt: _custom
                                    ? _prompt.text.trim()
                                    : null,
                                tier: _tier,
                              ),
                            ),
                            icon: const Icon(Icons.photo_library_outlined),
                            label: const Text('Choose from gallery'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Framed extends StatelessWidget {
  const _Framed({
    super.key,
    required this.size,
    required this.label,
    required this.child,
  });

  final Size size;
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size.width,
    height: size.height,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: AppColors.card, child: child),
          Positioned(
            left: 8,
            top: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// v11.56: the style's real before/after sample (drag to compare).
class _SampleSlider extends StatelessWidget {
  const _SampleSlider({required this.sample});
  final StyleSample sample;

  Widget _img(String url) => FutureBuilder<File?>(
    future: StyleSamples.instance.file(url),
    builder: (context, snap) => snap.data == null
        ? const ColoredBox(color: AppColors.card)
        : Image.file(snap.data!, fit: BoxFit.cover, gaplessPlayback: true),
  );

  @override
  Widget build(BuildContext context) => SampleCompareSlider(
    before: _img(sample.before!),
    after: _img(sample.after!),
  );
}
