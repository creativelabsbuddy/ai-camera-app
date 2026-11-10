import 'dart:io';
import 'dart:typed_data';

import 'package:ai_camera/services/macro.dart';
import 'package:ai_camera/services/zoom_assist.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('generic flagship detection', () {
    test('telephoto → flagship (S24 Ultra style)', () {
      final c = classifyCamera(
        backFactors: [0.6, 1, 3, 5],
        sensorCropFactor: 2,
        previewLongSide: 1280,
        hardwareMax: 100,
      );
      expect(c.lowEnd, isFalse);
      expect(c.reason, contains('telephoto'));
    });
    test('high-res main, no tele, big preview → flagship', () {
      final c = classifyCamera(
        backFactors: [0.6, 1],
        sensorCropFactor: 2,
        previewLongSide: 1920,
        hardwareMax: 8,
      );
      expect(c.lowEnd, isFalse);
    });
    test('macro/depth extras without tele → cheap', () {
      final c = classifyCamera(
        backFactors: [1, 1, 1],
        sensorCropFactor: 1,
        previewLongSide: 1280,
        hardwareMax: 10,
      );
      expect(c.lowEnd, isTrue);
      expect(c.reason, startsWith('cheap'));
    });
  });

  group('relative bright spot', () {
    Uint8List grey(int spot, int bg) {
      final g = Uint8List(48 * 36)..fillRange(0, 48 * 36, bg);
      for (var y = 15; y < 20; y++) {
        for (var x = 20; x < 26; x++) {
          g[y * 48 + x] = spot;
        }
      }
      return g;
    }

    test('well exposed moon (210) on black still found', () {
      final s = findBrightSpot(grey(210, 5), 48, 36);
      expect(s, isNotNull);
      expect(s!.top, 210);
    });
    test('low contrast → none', () {
      expect(findBrightSpot(grey(100, 60), 48, 36), isNull);
    });
  });

  group('latch exposure', () {
    test('clipping → faster, dark → slower, target holds', () {
      expect(nextLatchExposure(kLatchStartNs, 255), lessThan(kLatchStartNs));
      expect(nextLatchExposure(kLatchStartNs, 100), greaterThan(kLatchStartNs));
      expect(nextLatchExposure(kLatchStartNs, 215), kLatchStartNs);
      expect(nextLatchExposure(kLatchMinNs, 255), kLatchMinNs);
      expect(nextLatchExposure(kLatchMaxNs, 10), kLatchMaxNs);
      expect(kLatchStartNs, 4000000); // 1/250 s
    });
    test('region top + frame ↔ crop round trip', () {
      final g = Uint8List(48 * 36)..[18 * 48 + 24] = 230;
      expect(regionTop(g, 48, 36, const Offset(0.5, 0.5), r: 0.02), 230);
      final f = cropToFrame(const Offset(0.8, 0.3), 4);
      final c = frameToCrop(f, 4);
      expect(c.dx, closeTo(0.8, 1e-9));
      expect(c.dy, closeTo(0.3, 1e-9));
    });
  });

  group('subject match', () {
    List<double> pattern(int w, int h, int sx) => [
      for (var y = 0; y < h; y++)
        for (var x = 0; x < w; x++)
          (((x + sx) ~/ 4 + y ~/ 4) % 2 == 0 ? 40.0 : 160.0) +
              ((x + sx) * 3 % 7),
    ];
    test('shifted copy still matches; clipped pixels ignored', () {
      final wide = pattern(62, 47, 0);
      final close = [
        for (var y = 0; y < 36; y++)
          for (var x = 0; x < 48; x++) wide[(y + 3) * 62 + x + 9],
      ];
      expect(bestShiftMatch(wide, 62, 47, close, 48, 36), greaterThan(0.95));
      final clipped = [for (final v in close) v > 150 ? 255.0 : v];
      expect(maskedNcc(edgeMap(clipped, 48, 36), edgeMap(clipped, 48, 36)), 1);
    });
    test('two misses needed', () => expect(kSubjectMissesNeeded, 2));
  });

  group('wiring', () {
    final hcs = File('lib/screens/home_camera_screen.dart').readAsStringSync();
    test('zoom mode gates heavy logic + 10x limit', () {
      expect(kNormalZoomMax, 10);
      expect(kZoomModeLabel, 'Zoom mode');
      expect(kZoomModeHint, 'Tap Zoom mode for more');
      expect(hcs, contains("route.aiMode == 'photo' && _zoomModeActive"));
      expect(hcs, contains('_zoomMode &&\n      _macroLowEnd'));
      expect(hcs, contains('_zoomModeActive &&\n          shouldMergeZoom('));
      expect(hcs, contains('if (!_zoomModeActive || _processingCapture'));
      expect(hcs, contains('await _setMode(CaptureMode.pro)'));
    });
    test('latch: tap re-meters, no AF; release clears options', () {
      expect(hcs, contains('? _latchTap(d.localPosition, geometry)'));
      expect(hcs, contains('!_processingCapture && !_brightApplied'));
      final j = File(
        'packages/camera_android_camerax/android/src/main/java/io/flutter/plugins/camerax/CameraXExtras.java',
      ).readAsStringSync();
      expect(j, contains('clearCaptureRequestOptions()'));
    });
    test('overlay on all key builds', () {
      expect(hcs, contains('AiConfig.hasEmbeddedApiKey && _cameraReady'));
      expect(hcs, contains('TELEPHOTO in use'));
      expect(hcs, contains('MAIN camera cropped'));
    });
    test('version', () {
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('version: 1.11.'),
      );
    });
  });
}
