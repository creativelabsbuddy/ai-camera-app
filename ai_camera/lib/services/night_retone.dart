import 'dart:io';
import 'dart:isolate';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'night_plan.dart';

/// "Use Normal Night" after a too-dark Pro Night shot: re-tones the merged
/// (natural) night photo with the bright NORMAL Night curve, on device,
/// free (no AI). Luma is lifted with [nightCurve]; colour follows the luma
/// ratio (chroma gain capped so noise isn't amplified).
Future<File> retoneNightBright(File src, {required String outDir}) async {
  final out = await Isolate.run(() => _retone(src.path, outDir));
  return File(out);
}

String _retone(String path, String outDir) {
  var im = img.decodeImage(File(path).readAsBytesSync());
  if (im == null) throw StateError('Could not decode image');
  im = img.bakeOrientation(im);
  final samples = <double>[];
  final step = (im.width * im.height / 40000).ceil().clamp(1, 1 << 20);
  var i = 0;
  for (final px in im) {
    if (i++ % step == 0) {
      samples.add((0.299 * px.r + 0.587 * px.g + 0.114 * px.b) / 255);
    }
  }
  final a = solveNightA(samples, NightTone.bright);
  for (final px in im) {
    final y = (0.299 * px.r + 0.587 * px.g + 0.114 * px.b) / 255;
    final t = nightCurve(y, a);
    final gain = y > 1e-4 ? t / y : 1.0;
    final cg = gain.clamp(1.0, 3.0);
    double ch(num c) {
      final v = c / 255;
      return ((t + (v - y) * cg) * 255).clamp(0, 255).toDouble();
    }

    px
      ..r = ch(px.r)
      ..g = ch(px.g)
      ..b = ch(px.b);
  }
  final out = p.join(
    outDir,
    'night_bright_${DateTime.now().microsecondsSinceEpoch}.jpg',
  );
  File(out).writeAsBytesSync(img.encodeJpg(im, quality: 93), flush: true);
  return out;
}
