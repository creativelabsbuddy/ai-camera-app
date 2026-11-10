import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// Basic free editor: rotate (90° steps), crop, brightness, contrast,
/// saturation, sharpness. All on-device, no credits.
@immutable
class EditParams {
  const EditParams({
    this.quarterTurns = 0,
    this.crop = const Rect.fromLTWH(0, 0, 1, 1),
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.sharpness = 0,
  });

  /// Clockwise 90° turns (0..3).
  final int quarterTurns;

  /// Normalised crop in the ROTATED image (0..1).
  final Rect crop;

  /// −1..1 each; sharpness 0..1.
  final double brightness;
  final double contrast;
  final double saturation;
  final double sharpness;

  bool get isIdentity =>
      quarterTurns % 4 == 0 &&
      crop == const Rect.fromLTWH(0, 0, 1, 1) &&
      brightness == 0 &&
      contrast == 0 &&
      saturation == 0 &&
      sharpness == 0;

  bool get hasColor => brightness != 0 || contrast != 0 || saturation != 0;

  EditParams copyWith({
    int? quarterTurns,
    Rect? crop,
    double? brightness,
    double? contrast,
    double? saturation,
    double? sharpness,
  }) => EditParams(
    quarterTurns: quarterTurns ?? this.quarterTurns,
    crop: crop ?? this.crop,
    brightness: brightness ?? this.brightness,
    contrast: contrast ?? this.contrast,
    saturation: saturation ?? this.saturation,
    sharpness: sharpness ?? this.sharpness,
  );

  /// Rotating the image rotates the existing crop with it.
  EditParams rotatedClockwise() {
    final c = crop;
    // (x, y) → (1 − y − h, x) for a clockwise quarter turn.
    final r = Rect.fromLTWH(1 - c.top - c.height, c.left, c.height, c.width);
    return copyWith(quarterTurns: (quarterTurns + 1) % 4, crop: r);
  }
}

/// Normalised crop clamped to the image with a minimum size.
Rect clampCrop(Rect r, {double minSize = 0.05}) {
  var l = r.left.clamp(0.0, 1.0 - minSize);
  var t = r.top.clamp(0.0, 1.0 - minSize);
  var w = r.width.clamp(minSize, 1.0 - l);
  var h = r.height.clamp(minSize, 1.0 - t);
  return Rect.fromLTWH(l, t, w, h);
}

/// 4×5 colour matrix (Flutter ColorFilter.matrix convention, offsets in
/// 0..255) for brightness / contrast / saturation — used for the live
/// editor preview AND for the saved file, so they match.
List<double> adjustMatrix(EditParams p) {
  final s = 1 + p.saturation; // 0..2
  final c = 1 + p.contrast * 0.6; // 0.4..1.6
  final b = p.brightness * 60;
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  final sr = (1 - s) * lr, sg = (1 - s) * lg, sb = (1 - s) * lb;
  final off = 128 * (1 - c) + b;
  return [
    c * (sr + s), c * sg, c * sb, 0, off, //
    c * sr, c * (sg + s), c * sb, 0, off, //
    c * sr, c * sg, c * (sb + s), 0, off, //
    0, 0, 0, 1, 0,
  ];
}

img.Image _applyMatrix(img.Image im, List<double> m) {
  final bytes = im.getBytes(order: img.ChannelOrder.rgb);
  final out = Uint8List(bytes.length);
  for (var i = 0; i < bytes.length; i += 3) {
    final r = bytes[i].toDouble(), g = bytes[i + 1].toDouble();
    final b = bytes[i + 2].toDouble();
    out[i] = (m[0] * r + m[1] * g + m[2] * b + m[4]).round().clamp(0, 255);
    out[i + 1] = (m[5] * r + m[6] * g + m[7] * b + m[9]).round().clamp(0, 255);
    out[i + 2] = (m[10] * r + m[11] * g + m[12] * b + m[14]).round().clamp(
      0,
      255,
    );
  }
  return img.Image.fromBytes(
    width: im.width,
    height: im.height,
    bytes: out.buffer,
    numChannels: 3,
  );
}

/// Unsharp mask (amount 0..1.5, radius ~0.1 % of the long side).
img.Image _sharpen(img.Image im, double amount) {
  final r = math.max(1, (math.max(im.width, im.height) / 1000).round());
  final blur = img.gaussianBlur(im.clone(), radius: r);
  final a = im.getBytes(order: img.ChannelOrder.rgb);
  final b = blur.getBytes(order: img.ChannelOrder.rgb);
  final out = Uint8List(a.length);
  for (var i = 0; i < a.length; i++) {
    out[i] = (a[i] + amount * (a[i] - b[i])).round().clamp(0, 255);
  }
  return img.Image.fromBytes(
    width: im.width,
    height: im.height,
    bytes: out.buffer,
    numChannels: 3,
  );
}

/// Pure edit pipeline: rotate → crop → colour → sharpen.
img.Image applyEdits(img.Image src, EditParams p) {
  var im = src.numChannels == 3 ? src : src.convert(numChannels: 3);
  final turns = p.quarterTurns % 4;
  if (turns != 0) im = img.copyRotate(im, angle: 90 * turns);
  final c = clampCrop(p.crop, minSize: 0.01);
  if (c != const Rect.fromLTWH(0, 0, 1, 1)) {
    final x = (c.left * im.width).round();
    final y = (c.top * im.height).round();
    final w = math.max(1, math.min(im.width - x, (c.width * im.width).round()));
    final h = math.max(
      1,
      math.min(im.height - y, (c.height * im.height).round()),
    );
    im = img.copyCrop(im, x: x, y: y, width: w, height: h);
  }
  if (p.hasColor) im = _applyMatrix(im, adjustMatrix(p));
  if (p.sharpness > 0) im = _sharpen(im, p.sharpness * 1.5);
  return im;
}

class _EditArgs {
  const _EditArgs(this.path, this.params, this.outDir);
  final String path;
  final EditParams params;
  final String outDir;
}

/// Applies [params] to the photo at [path] in a background isolate.
Future<File> applyEditsToFile(
  File file,
  EditParams params,
  String outDir,
) async {
  final out = await compute(_editSync, _EditArgs(file.path, params, outDir));
  return File(out);
}

String _editSync(_EditArgs a) {
  final raw = img.decodeImage(File(a.path).readAsBytesSync());
  if (raw == null) throw StateError('Could not read the photo');
  final out = applyEdits(img.bakeOrientation(raw), a.params);
  final dest = p.join(
    a.outDir,
    'edit_${DateTime.now().millisecondsSinceEpoch}.jpg',
  );
  File(dest).writeAsBytesSync(img.encodeJpg(out, quality: 95));
  return dest;
}
