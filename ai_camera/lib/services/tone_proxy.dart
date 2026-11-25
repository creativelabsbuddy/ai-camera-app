import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'tone.dart';

/// v11.69 small RGBA copy of a photo for the live tone preview (decoded
/// natively at ≤[kToneProxyLong] px — fast even on a cheap tablet). The full
/// resolution file is rendered only when needed (Save / Filters / Edit …).
const int kToneProxyLong = 1280;

class ToneProxy {
  ToneProxy._(this.rgba, this.width, this.height, this.stats);

  final Uint8List rgba;
  final int width;
  final int height;
  final ToneStats stats;

  /// Decodes [file] at a reduced size. Null when the image can't be read.
  static Future<ToneProxy?> load(
    File file, {
    int maxLong = kToneProxyLong,
  }) async {
    try {
      final bytes = await file.readAsBytes();
      final buf = await ui.ImmutableBuffer.fromUint8List(bytes);
      final desc = await ui.ImageDescriptor.encoded(buf);
      final w = desc.width, h = desc.height;
      if (w <= 0 || h <= 0) return null;
      final s = (w >= h ? w : h) > maxLong ? maxLong / (w >= h ? w : h) : 1.0;
      final codec = await desc.instantiateCodec(
        targetWidth: (w * s).round(),
        targetHeight: (h * s).round(),
      );
      final frame = await codec.getNextFrame();
      final im = frame.image;
      final data = await im.toByteData(format: ui.ImageByteFormat.rawRgba);
      final iw = im.width, ih = im.height;
      im.dispose();
      codec.dispose();
      desc.dispose();
      buf.dispose();
      if (data == null) return null;
      final rgba = data.buffer.asUint8List();
      final stats = await compute(_stats, (rgba, iw, ih));
      return ToneProxy._(rgba, iw, ih, stats);
    } catch (e) {
      debugPrint('Tone proxy failed: $e');
      return null;
    }
  }

  /// Toned preview image (caller disposes).
  Future<ui.Image> render(ToneParams t, {bool mono = false}) async {
    final out = await compute(_tone, (rgba, t.key, mono));
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      out,
      width,
      height,
      ui.PixelFormat.rgba8888,
      c.complete,
    );
    return c.future;
  }
}

ToneStats _stats((Uint8List, int, int) a) => toneStatsOf(a.$1, a.$2, a.$3);

Uint8List _tone((Uint8List, String, bool) a) {
  final v = a.$2.split(',').map(double.parse).toList();
  return toneRgba(
    a.$1,
    ToneParams(
      exposure: v[0],
      contrast: v[1],
      highlights: v[2],
      shadows: v[3],
      warmth: v[4],
      saturation: v[5],
    ),
    mono: a.$3,
  );
}
