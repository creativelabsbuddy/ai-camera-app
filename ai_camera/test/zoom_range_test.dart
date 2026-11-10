import 'package:ai_camera/services/zoom_range.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> labels(List<ZoomStop> s) => s.map((e) => e.label).toList();
List<double> values(List<ZoomStop> s) => s.map((e) => e.value).toList();

void main() {
  group('displayMax (100x for everyone on back camera)', () {
    test('S24-like: reported 10 -> display 100, camera max 10', () {
      final r = computeZoomRange(
        controllerMin: 0.6,
        controllerMax: 10,
        nativeReportedMax: 10,
        teleMultiplier: 5,
      );
      expect(r.deviceMax, 10);
      expect(r.displayMax, 100);
      expect(r.hardwareMax, 10);
      expect(r.extended, isTrue);
    });

    test('S24-like measured tele 4.83 snaps to 5x', () {
      expect(teleMultiplierFrom([0.55, 1.0, 2.9, 4.83]), 5);
    });

    test('cheap 8x phone also reaches 100x (digital crop)', () {
      final r = computeZoomRange(controllerMin: 1, controllerMax: 8);
      expect(r.deviceMax, 8);
      expect(r.displayMax, kMaxUserZoom);
      expect(r.extended, isTrue);
    });

    test('front camera (displayTarget null) stays at device max', () {
      final r = computeZoomRange(
        controllerMin: 1,
        controllerMax: 8,
        displayTarget: null,
      );
      expect(r.displayMax, 8);
      expect(r.extended, isFalse);
    });

    test('phone exposing 120x keeps its own max', () {
      expect(computeDisplayMax(deviceMax: 120, target: 100), 120);
    });

    test('deviceMax = max(controller, native)', () {
      expect(computeDeviceMax(controllerMax: 8, nativeReportedMax: 10), 10);
      expect(computeDeviceMax(controllerMax: 10, nativeReportedMax: null), 10);
      expect(computeDeviceMax(controllerMax: 10, nativeReportedMax: 4), 10);
    });
  });

  group('chips', () {
    test('S24-like chips', () {
      final r = computeZoomRange(
        controllerMin: 0.6,
        controllerMax: 10,
        nativeReportedMax: 10,
      );
      expect(labels(buildZoomStops(r)), [
        '0.6',
        '1',
        '2',
        '3',
        '5',
        '10',
        '30',
        '100',
      ]);
    });

    test('8x phone: chip at device max 8, then 10/30/100', () {
      final r = computeZoomRange(controllerMin: 1, controllerMax: 8);
      final s = buildZoomStops(r);
      expect(labels(s), ['1', '2', '3', '5', '8', '10', '30', '100']);
      expect(values(s).last, 100);
    });

    test('front 8x phone chips end at 8', () {
      final r = computeZoomRange(
        controllerMin: 1,
        controllerMax: 8,
        displayTarget: null,
      );
      expect(labels(buildZoomStops(r)), ['1', '2', '3', '5', '8']);
    });

    test('deviceMax 9.8 snaps the 10x chip value', () {
      final r = computeZoomRange(controllerMin: 1, controllerMax: 9.8);
      final s = buildZoomStops(r);
      final ten = s.firstWhere((e) => e.label == '10');
      expect(ten.value, 9.8);
    });

    test('odd optical factor (3.5x) gets its own chip; 4.9 merges into 5', () {
      final r = computeZoomRange(controllerMin: 1, controllerMax: 10);
      final s = buildZoomStops(r, opticalFactors: [1, 3.5, 4.9]);
      expect(labels(s), ['1', '2', '3', '3.5', '5', '10', '30', '100']);
    });
  });

  group('planZoom (no Pro gate)', () {
    final s24 = computeZoomRange(
      controllerMin: 0.6,
      controllerMax: 10,
      nativeReportedMax: 10,
    );

    test('30x: camera 10x (real max) + digital 3x', () {
      final p = planZoom(requested: 30, range: s24);
      expect(p.selected, 30);
      expect(p.cameraZoom, 10);
      expect(p.digitalZoom, closeTo(3, 1e-9));
    });

    test('100x = camera 10x + digital 10x', () {
      final p = planZoom(requested: 100, range: s24);
      expect(p.selected, 100);
      expect(p.cameraZoom, 10);
      expect(p.digitalZoom, closeTo(10, 1e-9));
    });

    test('within device range: no digital', () {
      final p = planZoom(requested: 3, range: s24);
      expect(p.cameraZoom, 3);
      expect(p.digitalZoom, 1);
    });

    test('below min clamps to min (0.6)', () {
      final p = planZoom(requested: 0.1, range: s24);
      expect(p.selected, 0.6);
      expect(p.cameraZoom, 0.6);
    });

    test('cheap 4x phone at 100x: camera 4x + digital 25x', () {
      final r = computeZoomRange(controllerMin: 1, controllerMax: 4);
      final p = planZoom(requested: 100, range: r);
      expect(p.selected, 100);
      expect(p.cameraZoom, 4);
      expect(p.digitalZoom, closeTo(25, 1e-9));
    });

    test('never exceeds displayMax', () {
      final p = planZoom(requested: 500, range: s24);
      expect(p.selected, 100);
      expect(p.digitalZoom, closeTo(10, 1e-9));
    });

    test('non-finite request falls back to 1x', () {
      final p = planZoom(requested: double.nan, range: s24);
      expect(p.selected, 1);
    });
  });
}
