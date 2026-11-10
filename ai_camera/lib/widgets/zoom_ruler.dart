import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

import '../services/zoom_ruler.dart';
import '../theme/app_theme.dart';

/// Samsung-style scrubbable zoom ruler: big centred live label ("22.0x")
/// over a gently curved ruler with a fixed centre needle. Drag left to zoom
/// in, right to zoom out. Lens chips and 10/30/100 are labelled ticks;
/// tapping a labelled tick jumps there.
class ZoomRuler extends StatefulWidget {
  const ZoomRuler({
    super.key,
    required this.scale,
    required this.zoom,
    required this.ticks,
    required this.onChanged,
    this.onInteraction,
  });

  final ZoomRulerScale scale;
  final double zoom;
  final List<RulerTick> ticks;
  final ValueChanged<double> onChanged;

  /// Any touch (keeps the ruler open).
  final VoidCallback? onInteraction;

  /// Pixels for the full min→max range = width × this.
  static const extentFactor = 1.8;

  @override
  State<ZoomRuler> createState() => _ZoomRulerState();
}

class _ZoomRulerState extends State<ZoomRuler> {
  double _dragStartZoom = 1;
  double _dragDx = 0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth.isFinite ? box.maxWidth : 360.0;
        final extent = w * ZoomRuler.extentFactor;
        return Column(
          key: const ValueKey('zoom_ruler'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              formatRulerLabel(widget.zoom),
              key: const ValueKey('zoom_ruler_label'),
              style: TextStyle(
                color: Colors.white,
                fontSize: 30,
                fontWeight: FontWeight.w700,
                shadows: [
                  Shadow(
                    color: Colors.black.withValues(alpha: 0.7),
                    blurRadius: 10,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            GestureDetector(
              key: const ValueKey('zoom_ruler_track'),
              behavior: HitTestBehavior.opaque,
              // Measure from touch-down so the touch slop isn't lost: the
              // ruler tracks the finger 1:1.
              dragStartBehavior: DragStartBehavior.down,
              onHorizontalDragStart: (_) {
                _dragStartZoom = widget.zoom;
                _dragDx = 0;
                widget.onInteraction?.call();
              },
              onHorizontalDragUpdate: (d) {
                _dragDx += d.delta.dx;
                widget.onInteraction?.call();
                widget.onChanged(
                  widget.scale.scrub(
                    from: _dragStartZoom,
                    dx: _dragDx,
                    extent: extent,
                  ),
                );
              },
              onTapUp: (d) {
                // Tap a labelled tick → jump to it.
                widget.onInteraction?.call();
                final centre = widget.scale.positionOf(widget.zoom);
                final t = centre + (d.localPosition.dx - w / 2) / extent;
                RulerTick? best;
                var bestDist = 24 / extent;
                for (final k in widget.ticks) {
                  if (k.kind != RulerTickKind.major) continue;
                  final dist = (widget.scale.positionOf(k.zoom) - t).abs();
                  if (dist < bestDist) {
                    best = k;
                    bestDist = dist;
                  }
                }
                if (best != null) widget.onChanged(best.zoom);
              },
              child: SizedBox(
                width: w,
                height: 58,
                child: CustomPaint(
                  painter: _RulerPainter(
                    scale: widget.scale,
                    zoom: widget.zoom,
                    ticks: widget.ticks,
                    extent: extent,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _RulerPainter extends CustomPainter {
  _RulerPainter({
    required this.scale,
    required this.zoom,
    required this.ticks,
    required this.extent,
  });

  final ZoomRulerScale scale;
  final double zoom;
  final List<RulerTick> ticks;
  final double extent;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final centre = scale.positionOf(zoom);
    // Gentle arc: ticks drop towards the edges (curved-ruler look).
    double sag(double x) {
      final n = (x - cx) / (size.width / 2);
      return 10 * n * n;
    }

    final tickPaint = Paint()..strokeCap = StrokeCap.round;
    for (final t in ticks) {
      final x = cx + (scale.positionOf(t.zoom) - centre) * extent;
      if (x < -20 || x > size.width + 20) continue;
      final edge = (1 - ((x - cx).abs() / (size.width / 2))).clamp(0.0, 1.0);
      final alpha = 0.25 + 0.75 * edge;
      final len = switch (t.kind) {
        RulerTickKind.major => 16.0,
        RulerTickKind.medium => 11.0,
        RulerTickKind.minor => 7.0,
      };
      final top = 8 + sag(x);
      tickPaint
        ..color =
            (t.kind == RulerTickKind.major ? Colors.white : Colors.white70)
                .withValues(alpha: alpha)
        ..strokeWidth = t.kind == RulerTickKind.major ? 2.2 : 1.3;
      canvas.drawLine(Offset(x, top), Offset(x, top + len), tickPaint);
      if (t.label != null) {
        final tp = TextPainter(
          text: TextSpan(
            text: t.label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: alpha),
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(x - tp.width / 2, top + len + 4));
      }
    }
    // Fixed centre needle.
    final needle = Paint()
      ..color = AppColors.proGold
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(cx, 2), Offset(cx, 30), needle);
    final tri = Path()
      ..moveTo(cx - 5, 0)
      ..lineTo(cx + 5, 0)
      ..lineTo(cx, 6)
      ..close();
    canvas.drawPath(tri, needle..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(_RulerPainter old) =>
      old.zoom != zoom || old.ticks != ticks || old.extent != extent;
}
