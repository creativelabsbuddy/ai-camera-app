import 'dart:io';
import 'dart:isolate';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// Normal (on-device, non-AI) filters — free for everyone, no credits.
enum LocalFilter {
  original('Original'),
  auto('Auto'),
  vivid('Vivid'),
  warm('Warm'),
  cool('Cool'),
  mono('B&W'),
  fade('Fade');

  const LocalFilter(this.label);
  final String label;
}

/// Applies [filter] to [source] in a background isolate. EXIF orientation is
/// baked first so the output is never rotated / stretched.
Future<File> applyLocalFilter(
  File source,
  LocalFilter filter, {
  required String outDir,
}) async {
  if (filter == LocalFilter.original) return source;
  final path = await Isolate.run(() => _applySync(source.path, filter, outDir));
  return File(path);
}

String _applySync(String path, LocalFilter filter, String outDir) {
  var image = img.decodeImage(File(path).readAsBytesSync());
  if (image == null) throw StateError('Could not decode image');
  image = img.bakeOrientation(image);
  if (image.width > 2400 || image.height > 2400) {
    image = img.copyResize(
      image,
      width: image.width >= image.height ? 2400 : null,
      height: image.height > image.width ? 2400 : null,
      interpolation: img.Interpolation.average,
    );
  }
  switch (filter) {
    case LocalFilter.original:
      break;
    case LocalFilter.auto:
      image = img.adjustColor(
        image,
        contrast: 1.08,
        saturation: 1.05,
        brightness: 1.02,
      );
      image = img.convolution(
        image,
        filter: <num>[0, -0.5, 0, -0.5, 3, -0.5, 0, -0.5, 0],
      );
    case LocalFilter.vivid:
      image = img.adjustColor(image, saturation: 1.3, contrast: 1.1);
    case LocalFilter.warm:
      image = img.colorOffset(image, red: 14, green: 6, blue: -8);
      image = img.adjustColor(image, saturation: 1.05);
    case LocalFilter.cool:
      image = img.colorOffset(image, red: -8, green: 2, blue: 14);
    case LocalFilter.mono:
      image = img.grayscale(image);
      image = img.adjustColor(image, contrast: 1.12);
    case LocalFilter.fade:
      image = img.adjustColor(
        image,
        contrast: 0.85,
        saturation: 0.8,
        brightness: 1.05,
      );
  }
  image.exif.imageIfd.orientation = null;
  final out = p.join(
    outDir,
    'ai_camera_${filter.name}_${DateTime.now().microsecondsSinceEpoch}.jpg',
  );
  File(out).writeAsBytesSync(img.encodeJpg(image, quality: 92), flush: true);
  return out;
}

/// Approximate 4×5 colour matrix of [filter] for the LIVE camera preview
/// (the saved photo uses the exact [applyLocalFilter]). Null = no filter.
List<double>? localFilterPreviewMatrix(LocalFilter filter) {
  List<double> sat(double s, {double contrast = 1, double bright = 0}) {
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final c = contrast;
    final off = 128 * (1 - c) + bright;
    double a(double l, bool d) => (d ? (1 - s) * l + s : (1 - s) * l) * c;
    return [
      a(lr, true), a(lg, false), a(lb, false), 0, off, //
      a(lr, false), a(lg, true), a(lb, false), 0, off, //
      a(lr, false), a(lg, false), a(lb, true), 0, off, //
      0, 0, 0, 1, 0,
    ];
  }

  switch (filter) {
    case LocalFilter.original:
      return null;
    case LocalFilter.auto:
      return sat(1.05, contrast: 1.08, bright: 4);
    case LocalFilter.vivid:
      return sat(1.3, contrast: 1.1);
    case LocalFilter.warm:
      final m = sat(1.05);
      m[4] += 14;
      m[9] += 6;
      m[14] -= 8;
      return m;
    case LocalFilter.cool:
      final m = sat(1.0);
      m[4] -= 8;
      m[9] += 2;
      m[14] += 14;
      return m;
    case LocalFilter.mono:
      return sat(0, contrast: 1.12);
    case LocalFilter.fade:
      return sat(0.8, contrast: 0.85, bright: 12);
  }
}
