import 'package:flutter/material.dart';

import '../services/macro.dart' show MacroLevel, macroCreditsFor;
import '../services/macro_box.dart' show kMacroChipNames;
import '../theme/app_theme.dart';
import 'credit_icon.dart';

/// v11.33 Macro level chips: 1x (exit the level) + Macro, Close,
/// Microscope, Extreme, Ultra, each with its credits for [quality].
/// v11.48: collapsed to the selected chip + an arrow; the arrow (or the
/// chip) opens the full list, picking one collapses it again.
class MacroLevelChips extends StatefulWidget {
  const MacroLevelChips({
    super.key,
    required this.selected,
    required this.quality,
    required this.onSelected,
  });

  /// Null = 1x (no level).
  final MacroLevel? selected;
  final String quality;
  final ValueChanged<MacroLevel?>? onSelected;

  @override
  State<MacroLevelChips> createState() => _MacroLevelChipsState();
}

/// Chip text: "1x" or "Macro 🪙2".
String macroLevelChipText(MacroLevel? l, String quality) => l == null
    ? '1x'
    : '${kMacroChipNames[l]} 🪙${macroCreditsFor(l.id, quality: quality)}';

class _MacroLevelChipsState extends State<MacroLevelChips> {
  bool _expanded = false;

  void _toggle() => setState(() => _expanded = !_expanded);

  void _pick(MacroLevel? l) {
    setState(() => _expanded = false);
    widget.onSelected?.call(l);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onSelected != null;
    return Container(
      key: const ValueKey('macro_level_chips'),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(20),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_expanded)
              for (final l in <MacroLevel?>[null, ...MacroLevel.values])
                _chip(l, onTap: enabled ? () => _pick(l) : null)
            else
              _chip(widget.selected, onTap: enabled ? _toggle : null),
            GestureDetector(
              key: const ValueKey('macro_level_arrow'),
              onTap: enabled ? _toggle : null,
              child: SizedBox(
                width: 30,
                height: 30,
                child: Icon(
                  _expanded
                      ? Icons.keyboard_arrow_left_rounded
                      : Icons.keyboard_arrow_right_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(MacroLevel? l, {VoidCallback? onTap}) {
    final on = l == widget.selected;
    return GestureDetector(
      key: ValueKey('macro_level_${l?.id ?? '1x'}'),
      onTap: onTap,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(15),
          color: on ? Colors.white.withValues(alpha: 0.2) : null,
        ),
        child: CreditText(
          macroLevelChipText(l, widget.quality),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: on ? AppColors.proGold : Colors.white,
          ),
        ),
      ),
    );
  }
}
