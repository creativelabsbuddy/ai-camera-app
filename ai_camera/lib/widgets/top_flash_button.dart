import 'package:flutter/material.dart';

import '../models/camera_options.dart';

/// v11.48 universal Flash button (top bar, every mode): icon + Off / Auto /
/// On text; tap cycles. Null [onTap] = greyed (front camera / busy).
class TopFlashButton extends StatelessWidget {
  const TopFlashButton({super.key, required this.flash, this.onTap});

  final FlashChoice flash;
  final VoidCallback? onTap;

  static String stateText(FlashChoice f) => switch (f) {
    FlashChoice.off => 'Off',
    FlashChoice.auto => 'Auto',
    FlashChoice.on => 'On',
  };

  @override
  Widget build(BuildContext context) {
    final on = flash != FlashChoice.off;
    final color = onTap == null
        ? Colors.white38
        : (on ? Colors.amber.shade300 : Colors.white);
    return Tooltip(
      message: flash.label,
      child: GestureDetector(
        key: const ValueKey('top_flash'),
        onTap: onTap,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(flash.icon, size: 18, color: color),
              const SizedBox(width: 4),
              Text(
                stateText(flash),
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
