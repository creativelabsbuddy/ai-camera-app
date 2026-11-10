import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Photo frame that, while [active], plays a premium "AI is working" effect
/// directly on the image: a soft light band sweeps diagonally across the
/// photo pixels (via [ShaderMask] + [BlendMode.srcATop], so letterbox areas
/// stay untouched), a light vignette, a breathing accent border and a small
/// floating status chip near the top. The photo stays visible underneath.
class AiWorkingFrame extends StatefulWidget {
  const AiWorkingFrame({
    super.key,
    required this.active,
    required this.label,
    required this.child,
    this.light = false,
    this.showElapsed = false,
    this.onCancel,
  });

  /// Shows "· 12s" (seconds since the AI work started) in the status chip.
  final bool showElapsed;

  /// When set, a Cancel button sits at the bottom of the frame while active.
  final VoidCallback? onCancel;

  final bool active;

  /// Lighter variant (e.g. saving): softer band, no vignette.
  final bool light;
  final String label;
  final Widget child;

  @override
  State<AiWorkingFrame> createState() => AiWorkingFrameState();
}

class AiWorkingFrameState extends State<AiWorkingFrame>
    with TickerProviderStateMixin {
  static const _radius = 20.0;

  /// Drives the sweep, border pulse and chip dots.
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  /// Fades the whole effect in/out so it never pops.
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
    reverseDuration: const Duration(milliseconds: 450),
  );

  /// Whole seconds since [_start] (ticked by a timer so tests can fake it).
  int _elapsed = 0;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    if (widget.active) _start();
    _fade.addStatusListener((status) {
      if (status == AnimationStatus.dismissed) _loop.stop();
    });
  }

  @override
  void didUpdateWidget(covariant AiWorkingFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active != oldWidget.active) {
      if (widget.active) {
        _start();
      } else {
        _ticker?.cancel();
        _fade.reverse();
      }
    }
  }

  void _start() {
    if (!_loop.isAnimating) _loop.repeat();
    _fade.forward();
    _ticker?.cancel();
    _elapsed = 0;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed++);
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _loop.dispose();
    _fade.dispose();
    super.dispose();
  }

  /// Band position in gradient-width units: sweeps from off-left to
  /// off-right during the first ~75% of the loop, then rests briefly.
  double _bandOffset(double t) {
    final p = Curves.easeInOutCubic.transform((t / 0.75).clamp(0.0, 1.0));
    return -1.6 + p * 3.2;
  }

  Shader _sweepShader(Rect bounds, double t, double strength) {
    final a = strength * (widget.light ? 0.55 : 1.0);
    return LinearGradient(
      begin: const Alignment(-1.0, -0.6),
      end: const Alignment(1.0, 0.6),
      colors: [
        Colors.transparent,
        AppColors.accent.withValues(alpha: 0.10 * a),
        AppColors.accentSoft.withValues(alpha: 0.28 * a),
        Colors.white.withValues(alpha: 0.42 * a),
        AppColors.accentSoft.withValues(alpha: 0.28 * a),
        AppColors.accent.withValues(alpha: 0.10 * a),
        Colors.transparent,
      ],
      stops: const [0.30, 0.38, 0.45, 0.50, 0.55, 0.62, 0.70],
      transform: _SlidingGradientTransform(_bandOffset(t)),
    ).createShader(bounds);
  }

  @override
  Widget build(BuildContext context) {
    // Background sits outside the ShaderMask so the sweep only lights the
    // photo's own pixels, not the letterbox bars.
    return ClipRRect(
      borderRadius: BorderRadius.circular(_radius),
      child: ColoredBox(
        color: AppColors.surface,
        child: AnimatedBuilder(
          animation: Listenable.merge([_loop, _fade]),
          child: widget.child,
          builder: (context, photo) {
            final strength = Curves.easeOut.transform(_fade.value);
            final t = _loop.value;
            final pulse = 0.5 + 0.5 * math.sin(t * 2 * math.pi);

            return Stack(
              fit: StackFit.expand,
              children: [
                // Shimmer band painted only over the photo's own pixels.
                ShaderMask(
                  blendMode: BlendMode.srcATop,
                  shaderCallback: (bounds) => strength == 0
                      ? const LinearGradient(
                          colors: [Colors.transparent, Colors.transparent],
                        ).createShader(bounds)
                      : _sweepShader(bounds, t, strength),
                  child: photo!,
                ),
                if (strength > 0) ...[
                  // Soft vignette — keeps the photo readable.
                  if (!widget.light)
                    IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            radius: 1.05,
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.32 * strength),
                            ],
                            stops: const [0.55, 1.0],
                          ),
                        ),
                      ),
                    ),
                  // Breathing accent edge glow.
                  IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(_radius),
                        border: Border.all(
                          width: 1.4,
                          color: AppColors.accentSoft.withValues(
                            alpha:
                                (0.18 + 0.32 * pulse) *
                                strength *
                                (widget.light ? 0.6 : 1.0),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Floating status chip near the top of the photo.
                  Positioned(
                    top: 14,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Center(
                        child: Opacity(
                          opacity: strength,
                          child: Transform.translate(
                            offset: Offset(0, -8 * (1 - strength)),
                            child: AiStatusChip(
                              key: const ValueKey('ai_status_chip'),
                              label: widget.showElapsed
                                  ? '${widget.label} · ${_elapsed}s'
                                  : widget.label,
                              t: t,
                              pulse: pulse,
                              light: widget.light,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (widget.onCancel != null && widget.active)
                    Positioned(
                      bottom: 16,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Opacity(
                          opacity: strength,
                          child: FilledButton.tonalIcon(
                            key: const ValueKey('ai_cancel'),
                            onPressed: widget.onCancel,
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.bg.withValues(
                                alpha: 0.72,
                              ),
                              foregroundColor: AppColors.textPrimary,
                              visualDensity: VisualDensity.compact,
                            ),
                            icon: const Icon(Icons.close_rounded, size: 18),
                            label: const Text('Cancel'),
                          ),
                        ),
                      ),
                    ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SlidingGradientTransform extends GradientTransform {
  const _SlidingGradientTransform(this.offset);

  /// Horizontal shift as a fraction of the bounds width.
  final double offset;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * offset, 0, 0);
}

class AiStatusChip extends StatelessWidget {
  const AiStatusChip({
    super.key,
    required this.label,
    required this.t,
    required this.pulse,
    required this.light,
  });

  final String label;
  final double t;
  final double pulse;
  final bool light;

  @override
  Widget build(BuildContext context) {
    final dots = (t * 4).floor() % 4; // 0..3 animated ellipsis
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
      decoration: BoxDecoration(
        color: AppColors.bg.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: AppColors.accentSoft.withValues(alpha: 0.30 + 0.25 * pulse),
          width: 0.8,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.accent.withValues(alpha: 0.18 + 0.22 * pulse),
            blurRadius: 14 + 6 * pulse,
            spreadRadius: -2,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Transform.rotate(
            angle: math.sin(t * 2 * math.pi) * 0.25,
            child: Transform.scale(
              scale: 0.9 + 0.15 * pulse,
              child: Icon(
                light ? Icons.downloading_rounded : Icons.auto_awesome,
                size: 14,
                color: Color.lerp(
                  AppColors.accentSoft,
                  Colors.white,
                  pulse * 0.6,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          // Fixed-width dots so the chip doesn't jitter.
          SizedBox(
            width: 14,
            child: Text(
              '.' * dots,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
