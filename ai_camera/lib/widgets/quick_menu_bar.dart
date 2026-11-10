import 'package:flutter/material.dart';

import '../models/camera_options.dart';
import '../models/quality_tier.dart';

/// Rounded translucent quick-menu bar (Samsung style) that replaces the zoom
/// pill: Settings, Night, Styles (filters row), Timer, Ratio, Quality, ✕
/// (v9 features first so they fit without scrolling on narrow phones).
/// Scrolls horizontally on narrow phones; ✕ stays pinned on the right.
class QuickMenuBar extends StatelessWidget {
  const QuickMenuBar({
    super.key,
    this.flash = FlashChoice.off,
    required this.timer,
    required this.ratio,
    required this.tier,
    required this.stylesOpen,
    required this.styleActive,
    this.stylesLocked = false,
    required this.onSettings,
    this.onFlash,
    required this.onTimer,
    required this.onRatio,
    required this.onQuality,
    required this.onStyles,
    required this.onClose,
    this.flashAvailable = true,
    this.night = false,
    this.onNight,
  });

  final FlashChoice flash;
  final TimerChoice timer;
  final FrameRatio ratio;
  final QualityTier tier;
  final bool stylesOpen;
  final bool styleActive;

  /// Small lock on Styles (unused since v9: styles work in every mode).
  final bool stylesLocked;

  /// Night mode on (moon highlighted).
  final bool night;
  final VoidCallback? onNight;
  final bool flashAvailable;
  final VoidCallback onSettings;
  final VoidCallback? onFlash;
  final VoidCallback? onTimer;
  final VoidCallback? onRatio;
  final VoidCallback? onQuality;
  final VoidCallback onStyles;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('quick_menu'),
      height: 50,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.only(left: 4, right: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(25),
      ),
      child: Row(
        children: [
          Expanded(
            // v11.54: items spread over the whole bar (no blank end);
            // scrolls only when they do not fit.
            child: LayoutBuilder(
              builder: (context, c) {
                final items = <Widget>[
                  _Item(
                    key: const ValueKey('qm_settings'),
                    tooltip: 'Settings',
                    onTap: onSettings,
                    child: const Icon(Icons.settings_outlined),
                  ),
                  // v11.48: Flash moved to the top bar (all modes).
                  _Item(
                    key: const ValueKey('qm_night'),
                    tooltip: night ? 'Night on' : 'Night off',
                    onTap: onNight,
                    selected: night,
                    active: night,
                    child: Icon(
                      night
                          ? Icons.nightlight_round
                          : Icons.nightlight_outlined,
                    ),
                  ),
                  _Item(
                    key: const ValueKey('qm_styles'),
                    tooltip: 'Styles',
                    onTap: onStyles,
                    selected: stylesOpen,
                    active: styleActive,
                    locked: stylesLocked,
                    child: const Icon(Icons.auto_awesome_outlined),
                  ),
                  // v11.51: Filters live in the Styles row now.
                  _Item(
                    key: const ValueKey('qm_timer'),
                    tooltip: timer.label,
                    onTap: onTimer,
                    active: timer != TimerChoice.off,
                    child: Icon(timer.icon),
                  ),
                  _Item(
                    key: const ValueKey('qm_ratio'),
                    tooltip: 'Aspect ratio ${ratio.label}',
                    onTap: onRatio,
                    child: _TextIcon(ratio.label),
                  ),
                  _Item(
                    key: const ValueKey('qm_quality'),
                    tooltip: 'Quality ${tier.label}',
                    onTap: onQuality,
                    child: _TextIcon(tier.shortLabel),
                  ),
                ];
                final fits = c.maxWidth >= items.length * 44;
                return fits
                    ? Row(
                        key: const ValueKey('quick_menu_items'),
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: items,
                      )
                    : SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(children: items),
                      );
              },
            ),
          ),
          GestureDetector(
            key: const ValueKey('quick_menu_close'),
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close_rounded, size: 20),
            ),
          ),
        ],
      ),
    );
  }
}

class _TextIcon extends StatelessWidget {
  const _TextIcon(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      color: Colors.white,
      fontSize: 13.5,
      fontWeight: FontWeight.w700,
    ),
  );
}

class _Item extends StatelessWidget {
  const _Item({
    super.key,
    required this.tooltip,
    required this.onTap,
    required this.child,
    this.selected = false,
    this.active = false,
    this.locked = false,
  });

  final String tooltip;
  final VoidCallback? onTap;
  final Widget child;

  /// Its strip is open.
  final bool selected;

  /// A non-default value is set (small gold dot).
  final bool active;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final color = onTap == null ? Colors.white38 : Colors.white;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 42,
          height: 42,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: selected ? Colors.white.withValues(alpha: 0.16) : null,
            borderRadius: BorderRadius.circular(21),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              IconTheme(
                data: IconThemeData(color: color, size: 22),
                child: child,
              ),
              if (active)
                Positioned(
                  top: 6,
                  right: 9,
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: Color(0xFFFFC857),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              if (locked)
                const Positioned(
                  bottom: 5,
                  right: 7,
                  child: Icon(
                    Icons.lock_rounded,
                    size: 11,
                    color: Color(0xFFFFC857),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
