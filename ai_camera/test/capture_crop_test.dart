import 'dart:io';

import 'package:ai_camera/services/capture_crop.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  group('computeCaptureCrop (pure)', () {
    test('4:3 portrait frame, no zoom = whole image', () {
      expect(
        computeCaptureCrop(iw: 3000, ih: 4000, portraitRatio: 3 / 4),
        const CropRect(0, 0, 3000, 4000),
      );
    });

    test('S24-like 100x: camera 10x still + 10x digital → centre 1/10', () {
      expect(
        computeCaptureCrop(
          iw: 3000,
          ih: 4000,
          portraitRatio: 3 / 4,
          digitalZoom: 10,
        ),
        const CropRect(1350, 1800, 300, 400),
      );
    });

    test('16:9 + 3x digital on a 3000x4000 portrait still', () {
      // 16:9 portrait frame = 2250x4000, then /3 = 750x1333.
      expect(
        computeCaptureCrop(
          iw: 3000,
          ih: 4000,
          portraitRatio: 9 / 16,
          digitalZoom: 3,
        ),
        const CropRect(1125, 1333, 750, 1333),
      );
    });

    test('landscape still keeps landscape crop; 1:1', () {
      expect(
        computeCaptureCrop(iw: 4000, ih: 3000, portraitRatio: 1),
        const CropRect(500, 0, 3000, 3000),
      );
    });

    test('degenerate inputs are safe', () {
      expect(
        computeCaptureCrop(iw: 0, ih: 0, portraitRatio: 3 / 4),
        const CropRect(0, 0, 1, 1),
      );
      final r = computeCaptureCrop(
        iw: 10,
        ih: 10,
        portraitRatio: double.nan,
        digitalZoom: 1000,
      );
      expect(r.width, greaterThanOrEqualTo(1));
      expect(r.height, greaterThanOrEqualTo(1));
    });
  });

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('crop'));
  tearDown(() => dir.deleteSync(recursive: true));

  String writeJpg(int w, int h, {int? orientation}) {
    final im = img.Image(width: w, height: h);
    img.fill(im, color: img.ColorRgb8(200, 50, 50));
    if (orientation != null) im.exif.imageIfd.orientation = orientation;
    final f = File('${dir.path}/shot_${w}x$h.jpg')
      ..writeAsBytesSync(img.encodeJpg(im));
    return f.path;
  }

  test('4:3 fast path returns original', () async {
    final p = writeJpg(400, 300, orientation: 6);
    final out = await cropCaptureToRatio(p, portraitRatio: 3 / 4, label: '4:3');
    expect(out, p);
  });

  test('16:9 bakes EXIF rotate then crops portrait 9:16', () async {
    // Landscape pixels + orientation 6 => upright portrait 300x400.
    final p = writeJpg(400, 300, orientation: 6);
    final out = await cropCaptureToRatio(
      p,
      portraitRatio: 9 / 16,
      label: '16:9',
    );
    expect(out, isNot(p));
    final im = img.decodeJpg(File(out).readAsBytesSync())!;
    expect(im.width, 225);
    expect(im.height, 400);
    expect(im.exif.imageIfd.orientation ?? 1, 1);
  });

  test('1:1 crop', () async {
    final p = writeJpg(300, 400);
    final out = await cropCaptureToRatio(p, portraitRatio: 1, label: '1:1');
    final im = img.decodeJpg(File(out).readAsBytesSync())!;
    expect([im.width, im.height], [300, 300]);
  });

  test('16:9 sensor + 4:3 selected crops to 3:4', () async {
    final p = writeJpg(720, 1280);
    final out = await cropCaptureToRatio(p, portraitRatio: 3 / 4, label: '4:3');
    final im = img.decodeJpg(File(out).readAsBytesSync())!;
    expect([im.width, im.height], [720, 960]);
  });

  test('Digital zoom 2.5x on 4:3 bakes EXIF and centre-crops', () async {
    // Landscape 800x600 + orientation 6 => upright portrait 600x800.
    final p = writeJpg(800, 600, orientation: 6);
    final out = await cropCaptureToRatio(
      p,
      portraitRatio: 3 / 4,
      label: '4:3_z25',
      digitalZoom: 2.5,
    );
    expect(out, isNot(p));
    final im = img.decodeJpg(File(out).readAsBytesSync())!;
    expect([im.width, im.height], [240, 320]);
    expect(im.exif.imageIfd.orientation ?? 1, 1);
  });

  test('digitalZoom 1.0 keeps 4:3 fast path', () async {
    final p = writeJpg(400, 300);
    final out = await cropCaptureToRatio(
      p,
      portraitRatio: 3 / 4,
      label: '4:3',
      digitalZoom: 1.0,
    );
    expect(out, p);
  });

  test('16:9 ratio + 2x digital zoom combine', () async {
    final p = writeJpg(720, 1280);
    final out = await cropCaptureToRatio(
      p,
      portraitRatio: 9 / 16,
      label: '16:9_z20',
      digitalZoom: 2,
    );
    final im = img.decodeJpg(File(out).readAsBytesSync())!;
    expect([im.width, im.height], [360, 640]);
  });

  test('digital zoom writes a small full-frame context image', () async {
    final p = writeJpg(1600, 1200, orientation: 6); // upright 1200x1600
    final r = await processCapture(
      p,
      portraitRatio: 3 / 4,
      label: '4:3_z40',
      digitalZoom: 4,
    );
    final crop = img.decodeJpg(File(r.path).readAsBytesSync())!;
    expect([crop.width, crop.height], [300, 400]);
    expect(r.contextPath, isNotNull);
    final ctx = img.decodeJpg(File(r.contextPath!).readAsBytesSync())!;
    expect([ctx.width, ctx.height], [576, 768]); // uncropped, upright, small
    expect(r.crop, const CropRect(450, 600, 300, 400));
  });

  test('no digital zoom → no context image', () async {
    final p = writeJpg(720, 1280);
    final r = await processCapture(p, portraitRatio: 3 / 4, label: '4:3');
    expect(r.contextPath, isNull);
  });
}
