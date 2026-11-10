import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/ai_gate.dart';

/// v11.52 full-screen "before AI" window over the preview: captured photo,
/// what will run, and either a countdown ring + Cancel (auto start), or
/// Cross (keep original) / Tick (start AI now) when [ask] is on.
class AiGateOverlay extends StatefulWidget {
  const AiGateOverlay({
    super.key,
    required this.photo,
    required this.label,
    required this.ask,
    required this.duration,
    required this.onChoice,
  });

  final File photo;
  final String label;
  final bool ask;
  final Duration duration;
  final ValueChanged<AiGateChoice> onChoice;

  @override
  State<AiGateOverlay> createState() => _AiGateOverlayState();
}

class _AiGateOverlayState extends State<AiGateOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  bool _done = false;

  @override
  void initState() {
    super.initState();
    if (!widget.ask) {
      _c.addStatusListener((s) {
        if (s == AnimationStatus.completed) _choose(AiGateChoice.start);
      });
      unawaited(_c.forward());
    }
  }

  void _choose(AiGateChoice c) {
    if (_done) return;
    _done = true;
    _c.stop();
    widget.onChoice(c);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('ai_gate'),
      color: Colors.black,
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Image.file(
                  widget.photo,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const SizedBox.expand(),
                ),
              ),
            ),
            Container(
              key: const ValueKey('ai_gate_label'),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white12,
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text(
                widget.label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.ask
                  ? 'Start AI on this photo?'
                  : 'AI starts in a moment · Cancel keeps the original',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.only(bottom: 22),
              child: widget.ask ? _askRow() : _countdownRow(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _countdownRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        AnimatedBuilder(
          animation: _c,
          builder: (_, _) {
            final left =
                (widget.duration.inMilliseconds * (1 - _c.value) / 1000).ceil();
            return SizedBox(
              width: 52,
              height: 52,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(
                    key: const ValueKey('ai_gate_ring'),
                    value: 1 - _c.value,
                    strokeWidth: 4,
                    color: Colors.amberAccent,
                    backgroundColor: Colors.white24,
                  ),
                  Text(
                    '$left',
                    key: const ValueKey('ai_gate_seconds'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(width: 20),
        FilledButton.icon(
          key: const ValueKey('ai_gate_cancel'),
          style: FilledButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
          ),
          onPressed: () => _choose(AiGateChoice.cancel),
          icon: const Icon(Icons.close_rounded),
          label: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _askRow() {
    Widget b(Key k, IconData i, Color c, String tip, AiGateChoice ch) =>
        Tooltip(
          message: tip,
          child: InkResponse(
            key: k,
            onTap: () => _choose(ch),
            radius: 40,
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(shape: BoxShape.circle, color: c),
              child: Icon(i, color: Colors.white, size: 34),
            ),
          ),
        );
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        b(
          const ValueKey('ai_gate_cross'),
          Icons.close_rounded,
          Colors.redAccent,
          'Keep original, no AI',
          AiGateChoice.cancel,
        ),
        const SizedBox(width: 48),
        b(
          const ValueKey('ai_gate_tick'),
          Icons.check_rounded,
          Colors.green,
          'Start AI',
          AiGateChoice.start,
        ),
      ],
    );
  }
}
