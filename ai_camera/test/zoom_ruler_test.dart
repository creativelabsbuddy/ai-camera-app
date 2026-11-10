import 'package:ai_camera/services/zoom_ruler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final s = ZoomRulerScale(min: 0.6, max: 100);

  test('log mapping: ends, monotonic, round trip', () {
    expect(s.zoomAt(0), closeTo(0.6, 1e-9));
    expect(s.zoomAt(1), closeTo(100, 1e-9));
    expect(s.positionOf(0.6), 0);
    expect(s.positionOf(100), 1);
    expect(s.positionOf(500), 1); // clamped
    var last = 0.0;
    for (var i = 0; i <= 100; i++) {
      final z = s.zoomAt(i / 100);
      expect(z, greaterThan(last));
      last = z;
      expect(s.positionOf(z), closeTo(i / 100, 1e-9));
    }
    // Logarithmic: 1→2 takes as much room as 10→20.
    expect(
      s.positionOf(2) - s.positionOf(1),
      closeTo(s.positionOf(20) - s.positionOf(10), 1e-9),
    );
  });

  test('fine steps: 0.1x below 10x, 1x steps from 10x; min/max exact', () {
    expect(quantizeZoom(2.34, min: 0.6, max: 100), 2.3);
    expect(quantizeZoom(2.36, min: 0.6, max: 100), 2.4);
    expect(quantizeZoom(9.93, min: 0.6, max: 100), 9.9);
    expect(quantizeZoom(9.97, min: 0.6, max: 100), 10);
    // v11.42: 0.5x steps 10x–30x, 1x above.
    expect(quantizeZoom(21.6, min: 0.6, max: 100), 21.5);
    expect(quantizeZoom(22.4, min: 0.6, max: 100), 22.5);
    expect(quantizeZoom(40.4, min: 0.6, max: 100), 40);
    expect(quantizeZoom(0.55, min: 0.55, max: 100), 0.55); // ultra-wide min
    expect(quantizeZoom(0.58, min: 0.55, max: 100), 0.6);
    expect(quantizeZoom(140, min: 0.6, max: 100), 100);
    expect(quantizeZoom(double.nan, min: 0.6, max: 100), 0.6);
    for (var i = 0; i <= 400; i++) {
      final q = s.snappedAt(i / 400);
      if (q < 10) {
        expect((q * 10 - (q * 10).round()).abs() < 1e-9 || q == 0.6, isTrue);
      } else if (q < 30) {
        expect(q * 2, (q * 2).roundToDouble()); // v11.42: 0.5x steps
      } else {
        expect(q, q.roundToDouble());
      }
    }
  });

  test('big centred label', () {
    expect(formatRulerLabel(22), '22.0x');
    expect(formatRulerLabel(2.4), '2.4x');
    expect(formatRulerLabel(100), '100.0x');
    expect(formatRulerLabel(0.6), '0.6x');
  });

  test(
    'scrub: drag left zooms in, right zooms out, full extent = full range',
    () {
      expect(s.scrub(from: 1, dx: -50, extent: 600), greaterThan(1));
      expect(s.scrub(from: 10, dx: 50, extent: 600), lessThan(10));
      expect(s.scrub(from: 0.6, dx: -600, extent: 600), 100);
      expect(s.scrub(from: 100, dx: 600, extent: 600), 0.6);
      expect(s.scrub(from: 5, dx: 0, extent: 600), 5);
    },
  );

  test('haptic ticks: lens chips crossed, both directions, no re-tick', () {
    const chips = [0.6, 1.0, 2.0, 3.0, 5.0, 10.0];
    expect(crossedTicks(1, 4.2, chips), [2.0, 3.0]);
    expect(crossedTicks(1, 5, chips), [2.0, 3.0, 5.0]); // landing ticks
    expect(crossedTicks(5, 5, chips), isEmpty);
    expect(crossedTicks(5, 5.1, chips), isEmpty); // leaving 5 doesn't tick
    expect(crossedTicks(22, 4, chips), [5.0, 10.0]);
    expect(crossedTicks(1.5, 0.6, chips), [0.6, 1.0]);
  });

  test('ruler ticks: majors at chips + 30/100 shortcuts, labelled', () {
    final ticks = buildRulerTicks(
      s,
      lensChips: const [0.6, 1, 2, 3, 5, 10],
      shortcuts: const [30, 100],
    );
    final majors = ticks.where((t) => t.kind == RulerTickKind.major).toList();
    expect(majors.map((t) => t.label), [
      '.6',
      '1',
      '2',
      '3',
      '5',
      '10',
      '30',
      '100',
    ]);
    expect(
      ticks.map((t) => t.zoom).toList(),
      [...ticks.map((t) => t.zoom)]..sort(),
    );
    expect(
      ticks.any((t) => t.zoom == 15 && t.kind == RulerTickKind.medium),
      isTrue,
    );
    // No duplicates at major positions.
    expect(ticks.where((t) => t.zoom == 10).length, 1);
  });

  test('degenerate range (front camera fixed 1x)', () {
    final f = ZoomRulerScale(min: 1, max: 1);
    expect(f.zoomAt(0.5), 1);
    expect(f.positionOf(3), 0);
    expect(f.scrub(from: 1, dx: -100, extent: 300), 1);
  });
}
