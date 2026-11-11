import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

import '../services/zoom_chips.dart';

/// Samsung-style zoom pill: translucent rounded pill with the device's real
/// lens chips; the selected chip is a dark circle with the live value and a
/// "×" suffix. v9: long-press or drag sideways on the pill opens the
/// continuous zoom ruler (min → 100x); 30 / 100 live on the ruler as
/// shortcut ticks instead of extra chips. A four-dot button at the right
/// end opens the quick menu.
class ZoomPill extends StatelessWidget {
  const ZoomPill({
    super.key,
    required this.chips,
    required this.zoom,
    required this.onSelected,
    required this.onOpenMenu,
    this.showChips = true,
    this.showMenu = true,
    this.menuDot = false,
    this.menuNew = false,
    this.menuKey,
    this.onRulerOpen,
    this.onRulerDragStart,
    this.onRulerDragUpdate,
  });

  final ZoomChipSet chips;
  final double zoom;
  final ValueChanged<double>? onSelected;
  final VoidCallback onOpenMenu;

  /// v11.48: false in Macro (no four-dot menu).
  final bool showMenu;

  /// False while the camera is not ready: only the menu button is shown.
  final bool showChips;

  /// Small dot on the menu button when a filter / style is active.
  final bool menuDot;

  /// v11.54 gold sparkle "NEW" dot (until Styles was opened once).
  final bool menuNew;

  /// v11.59: key on the four-dot button (the Styles hint anchors to it).
  final Key? menuKey;

  /// Long-press on the pill → open the zoom ruler.
  final VoidCallback? onRulerOpen;

  /// Horizontal drag on the pill opens the ruler and scrubs it directly.
  final VoidCallback? onRulerDragStart;
  final ValueChanged<double>? onRulerDragUpdate;

  @override
  Widget build(BuildContext context) {
    final visible = chips.visible(zoom);
    final active = chips.activeIndex(zoom);
    final nPrimary = chips.primary.length;

    Widget chip(int i) {
      final s = visible[i];
      final isActive = i == active;
      return _ZoomChip(
        key: ValueKey('zoom_chip_${s.label}'),
        label: isActive ? '${formatChipZoom(zoom)}×' : s.label,
        active: isActive,
        onTap: onSelected == null ? null : () => onSelected!(s.value),
      );
    }

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showChips && (nPrimary > 1 || chips.extended.isNotEmpty))
          GestureDetector(
            onLongPress: onRulerOpen,
            dragStartBehavior: DragStartBehavior.down,
            onHorizontalDragStart: onRulerDragStart == null
                ? null
                : (_) => onRulerDragStart!(),
            onHorizontalDragUpdate: onRulerDragUpdate == null
                ? null
                : (d) => onRulerDragUpdate!(d.delta.dx),
            child: Container(
              key: const ValueKey('zoom_pill'),
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.38),
                borderRadius: BorderRadius.circular(26),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [for (var i = 0; i < nPrimary; i++) chip(i)],
              ),
            ),
          ),
        const SizedBox(width: 14),
        if (showMenu) FourDotButton(key: menuKey, onTap: onOpenMenu, dot: menuDot, sparkle: menuNew),
      ],
    );
    return FittedBox(fit: BoxFit.scaleDown, child: row);
  }
}

class _ZoomChip extends StatelessWidget {
  const _ZoomChip({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: active,
      label: 'Zoom $label',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active
                ? Colors.black.withValues(alpha: 0.72)
                : Colors.transparent,
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Text(
                label,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: active ? 13.5 : 12.5,
                  fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Four dots in a square (Samsung quick-menu button).
class FourDotButton extends StatelessWidget {
  const FourDotButton({super.key, required this.onTap, this.dot = false, this.sparkle = false});

  final VoidCallback onTap;
  final bool dot;

  /// v11.54: small gold sparkle "NEW" dot (Styles are here).
  final bool sparkle;

  @override
  Widget build(BuildContext context) {
    Widget d() => Container(
      width: 4.5,
      height: 4.5,
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
      ),
    );
    return Semantics(
      button: true,
      label: 'Quick menu',
      child: GestureDetector(
        key: const ValueKey('quick_menu_open'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.38),
            shape: BoxShape.circle,
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 13,
                height: 13,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [d(), d()],
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [d(), d()],
                    ),
                  ],
                ),
              ),
              if (sparkle)
                const Positioned(
                  top: 1,
                  right: 1,
                  child: Icon(
                    Icons.auto_awesome,
                    key: ValueKey('quick_menu_new'),
                    size: 13,
                    color: Color(0xFFFFC857),
                  ),
                ),
              if (dot && !sparkle)
                Positioned(
                  top: 7,
                  right: 7,
                  child: Container(
                    key: const ValueKey('quick_menu_dot'),
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                      color: Color(0xFFFFC857),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
