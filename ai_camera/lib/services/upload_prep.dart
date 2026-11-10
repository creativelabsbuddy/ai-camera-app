import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Upload sizes (long side, px). Flare returns ~1.5K images whatever the
/// input size, so bigger uploads only cost time, data and input tokens.
const int kLookInputLongSide = 1536; // style / custom change
const int kEnhanceInputLongSide = 2048; // enhance crop
const int kContextLongSide = 768; // enhance scene context

/// v11.5 Macro boxed full frame (`*_boxed.jpg`): bigger so the box reads.
const int kMacroContextLongSide = 1024;
int contextLongSideFor(String path) =>
    path.endsWith('_boxed.jpg') ? kMacroContextLongSide : kContextLongSide;
const int kReferenceLongSide = 1024; // style reference images
const int kUploadJpegQuality = 90;

/// Upload-ready image: upright pixels, ≤ maxLong long side, JPEG.
class PreparedImage {
  const PreparedImage(this.bytes, this.mime, this.width, this.height);
  final Uint8List bytes;
  final String mime;
  final int width;
  final int height;

  String get dataUrl => 'data:$mime;base64,${base64Encode(bytes)}';
}

/// Switches for tests.
class UploadPrep {
  /// Use the engine's native (subsampling) JPEG decoder first. ~20× faster
  /// than pure-Dart decoding for 12–50 MP captures and far less memory.
  static bool nativeDecode = true;

  /// Last path used (for tests / diagnostics): 'native', 'dart', 'passthrough'.
  static String lastPath = '';
}

/// Bakes EXIF orientation and limits the long side to [maxLong] (JPEG q90).
/// Small upright JPEGs are passed through untouched.
Future<PreparedImage> prepareUpload(
  Uint8List bytes, {
  int maxLong = kEnhanceInputLongSide,
  int quality = kUploadJpegQuality,
}) async {
  if (UploadPrep.nativeDecode) {
    try {
      final r = await _prepareNative(
        bytes,
        maxLong,
        quality,
      ).timeout(const Duration(seconds: 20));
      if (r != null) return r;
    } catch (e) {
      debugPrint('Native upload prep failed, using Dart decoder: $e');
    }
  }
  UploadPrep.lastPath = 'dart';
  return compute(_prepareSync, _PrepArgs(bytes, maxLong, quality));
}

bool _isJpeg(Uint8List b) => b.length > 2 && b[0] == 0xFF && b[1] == 0xD8;

int _exifOrientation(Uint8List bytes) {
  if (!_isJpeg(bytes)) return 1;
  try {
    final exif = img.decodeJpgExif(bytes);
    if (exif == null || !exif.imageIfd.hasOrientation) return 1;
    return exif.imageIfd.orientation ?? 1;
  } catch (_) {
    return 1;
  }
}

/// Output size for an upright [w]×[h] image limited to [maxLong].
({int width, int height}) fitLongSide(int w, int h, int maxLong) {
  final long = math.max(w, h);
  if (long <= maxLong) return (width: w, height: h);
  final s = maxLong / long;
  return (
    width: math.max(1, (w * s).round()),
    height: math.max(1, (h * s).round()),
  );
}

Future<PreparedImage?> _prepareNative(
  Uint8List bytes,
  int maxLong,
  int quality,
) async {
  final orientation = _exifOrientation(bytes);
  if (orientation <= 1 && _isJpeg(bytes)) {
    // Cheap header read: small upright JPEGs go out untouched.
    final buf = await ui.ImmutableBuffer.fromUint8List(bytes);
    final desc = await ui.ImageDescriptor.encoded(buf);
    final w = desc.width;
    final h = desc.height;
    desc.dispose();
    buf.dispose();
    if (math.max(w, h) <= maxLong) {
      UploadPrep.lastPath = 'passthrough';
      return PreparedImage(bytes, 'image/jpeg', w, h);
    }
  }
  // The engine applies EXIF orientation only for some files (it depends on
  // how the tag was written), and target sizes are in raw sensor space. To
  // be deterministic, neutralise the tag, decode raw pixels straight to the
  // target size (JPEG DCT scaling — a 50 MP file never sits fully in memory)
  // and bake the orientation ourselves on the small image.
  var raw = bytes;
  if (orientation > 1) {
    final exif = img.decodeJpgExif(bytes);
    if (exif == null) return null;
    exif.imageIfd.orientation = 1;
    raw = img.injectJpgExif(bytes, exif) ?? (throw StateError('exif patch'));
  }
  final buf = await ui.ImmutableBuffer.fromUint8List(raw);
  final desc = await ui.ImageDescriptor.encoded(buf);
  final target = fitLongSide(desc.width, desc.height, maxLong);
  final codec = await desc.instantiateCodec(
    targetWidth: target.width,
    targetHeight: target.height,
  );
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final ow = image.width;
  final oh = image.height;
  image.dispose();
  codec.dispose();
  desc.dispose();
  buf.dispose();
  if (rgba == null) return null;
  final out = await compute(
    _encodeRgbaOriented,
    _RgbaArgs(rgba.buffer.asUint8List(), ow, oh, quality, orientation),
  );
  UploadPrep.lastPath = 'native';
  return out;
}

