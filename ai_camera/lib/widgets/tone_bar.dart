import 'package:flutter/material.dart';

import '../services/tone.dart';
import '../theme/app_theme.dart';

/// v11.69 small pill used by the tone strips (camera + preview) and the
/// Natural | Studio chip. Minimal, Samsung-like.
class TonePill extends StatelessWidget {
  const TonePill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.dense = false,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: EdgeInsets.symmetric(
          horizontal: dense ? 11 : 13,
          vertical: dense ? 5 : 7,
        ),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.black.withValues(alpha: 0.42),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: selected ? Colors.white : Colors.white24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 14,
                color: selected ? Colors.black : Colors.white,
              ),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                color: selected ? Colors.black : Colors.white,
                fontSize: dense ? 12 : 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Swipeable strip of the free Tone presets (camera, above the shutter).
class TonePresetStrip extends StatelessWidget {
  const TonePresetStrip({
    super.key,
    required this.selected,
    required this.onSelected,
    this.dense = true,
  });

  final TonePreset selected;
  final ValueChanged<TonePreset>? onSelected;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: dense ? 32 : 38,
      child: ListView.separated(
        key: const ValueKey('tone_preset_strip'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: TonePreset.values.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final t = TonePreset.values[i];
          return Center(
            child: TonePill(
              key: ValueKey('tone_${t.name}'),
              label: t.label,
              selected: t == selected,
              dense: dense,
              onTap: onSelected == null ? null : () => onSelected!(t),
            ),
          );
        },
      ),
    );
  }
}

/// After-capture tone controls (Normal photos): Auto Tone on/off, Adjust,
/// Reset, and the presets strip. Hold the photo to see the original.
class ToneBar extends StatelessWidget {
  const ToneBar({
    super.key,
    required this.autoOn,
    required this.preset,
    required this.enabled,
    required this.canReset,
    required this.onAuto,
    required this.onPreset,
    required this.onAdjust,
    required this.onReset,
    this.showAuto = true,
    this.showPresets = true,
  });

  final bool showAuto;
  final bool showPresets;
  final bool autoOn;
  final TonePreset preset;
  final bool enabled;
  final bool canReset;
  final ValueChanged<bool> onAuto;
  final ValueChanged<TonePreset> onPreset;
  final VoidCallback onAdjust;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('tone_bar'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              if (showAuto) ...[
                TonePill(
                  key: const ValueKey('tone_auto_toggle'),
                  icon: autoOn
                      ? Icons.check_rounded
                      : Icons.auto_fix_high_outlined,
                  label: 'Auto Tone',
                  selected: autoOn,
                  dense: true,
                  onTap: enabled ? () => onAuto(!autoOn) : null,
                ),
                const SizedBox(width: 6),
              ],
              TonePill(
                key: const ValueKey('tone_adjust'),
                icon: Icons.tune_rounded,
                label: 'Adjust',
                selected: false,
                dense: true,
                onTap: enabled ? onAdjust : null,
              ),
              const SizedBox(width: 6),
              TonePill(
                key: const ValueKey('tone_reset'),
                icon: Icons.restart_alt_rounded,
                label: 'Reset',
                selected: false,
                dense: true,
                onTap: enabled && canReset ? onReset : null,
              ),
              const Spacer(),
              const Text(
                'Hold photo to compare',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 11),
              ),
            ],
          ),
        ),
        if (showPresets) ...[
          const SizedBox(height: 6),
          TonePresetStrip(
            selected: preset,
            onSelected: enabled ? onPreset : null,
          ),
        ],
      ],
    );
  }
}

/// Manual tone sliders (after Auto). [onChanged] fires live while dragging.
Future<void> showToneSliders(
  BuildContext context, {
  required ToneParams initial,
  required ValueChanged<ToneParams> onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    barrierColor: Colors.black12,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      var v = initial;
      return StatefulBuilder(
        builder: (ctx, set) {
          Widget row(
            String label,
            String key,
            double value,
            ToneParams Function(double) apply,
          ) {
            return Row(
              children: [
                SizedBox(
                  width: 92,
                  child: Text(label, style: const TextStyle(fontSize: 13)),
                ),
                Expanded(
                  child: Slider(
                    key: ValueKey('tone_slider_$key'),
                    value: value,
                    min: -1,
                    max: 1,
                    onChanged: (x) {
                      set(() => v = apply(x));
                      onChanged(v);
                    },
                  ),
                ),
                SizedBox(
                  width: 36,
                  child: Text(
                    '${(value * 100).round()}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            );
          }

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  row(
                    'Brightness',
                    'exposure',
                    v.exposure,
                    (x) => v.copyWith(exposure: x),
                  ),
                  row(
                    'Contrast',
                    'contrast',
                    v.contrast,
                    (x) => v.copyWith(contrast: x),
                  ),
                  row(
                    'Highlights',
                    'highlights',
                    v.highlights,
                    (x) => v.copyWith(highlights: x),
                  ),
                  row(
                    'Shadows',
                    'shadows',
                    v.shadows,
                    (x) => v.copyWith(shadows: x),
                  ),
                  row(
                    'Warmth',
                    'warmth',
                    v.warmth,
                    (x) => v.copyWith(warmth: x),
                  ),
                  row(
                    'Saturation',
                    'saturation',
                    v.saturation,
                    (x) => v.copyWith(saturation: x),
                  ),
                  Row(
                    children: [
                      TextButton(
                        key: const ValueKey('tone_sliders_reset'),
                        onPressed: () {
                          set(() => v = ToneParams.zero);
                          onChanged(v);
                        },
                        child: const Text('Reset sliders'),
                      ),
                      const Spacer(),
                      FilledButton(
                        key: const ValueKey('tone_sliders_done'),
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Done'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}
