import 'dart:io';
import 'dart:typed_data';

import 'package:ai_camera/services/zoom_assist.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _scene(int w, int h, int rest, {int lamp = 255, int r = 2}) {
  final g = Uint8List(w * h)..fillRange(0, w * h, rest);
  for (var y = h ~/ 2 - r; y < h ~/ 2 + r; y++) {
    for (var x = w ~/ 2 - r; x < w ~/ 2 + r; x++) {
      g[y * w + x] = lamp;
    }
  }
  return g;
}

void main() {
  final home = File('lib/screens/home_camera_screen.dart').readAsStringSync();

  test('A: a lamp in a normally lit room does not trigger the dark latch', () {
    expect(findBrightSpot(_scene(64, 48, 70), 64, 48), isNull);
    expect(findBrightSpot(_scene(64, 48, 50), 64, 48), isNull);
  });

  test('A: moon / lamp on a dark background still latches', () {
    expect(findBrightSpot(_scene(64, 48, 10), 64, 48), isNotNull);
  });

  test('A: auto exposure restored on Zoom mode and mode switch', () {
    expect(home, contains('Future<void> _restoreAutoExposure()'));
    expect(home, contains('await _restoreAutoExposure();'));
    expect(home, contains('unawaited(_restoreAutoExposure()); // v11.46'));
  });

  test('B: Normal camera zoom reaches the device max', () {
    expect(
      home,
      contains('_mode == CaptureMode.normal\n      ? _range.displayMax'),
    );
    expect(kNormalZoomMax, 10); // Pro without Zoom mode keeps 10x
  });
}