PreparedImage _encodeRgbaOriented(_RgbaArgs a) {
  var im = img.Image.fromBytes(
    width: a.width,
    height: a.height,
    bytes: a.rgba.buffer,
    bytesOffset: a.rgba.offsetInBytes,
    numChannels: 4,
  );
  if (a.orientation > 1) {
    im.exif.imageIfd.orientation = a.orientation;
    im = img.bakeOrientation(im);
  }
  final jpg = Uint8List.fromList(img.encodeJpg(im, quality: a.quality));
  return PreparedImage(jpg, 'image/jpeg', im.width, im.height);
}

class _RgbaArgs {
  const _RgbaArgs(
    this.rgba,
    this.width,
    this.height,
    this.quality, [
    this.orientation = 1,
  ]);
  final Uint8List rgba;
  final int width;
  final int height;
  final int quality;
  final int orientation;
}

Uint8List _encodeRgba(_RgbaArgs a) {
  final im = img.Image.fromBytes(
    width: a.width,
    height: a.height,
    bytes: a.rgba.buffer,
    bytesOffset: a.rgba.offsetInBytes,
    numChannels: 4,
  );
  return Uint8List.fromList(img.encodeJpg(im, quality: a.quality));
}

class _PrepArgs {
  const _PrepArgs(this.bytes, this.maxLong, this.quality);
  final Uint8List bytes;
  final int maxLong;
  final int quality;
}

PreparedImage _prepareSync(_PrepArgs a) {
  final raw = img.decodeImage(a.bytes);
  if (raw == null) {
    throw const FormatException('Could not decode image for upload');
  }
  final hasOrientation =
      raw.exif.imageIfd.hasOrientation &&
      (raw.exif.imageIfd.orientation ?? 1) != 1;
  var decoded = img.bakeOrientation(raw);
  final needsResize = decoded.width > a.maxLong || decoded.height > a.maxLong;
  if (needsResize) {
    final t = fitLongSide(decoded.width, decoded.height, a.maxLong);
    decoded = img.copyResize(
      decoded,
      width: t.width,
      height: t.height,
      interpolation: img.Interpolation.average,
    );
  }
  if (!needsResize && !hasOrientation && _isJpeg(a.bytes)) {
    return PreparedImage(a.bytes, 'image/jpeg', decoded.width, decoded.height);
  }
  return PreparedImage(
    Uint8List.fromList(img.encodeJpg(decoded, quality: a.quality)),
    'image/jpeg',
    decoded.width,
    decoded.height,
  );
}

/// Resamples [bytes] up so its long side is ≥ [minLongSide] (JPEG q92);
/// returns the input unchanged when already big enough. Native decode +
/// upscale first (fast), pure Dart as fallback.
Future<Uint8List> ensureMinLongSide(Uint8List bytes, int minLongSide) async {
  if (UploadPrep.nativeDecode) {
    try {
      final r = await _upscaleNative(
        bytes,
        minLongSide,
      ).timeout(const Duration(seconds: 20));
      if (r != null) return r;
    } catch (e) {
      debugPrint('Native upscale failed, using Dart: $e');
    }
  }
  return compute(_ensureMinSync, _MinArgs(bytes, minLongSide));
}

Future<Uint8List?> _upscaleNative(Uint8List bytes, int minLong) async {
  final buf = await ui.ImmutableBuffer.fromUint8List(bytes);
  final desc = await ui.ImageDescriptor.encoded(buf);
  final w = desc.width;
  final h = desc.height;
  desc.dispose();
  buf.dispose();
  final long = math.max(w, h);
  if (long >= minLong * 0.98) return bytes;
  final s = minLong / long;
  final codec = await ui.instantiateImageCodec(
    bytes,
    targetWidth: (w * s).round(),
    targetHeight: (h * s).round(),
    allowUpscaling: true,
  );
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final ow = image.width;
  final oh = image.height;
  image.dispose();
  codec.dispose();
  if (rgba == null) return null;
  return compute(_encodeRgba, _RgbaArgs(rgba.buffer.asUint8List(), ow, oh, 92));
}

class _MinArgs {
  const _MinArgs(this.bytes, this.minLong);
  final Uint8List bytes;
  final int minLong;
}

Uint8List _ensureMinSync(_MinArgs a) {
  final im = img.decodeImage(a.bytes);
  if (im == null) return a.bytes;
  final long = math.max(im.width, im.height);
  if (long >= a.minLong * 0.98) return a.bytes;
  final scale = a.minLong / long;
  final out = img.copyResize(
    im,
    width: (im.width * scale).round(),
    height: (im.height * scale).round(),
    interpolation: img.Interpolation.cubic,
  );
  return Uint8List.fromList(img.encodeJpg(out, quality: 92));
}
