import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/barcode_actions.dart';
import '../services/live_look.dart';
import '../services/live_policies.dart';
import '../theme/app_theme.dart';

/// Rule-of-thirds grid + optional level (horizon) line.
class GridLevelOverlay extends StatelessWidget {
  const GridLevelOverlay({
    super.key,
    required this.grid,
    required this.level,
    this.roll = 0,
    this.flat = false,
  });

  final bool grid;
  final bool level;
  final double roll;
  final bool flat;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: CustomPaint(
      key: const ValueKey('grid_level_overlay'),
      painter: _GridLevelPainter(grid: grid, level: level && !flat, roll: roll),
      child: const SizedBox.expand(),
    ),
  );
}

class _GridLevelPainter extends CustomPainter {
  _GridLevelPainter({
    required this.grid,
    required this.level,
    required this.roll,
  });
  final bool grid;
  final bool level;
  final double roll;

  @override
  void paint(Canvas canvas, Size size) {
    if (grid) {
      final p = Paint()
        ..color = Colors.white.withValues(alpha: 0.14)
        ..strokeWidth = 1;
      for (var i = 1; i < 3; i++) {
        final x = size.width * i / 3, y = size.height * i / 3;
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
        canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
      }
    }
    if (level) {
      final ok = isLevel(roll);
      final c = size.center(Offset.zero);
      final len = size.width * 0.18;
      final ref = Paint()
        ..color = Colors.white.withValues(alpha: 0.6)
        ..strokeWidth = 1.5;
      canvas.drawLine(c - Offset(len * 1.6, 0), c - Offset(len * 1.15, 0), ref);
      canvas.drawLine(c + Offset(len * 1.15, 0), c + Offset(len * 1.6, 0), ref);
      final r = -roll * math.pi / 180;
      final d = Offset(math.cos(r), math.sin(r)) * len;
      canvas.drawLine(
        c - d,
        c + d,
        Paint()
          ..color = ok ? AppColors.success : AppColors.proGold
          ..strokeWidth = ok ? 2.5 : 2
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_GridLevelPainter o) =>
      o.grid != grid || o.level != level || (o.roll - roll).abs() > 0.05;
}

/// Thin face boxes (frame pixel rects).
class FaceBoxesOverlay extends StatelessWidget {
  const FaceBoxesOverlay({super.key, required this.boxes});
  final List<Rect> boxes;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: CustomPaint(
      key: const ValueKey('face_boxes'),
      painter: _FacePainter(boxes),
      child: const SizedBox.expand(),
    ),
  );
}

class _FacePainter extends CustomPainter {
  _FacePainter(this.boxes);
  final List<Rect> boxes;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    for (final b in boxes) {
      canvas.drawRRect(RRect.fromRectAndRadius(b, const Radius.circular(8)), p);
    }
  }

  @override
  bool shouldRepaint(_FacePainter o) => o.boxes != boxes;
}

/// Tappable QR / barcode chip.
class ScanChip extends StatelessWidget {
  const ScanChip({
    super.key,
    required this.action,
    required this.onTap,
    required this.onDismiss,
  });

  final ScanAction action;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  IconData get _icon => switch (action.kind) {
    ScanKind.url => Icons.link_rounded,
    ScanKind.upi => Icons.currency_rupee_rounded,
    ScanKind.phone => Icons.call_rounded,
    ScanKind.email => Icons.mail_outline_rounded,
    ScanKind.wifi => Icons.wifi_rounded,
    ScanKind.text => Icons.notes_rounded,
  };

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    borderRadius: BorderRadius.circular(22),
    elevation: 3,
    child: InkWell(
      key: const ValueKey('scan_chip'),
      borderRadius: BorderRadius.circular(22),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon, size: 18, color: Colors.black87),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    action.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.black87,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    action.actionLabel,
                    style: const TextStyle(
                      color: AppColors.accent,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              key: const ValueKey('scan_chip_close'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 16, color: Colors.black54),
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    ),
  );
}

/// Subtle scene tip ("Food? Try Portrait…").
class SuggestionChip extends StatelessWidget {
  const SuggestionChip({
    super.key,
    required this.text,
    required this.onTap,
    required this.onDismiss,
  });

  final String text;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black.withValues(alpha: 0.55),
    borderRadius: BorderRadius.circular(18),
    child: InkWell(
      key: const ValueKey('scene_tip'),
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 2, 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.lightbulb_outline_rounded,
              size: 15,
              color: AppColors.proGold,
            ),
            const SizedBox(width: 6),
            Text(text, style: const TextStyle(fontSize: 12)),
            IconButton(
              key: const ValueKey('scene_tip_close'),
              visualDensity: VisualDensity.compact,
              iconSize: 14,
              icon: const Icon(Icons.close),
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    ),
  );
}

/// Corner badge for the live AI look: sample thumbnail for big changes
/// (outfit / place / anime) + "applies after the shutter".
class LiveLookBadge extends StatelessWidget {
  const LiveLookBadge({super.key, required this.look, required this.title});

  final LiveLook look;
  final String title;

  @override
  Widget build(BuildContext context) {
    Widget? thumb;
    if (look.sampleAsset != null) {
      thumb = Image.asset(look.sampleAsset!, fit: BoxFit.cover);
    } else if (look.sampleUrl != null) {
      thumb = Image.network(
        look.sampleUrl!,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const ColoredBox(color: AppColors.card),
      );
    }
    return IgnorePointer(
      child: Container(
        key: const ValueKey('live_look_badge'),
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (thumb != null)
              ClipRRect(
                key: const ValueKey('live_look_thumb'),
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(width: 72, height: 96, child: thumb),
              ),
            if (thumb != null) const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.auto_awesome,
                  size: 12,
                  color: AppColors.proGold,
                ),
                const SizedBox(width: 4),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            if (look.caption != null)
              SizedBox(
                width: 140,
                child: Text(
                  look.caption!,
                  textAlign: TextAlign.end,
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
