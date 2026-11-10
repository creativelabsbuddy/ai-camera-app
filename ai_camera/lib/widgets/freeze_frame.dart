import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/frame_stats.dart';

/// Last live frame (tiny analysis thumbnail, blurred) shown while the
/// camera is handed over (native Night / Portrait, document scanner,
/// re-open) instead of a black "Opening camera…" screen.
class FreezeFrame extends StatefulWidget {
  const FreezeFrame({super.key, required this.stats, this.mirror = false});

  final FrameStats? stats;
  final bool mirror;

  @override
  State<FreezeFrame> createState() => _FreezeFrameState();
}

class _FreezeFrameState extends State<FreezeFrame> {
  ui.Image? _image;
  FrameStats? _for;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(FreezeFrame old) {
    super.didUpdateWidget(old);
    if (!identical(old.stats, widget.stats)) _decode();
  }

  void _decode() {
    final s = widget.stats;
    final px = s?.thumb;
    if (s == null || px == null || identical(s, _for)) return;
    _for = s;
    ui.decodeImageFromPixels(
      px,
      s.thumbWidth,
      s.thumbHeight,
      ui.PixelFormat.rgba8888,
      (img) {
        if (!mounted || !identical(_for, s)) {
          img.dispose();
          return;
        }
        final old = _image;
        setState(() => _image = img);
        old?.dispose();
      },
    );
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    if (img == null) return const ColoredBox(color: Colors.black);
    Widget child = RawImage(
      image: img,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
    );
    if (widget.mirror) child = Transform.flip(flipX: true, child: child);
    return ClipRect(
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: ColorFiltered(
          colorFilter: const ColorFilter.mode(
            Color(0x33000000),
            BlendMode.darken,
          ),
          child: child,
        ),
      ),
    );
  }
}
