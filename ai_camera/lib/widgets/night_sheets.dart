import 'package:flutter/material.dart';

import '../services/image_guard.dart';
import '../theme/app_theme.dart';

/// Pro Night tips (first use + the (i) button on the viewfinder).
Future<void> showProNightTips(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    showDragHandle: true,
    builder: (ctx) => const SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          key: ValueKey('pro_night_tips'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.nightlight_round, color: AppColors.proGold),
                SizedBox(width: 8),
                Text(
                  'Pro Night tips',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
              ],
            ),
            SizedBox(height: 12),
            Text(
              'Best for',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: 6),
            _Tip(
              Icons.location_city_rounded,
              'City lights, streets, buildings',
            ),
            _Tip(Icons.wb_twilight_rounded, 'After sunset'),
            _Tip(Icons.celebration_rounded, 'Diwali, wedding and cafe lights'),
            _Tip(Icons.people_alt_rounded, 'People near some light'),
            SizedBox(height: 10),
            Text(
              'Not for',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: 6),
            _Tip(
              Icons.dark_mode_rounded,
              'A fully dark room — use Normal Night or flash',
              warn: true,
            ),
            SizedBox(height: 10),
            Text(
              'Night stays night. AI never adds or removes things; if it '
              'does, the result is rejected and nothing is charged.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Tip extends StatelessWidget {
  const _Tip(this.icon, this.text, {this.warn = false});
  final IconData icon;
  final String text;
  final bool warn;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      children: [
        Icon(
          icon,
          size: 18,
          color: warn ? Colors.orange.shade300 : AppColors.proGold,
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 14))),
      ],
    ),
  );
}

/// Choice on the "Too dark for Pro Night" sheet.
enum TooDarkChoice { normalNight, flashOn }

/// Pro Night darkness gate: AI not called, nothing charged.
Future<TooDarkChoice?> showTooDarkSheet(BuildContext context) {
  return showModalBottomSheet<TooDarkChoice>(
    context: context,
    backgroundColor: AppColors.surface,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          key: const ValueKey('too_dark_sheet'),
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.dark_mode_rounded,
              size: 34,
              color: Colors.white70,
            ),
            const SizedBox(height: 10),
            const Text(
              kTooDarkMessage,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            const Text(
              'No AI used · no credits charged',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey('too_dark_normal_night'),
                    onPressed: () =>
                        Navigator.pop(ctx, TooDarkChoice.normalNight),
                    icon: const Icon(Icons.nightlight_round, size: 18),
                    label: const Text('Normal Night'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('too_dark_flash_on'),
                    onPressed: () => Navigator.pop(ctx, TooDarkChoice.flashOn),
                    icon: const Icon(Icons.flash_on_rounded, size: 18),
                    label: const Text('Flash on'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
