import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:ai_camera/services/camera_extras.dart';
import 'package:ai_camera/services/focus_mapping.dart';
import 'package:ai_camera/services/frame_stats.dart';
import 'package:ai_camera/services/macro_box.dart';
import 'package:ai_camera/services/tap_focus.dart';
import 'package:ai_camera/services/zoom_assist.dart';
import 'package:flutter_test/flutter_test.dart';

import 'focus_test.dart' show FakeOps;

const w = kThumbW, h = kThumbH;

/// Grey image with a bright square.
Uint8List grey({
  int bg = 20,
  int spot = 255,
  int x0 = 30,
  int y0 = 10,
  int s = 6,
}) {
  final t = Uint8List(w * h)..fillRange(0, w * h, bg);
  for (var y = y0; y < y0 + s; y++) {
    for (var x = x0; x < x0 + s; x++) {
      t[y * w + x] = spot;
    }
  }
  return t;
}

/// Same as RGBA (4 bytes/px, alpha 255) — the real thumb format.
Uint8List rgba(Uint8List g) {
  final o = Uint8List(g.length * 4);
  for (var i = 0; i < g.length; i++) {
    o[i * 4] = o[i * 4 + 1] = o[i * 4 + 2] = g[i];
    o[i * 4 + 3] = 255;
  }
  return o;
}

