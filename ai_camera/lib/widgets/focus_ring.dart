import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Samsung-like tap-to-focus ring: pops in (scale 1.35 → 1.0), pulses while
/// focusing, then fades. When AE/AF is locked it stays, turns gold and shows
/// an "AE/AF lock" label above it.
class FocusRing extends StatefulWidget {
  const FocusRing({
    super.key,
    required this.center,
    required this.diameter,
    required this.locked,
    required this.focused,
  });

  /// Ring centre in frame coordinates.
  final Offset center;
  final double diameter;
  final bool locked;

  /// AF converged (ring tightens + brightens).
  final bool focused;

  @override
  State<FocusRing> createState() => _FocusRingState();
}

class _FocusRingState extends State<FocusRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  )..forward();

  Timer? _fadeTimer;
  bool _faded = false;

  @override
  void initState() {
    super.initState();
    _scheduleFade();
  }

  @override
  void didUpdateWidget(FocusRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focused != widget.focused ||
        oldWidget.locked != widget.locked) {
      _scheduleFade();
    }
  }

  /// Plain tap: fade ~1.2 s after AF settles (or 2.5 s regardless).
  /// Locked: stays visible.
  void _scheduleFade() {
    _fadeTimer?.cancel();
    if (widget.locked) {
      if (_faded) setState(() => _faded = false);
      return;
    }
    _fadeTimer = Timer(
      Duration(milliseconds: widget.focused ? 1200 : 2500),
      () {
        if (mounted) setState(() => _faded = true);
      },
    );
  }

  @override
  void dispose() {
    _fadeTimer?.cancel();
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.diameter;
    final color = widget.locked ? AppColors.proGold : Colors.white;
    return Positioned(
      left: widget.center.dx - d / 2,
      top: widget.center.dy - d / 2 - (widget.locked ? 28 : 0),
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: _faded ? 0 : 1,
          duration: const Duration(milliseconds: 300),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.locked)
                Container(
                  key: const ValueKey('ae_af_lock_label'),
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'AE/AF lock',
                    style: TextStyle(
                      color: AppColors.proGold,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              AnimatedBuilder(
                animation: _pop,
                builder: (context, _) {
                  final t = Curves.easeOutBack.transform(_pop.value);
                  final scale = 1.35 - 0.35 * t * (widget.focused ? 1.0 : 0.92);
                  return Transform.scale(
                    scale: scale,
                    child: Container(
                      key: const ValueKey('focus_ring'),
                      width: d,
                      height: d,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: color.withValues(
                            alpha: widget.focused || widget.locked ? 0.95 : 0.7,
                          ),
                          width: widget.focused || widget.locked ? 2 : 1.4,
                        ),
                      ),
                      child: Center(
                        child: Container(
                          width: 4,
                          height: 4,
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.9),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
