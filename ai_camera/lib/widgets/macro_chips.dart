import 'package:flutter/material.dart';

import '../services/zoom_range.dart' show formatZoom;
import '../theme/app_theme.dart';

/// v11.17: chip text, e.g. 1 → "1x", 1.5 → "1.5x" (was `${v.round()}x`,
/// which showed the 1.5x chip as "2x").
String macroChipLabel(double v) {
  final name = kMacroLevelChipNames[v];
  return name == null ? '${formatZoom(v)}x' : '${formatZoom(v)}x $name';
}

/// v11.20 level chips after 5x.
final Map<double, String> kMacroLevelChipNames = {
  6.0: 'Close',
  12.0: 'Micro',
  21.0: 'Extreme',
  30.0: 'Ultra',
};

/// Unique key per chip (1.5 → macro_chip_1.5; 2 → macro_chip_2).
String macroChipKey(double v) => 'macro_chip_${formatZoom(v)}';

/// Macro zoom chips (v11.17: real labels — 1.5 shows "1.5x", not "2x").
class MacroChips extends StatelessWidget {
  const MacroChips({
    super.key,
    required this.chips,
    required this.selected,
    required this.onSelected,
    this.locked = const {},
  });
  final List<double> chips;

  /// v11.32 chips whose level is not unlocked yet (lock icon; tapping still
  /// zooms there).
  final Set<double> locked;
  final double selected;
  final ValueChanged<double>? onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('macro_chips'),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(20),
      ),
      // v11.20: scrolls if the level chips don't fit.
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final v in chips)
              GestureDetector(
                key: ValueKey(macroChipKey(v)),
                onTap: onSelected == null ? null : () => onSelected!(v),
                child: Container(
                  width:
                      kMacroLevelChipNames.containsKey(v) || locked.contains(v)
                      ? null
                      : (v == v.roundToDouble() ? 30 : 38),
                  padding:
                      kMacroLevelChipNames.containsKey(v) || locked.contains(v)
                      ? const EdgeInsets.symmetric(horizontal: 9)
                      : null,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape:
                        kMacroLevelChipNames.containsKey(v) ||
                            locked.contains(v)
                        ? BoxShape.rectangle
                        : BoxShape.circle,
                    borderRadius:
                        kMacroLevelChipNames.containsKey(v) ||
                            locked.contains(v)
                        ? BorderRadius.circular(15)
                        : null,
                    color: (v - selected).abs() < 0.01
                        ? Colors.white.withValues(alpha: 0.2)
                        : null,
                  ),
                  child: !locked.contains(v)
                      ? _label(v)
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(right: 2),
                              child: Icon(
                                Icons.lock_rounded,
                                key: ValueKey('${macroChipKey(v)}_locked'),
                                size: 11,
                                color: Colors.white54,
                              ),
                            ),
                            _label(v),
                          ],
                        ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _label(double v) => Text(
    macroChipLabel(v),
    style: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w800,
      color: (v - selected).abs() < 0.01 ? AppColors.proGold : Colors.white,
    ),
  );
}