void main() {
  group('colour (RGBA) input is read correctly', () {
    test('bright spot found in RGBA thumb, same centroid as grey', () {
      final g = findBrightSpot(grey(), w, h)!;
      final c = findBrightSpot(rgba(grey()), w, h)!;
      expect(c.centroid.dx, closeTo(g.centroid.dx, 1e-9));
      expect(c.centroid.dy, closeTo(33 / 48 * 0 + 13 / 64, 0.01));
    });
    test('alpha bytes never count as clipping (dark RGBA → none)', () {
      expect(findBrightSpot(rgba(grey(spot: 20)), w, h), isNull);
    });
    test('lumaOf + boxFill on RGBA', () {
      expect(lumaOf(rgba(grey()), w, h), grey());
      final full = Uint8List(w * h)..fillRange(0, w * h, 120);
      for (var y = h ~/ 4; y < h * 3 ~/ 4; y++) {
        for (var x = w ~/ 4; x < w * 3 ~/ 4; x++) {
          full[y * w + x] = 220;
        }
      }
      expect(boxFill(rgba(full), w, h), greaterThan(0.9));
    });
  });

  group('brightest ~0.5 % rule', () {
    test('a grey-white blob below 235 still counts (tone mapped)', () {
      expect(findBrightSpot(grey(spot: 215, bg: 35), w, h), isNotNull);
    });
    test(
      'small bulb (4 px) found; v11.46: dark background only (lit room grey 60 = no latch)',
      () {
        expect(findBrightSpot(grey(s: 2, bg: 20), w, h), isNotNull);
        expect(findBrightSpot(grey(s: 2, bg: 60), w, h), isNull);
        expect(findBrightSpot(grey(bg: 90), w, h), isNull);
      },
    );
    test('debug text', () {
      findBrightSpot(grey(), w, h);
      expect(brightDebug, startsWith('bright found area'));
    });
  });

  group('visible crop', () {
    test('frame stats sample the centre 1/zoom', () {
      // 200×200 Y plane: centre 50×50 bright, rest dark; rotation 0.
      const fw = 200, fh = 200;
      final nv21 = Uint8List(fw * fh * 3 ~/ 2)..fillRange(0, fw * fh, 10);
      for (var y = 75; y < 125; y++) {
        for (var x = 75; x < 125; x++) {
          nv21[y * fw + x] = 250;
        }
      }
      final full = frameStatsFromNv21(nv21, fw, fh, rotation: 0);
      final crop = frameStatsFromNv21(nv21, fw, fh, rotation: 0, cropZoom: 4);
      int bright(Uint8List v) => v.where((e) => e > 200).length;
      expect(bright(full.cropLuma!), lessThan(bright(crop.cropLuma!)));
      expect(bright(crop.cropLuma!), w * h); // all bright at 4x
    });
    test('crop point → camera frame; metering size shrinks with zoom', () {
      final p = cropToFrame(const Offset(1, 1), 4);
      expect(p.dx, closeTo(0.625, 1e-9));
      expect(meteringSizeFor(1), 0.15);
      expect(meteringSizeFor(2), closeTo(0.075, 1e-9));
      expect(meteringSizeFor(100), 0.05); // v11.36 min 0.05
    });
  });

  group('tap overrides the bright lock', () {
    const geo = PreviewGeometry(
      frameSize: Size(360, 480),
      previewSize: Size(480, 360),
    );
    test('bright lock goes through the controller; a tap cancels it', () async {
      final ops = FakeOps();
      final f = TapFocusController(clock: () => DateTime(2026));
      await f.attach(ops);
      var taps = 0;
      f.onUserTap = () => taps++;
      expect(await f.brightLock(const Offset(0.5, 0.2)), isTrue);
      expect(f.brightOn, isTrue);
      expect(ops.calls, contains('AFmode:locked'));
      await f.focusAt(const Offset(100, 100), geo, zoom: 40);
      expect(f.brightOn, isFalse);
      expect(taps, 1);
      expect(f.tapPausesBright, isTrue);
      // While the tap is active the bright lock is refused.
      expect(await f.brightLock(const Offset(0.5, 0.2)), isFalse);
    });
    test('tap survives a small zoom change, not a big one', () async {
      final f = TapFocusController(clock: () => DateTime(2026));
      await f.attach(FakeOps());
      await f.focusAt(const Offset(100, 100), geo, zoom: 40);
      f.onSceneChange(zoom: 44);
      expect(f.isActive, isTrue);
      f.onSceneChange(zoom: 80);
      await Future<void>.delayed(Duration.zero);
      expect(f.isActive, isFalse);
      expect(tapSurvivesZoom(40, 49), isTrue);
      expect(tapSurvivesZoom(40, 51), isFalse);
    });
  });

  group('telephoto check', () {
    test('slots and reachability', () {
      expect(lensCheckSlot(1.02), 1);
      expect(lensCheckSlot(3.1), 3);
      expect(lensCheckSlot(9.5), 10);
      expect(lensCheckSlot(6), isNull);
      final l = LensCheck();
      expect(l.tenXReachable, isNull);
      l.record(1, '2');
      l.record(3, '3');
      l.record(10, '3');
      expect(l.teleAt(3), isTrue);
      expect(l.tenXReachable, isFalse); // 10x = same lens as 3x → crop
      l.record(10, '4');
      expect(l.tenXReachable, isTrue);
      expect(LensCheck.decode(l.encode()).seen, l.seen);
      expect(l.text, 'lens 1x 2 · 3x tele 3 · 10x tele 4');
    });
    test('lens info text', () {
      expect(lensInfoText(const {}), 'lens info —');
      final t = lensInfoText(const {
        'cameraId': '0',
        'activePhysicalId': '4',
        'zoomRatio': 10.0,
        'focusDistance': 0.0,
        'exposureNs': 2000000,
        'iso': 100,
        'aeComp': -12,
        'aeCompMin': -12,
        'aeCompMax': 12,
        'manualSensor': true,
      });
      expect(t, contains('active 4'));
      expect(t, contains('1/500s ISO 100'));
      expect(t, contains('[-12..12]'));
    });
  });

  test('fork + wiring', () {
    final fork = File(
      'packages/camera_android_camerax/lib/src/android_camera_camerax.dart',
    ).readAsStringSync();
    expect(fork, contains('static double? meteringPointSize;'));
    final j = File(
      'packages/camera_android_camerax/android/src/main/java/io/flutter/plugins/camerax/CameraXExtras.java',
    ).readAsStringSync();
    expect(j, contains('LOGICAL_MULTI_CAMERA_ACTIVE_PHYSICAL_ID'));
    expect(j, contains('LENS_FOCUS_DISTANCE, 0f'));
    final p = File('pubspec.yaml').readAsStringSync();
    expect(p, contains('path: packages/camera_android_camerax'));
    final hcs = File('lib/screens/home_camera_screen.dart').readAsStringSync();
    expect(hcs, contains('findBrightSpot(g, kThumbW, kThumbH)')); // v11.36
    expect(hcs, isNot(contains('_onUserTap'))); // v11.36: tap keeps latch
    expect(hcs, contains('CameraExtras.setMeteringSize('));
  });
}
