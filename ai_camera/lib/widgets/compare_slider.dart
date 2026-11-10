import 'dart:io';

import 'package:flutter/material.dart';

/// Before / after compare: the after image is revealed left of a draggable
/// divider (drag or tap anywhere).
class CompareSlider extends StatefulWidget {
  const CompareSlider({
    super.key,
    required this.before,
    required this.after,
    this.initial = 0.5,
  });

  final File before;
  final File after;
  final double initial;

  @override
  State<CompareSlider> createState() => _CompareSliderState();
}

class _CompareSliderState extends State<CompareSlider> {
  late double _pos = widget.initial;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        void update(double dx) =>
            setState(() => _pos = (dx / w).clamp(0.0, 1.0));
        return GestureDetector(
          key: const ValueKey('compare_slider'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) => update(d.localPosition.dx),
          onTapDown: (d) => update(d.localPosition.dx),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.file(
                widget.before,
                fit: BoxFit.contain,
                gaplessPlayback: true,
              ),
              ClipRect(
                clipper: _LeftClipper(_pos),
                child: Image.file(
                  widget.after,
                  key: ValueKey(widget.after.path),
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                ),
              ),
              Positioned(
                left: (w * _pos - 1).clamp(0.0, w - 2),
                top: 0,
                bottom: 0,
                child: Container(width: 2, color: Colors.white),
              ),
              Positioned(
                left: (w * _pos - 16).clamp(0.0, w - 32),
                top: box.maxHeight / 2 - 16,
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.compare_arrows,
                    size: 20,
                    color: Colors.black,
                  ),
                ),
              ),
              const Positioned(left: 10, bottom: 10, child: _Tag('After')),
              const Positioned(right: 10, bottom: 10, child: _Tag('Before')),
            ],
          ),
        );
      },
    );
  }
}

class _LeftClipper extends CustomClipper<Rect> {
  _LeftClipper(this.fraction);

  final double fraction;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width * fraction, size.height);

  @override
  bool shouldReclip(_LeftClipper old) => old.fraction != fraction;
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      text,
      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
    ),
  );
}

/// v11.56 style sample before/after (any two widgets, 9:16 cover). Drag or
/// tap to move the divider; AFTER is revealed on the left like [CompareSlider].
class SampleCompareSlider extends StatefulWidget {
  const SampleCompareSlider({
    super.key,
    required this.before,
    required this.after,
    this.initial = 0.5,
  });

  final Widget before;
  final Widget after;
  final double initial;

  @override
  State<SampleCompareSlider> createState() => _SampleCompareSliderState();
}

class _SampleCompareSliderState extends State<SampleCompareSlider> {
  late double _pos = widget.initial;
  double get position => _pos;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final w = box.maxWidth;
      void update(double dx) => setState(() => _pos = (dx / w).clamp(0.0, 1.0));
      return GestureDetector(
        key: const ValueKey('sample_compare_slider'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => update(d.localPosition.dx),
        onTapDown: (d) => update(d.localPosition.dx),
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.before,
            ClipRect(clipper: _LeftClipper(_pos), child: widget.after),
            Positioned(
              left: (w * _pos - 1).clamp(0.0, w - 2),
              top: 0,
              bottom: 0,
              child: Container(width: 2, color: Colors.white),
            ),
            Positioned(
              left: (w * _pos - 16).clamp(0.0, w - 32),
              top: box.maxHeight / 2 - 16,
              child: Container(
                width: 32,
                height: 32,
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                child: const Icon(Icons.compare_arrows, size: 20, color: Colors.black),
              ),
            ),
            const Positioned(left: 10, bottom: 10, child: _Tag('After')),
            const Positioned(right: 10, bottom: 10, child: _Tag('Before')),
          ],
        ),
      );
    },
  );
}
