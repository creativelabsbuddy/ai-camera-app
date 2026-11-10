import 'package:ai_camera/services/optical_profile.dart';
import 'package:ai_camera/services/zoom_chips.dart';
import 'package:ai_camera/services/zoom_range.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> labels(List<ZoomStop> s) => s.map((e) => e.label).toList();

OpticalProfile profile(List<double> usable, {double crop = 1}) {
  final best = usable.reduce((a, b) => a > b ? a : b).clamp(1.0, 100.0);
  return OpticalProfile(
    usableFactors: usable,
    allFactors: usable,
    bestOptical: best,
    sensorCropFactor: crop,
    opticalLimit: best > crop ? best : crop,
    appMaxZoom: 10,
    fromCamera2: true,
  );
}

void main() {
  final s24Range = computeZoomRange(
    controllerMin: 0.6,
    controllerMax: 10,
    nativeReportedMax: 10,
  );
  final s24 = profile([0.6, 1, 3, 5], crop: 2);

  test('S24 Ultra-like: chips .6 1 2 3 5 10; 30 / 100 are ruler ticks', () {
    final c = buildZoomChipSet(s24Range, optical: s24);
    expect(labels(c.primary), ['.6', '1', '2', '3', '5', '10']);
    expect(labels(c.extended), ['30', '100']);
    expect(c.primary.first.value, 0.6);
    // v9: no chip expansion — the pill always shows the lens chips only.
    for (final z in [1.0, 10.0, 45.0, 100.0]) {
      expect(labels(c.visible(z)), ['.6', '1', '2', '3', '5', '10']);
    }
    expect(c.lensValues, [0.6, 1, 2, 3, 5, 10]);
    expect(c.shortcutValues, [30, 100]);
  });

  test('active chip = highest chip at or below zoom', () {
    final c = buildZoomChipSet(s24Range, optical: s24);
    expect(c.activeIndex(1), 1);
    expect(c.activeIndex(0.6), 0);
    expect(c.activeIndex(4.2), 3); // "3" chip shows live 4.2×
    expect(c.activeIndex(10), 5);
    expect(c.activeIndex(30), 5); // last chip shows the live "30×"
    expect(c.activeIndex(100), 5);
  });

  test('cheap 50MP phone without tele: 1 2, ticks 10 30 100', () {
    final r = computeZoomRange(controllerMin: 1, controllerMax: 8);
    final c = buildZoomChipSet(r, optical: profile([1], crop: 2));
    expect(labels(c.primary), ['1', '2']);
    expect(labels(c.extended), ['10', '30', '100']);
  });

  test('ultra-wide + 3x tele phone: .5 1 2 3 6', () {
    final r = computeZoomRange(controllerMin: 0.5, controllerMax: 10);
    final c = buildZoomChipSet(r, optical: profile([0.5, 1, 3]));
    expect(labels(c.primary), ['.5', '1', '2', '3', '6']);
    expect(labels(c.extended), ['10', '30', '100']);
  });

  test('front camera 1–8x: 1 2, one chip at max', () {
    final r = computeZoomRange(
      controllerMin: 1,
      controllerMax: 8,
      displayTarget: null,
    );
    final c = buildZoomChipSet(r);
    expect(labels(c.primary), ['1', '2']);
    expect(labels(c.extended), ['8']);
  });

  test('no zoom at all → single 1 chip, no ticks', () {
    final c = buildZoomChipSet(ZoomRange.none);
    expect(labels(c.primary), ['1']);
    expect(c.extended, isEmpty);
    expect(c.shortcutValues, isEmpty);
  });

  test('chip text', () {
    expect(formatChipZoom(0.6), '.6');
    expect(formatChipZoom(0.55), '.6');
    expect(formatChipZoom(1), '1');
    expect(formatChipZoom(2.4), '2.4');
    expect(formatChipZoom(100), '100');
  });
}
