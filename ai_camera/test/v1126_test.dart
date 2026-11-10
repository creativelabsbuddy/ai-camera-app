import 'dart:io';
import 'dart:math' as math;

import 'package:ai_camera/services/macro.dart';
import 'package:flutter_test/flutter_test.dart';

const w = 48, h = 64;

/// Synthetic 48x64 RGBA scene: [f] gives the RGB at (x, y).
List<int> scene(List<int> Function(double x, double y) f) {
  final t = List<int>.filled(w * h * 4, 255);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final c = f(x.toDouble(), y.toDouble());
      final o = (y * w + x) * 4;
      t[o] = c[0];
      t[o + 1] = c[1];
      t[o + 2] = c[2];
    }
  }
  return t;
}

/// A red flower with yellow centre on green leaves, offset by (dx, dy).
List<int> flower({double dx = 0, double dy = 0}) => scene((x, y) {
  final cx = 24 + dx, cy = 30 + dy;
  final r = math.sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy));
  final petal = 14 + 4 * math.cos(5 * math.atan2(y - cy, x - cx));
  if (r < 5) return [240, 210, 40];
  if (r < petal) return [210, 40, 60];
  final v = ((x + y) % 10 < 5) ? 110 : 80;
  return [40, v, 50];
});

/// A different subject: blue/white checker (fabric) with grey edge.
List<int> fabric() => scene((x, y) {
  if (((x ~/ 6) + (y ~/ 6)).isEven) return [40, 70, 200];
  return [235, 235, 240];
});

List<int> boxBlur(List<int> t, int r) {
  final o = List<int>.of(t);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      for (var c = 0; c < 3; c++) {
        var s = 0, n = 0;
        for (var j = -r; j <= r; j++) {
          for (var i = -r; i <= r; i++) {
            final xx = x + i, yy = y + j;
            if (xx < 0 || yy < 0 || xx >= w || yy >= h) continue;
            s += t[(yy * w + xx) * 4 + c];
            n++;
          }
        }
        o[(y * w + x) * 4 + c] = s ~/ n;
      }
    }
  }
  return o;
}

void main() {
  group('drift robustness', () {
    test('shifted / blurred same subject does not count as drift', () {
      final ref = flower();
      for (final v in [
        flower(dx: 5, dy: 0),
        flower(dx: -4, dy: 6),
        flower(dx: 0, dy: -8),
        boxBlur(ref, 2),
        boxBlur(flower(dx: 3, dy: 4), 1),
      ]) {
        final m = driftMetric(ref, v)!;
        expect(m.driftAt(3), isFalse, reason: '$m');
        expect(m.driftAt(8), isFalse, reason: '$m');
      }
    });

    test('a different subject triggers', () {
      final m = driftMetric(flower(), fabric())!;
      expect(m.driftAt(3), isTrue, reason: '$m');
      expect(m.driftAt(8), isTrue, reason: '$m');
      expect(m.toString(), matches(RegExp(r'^s\d\.\d\d c\d\.\d\d$')));
    });

    test('thresholds + confirm time per zoom', () {
      expect(kDriftDiffThreshold, 0.65);
      expect(kDriftColorThreshold, 0.45);
      expect(kDriftDeepThreshold, 0.75);
      expect(kDriftDeepColorThreshold, 0.50);
      expect(kDriftChecksNeeded, 4); // 2.0 s at 500 ms
      expect(kDriftDeepChecksNeeded, 6); // 3.0 s
      expect(kDriftReturnDiff, 0.35);
      expect(kDriftReturnColor, 0.25);
      expect(kDriftPopupMin, const Duration(milliseconds: 1500));
      expect(kDriftReturnTimeout, const Duration(seconds: 5));
    });

    test('watch: shaky same subject never fires, new subject fires', () {
      final t0 = DateTime(2026);
      final wtch = SubjectChangeWatch();
      final ref = flower();
      var fired = false;
      for (var i = 0; i < 20; i++) {
        final f = i.isEven ? flower(dx: 4, dy: -3) : boxBlur(ref, 1);
        fired |= wtch.update(
          thumb: i == 0 ? ref : f,
          zoom: 3,
          now: t0.add(Duration(milliseconds: 500 * i)),
          sharpness: 100,
        );
      }
      expect(fired, isFalse);
      final w2 = SubjectChangeWatch();
      var at = -1;
      for (var i = 0; i < 10 && at < 0; i++) {
        if (w2.update(
          thumb: i == 0 ? ref : fabric(),
          zoom: 3,
          now: t0.add(Duration(milliseconds: 500 * i)),
          sharpness: 100,
        )) {
          at = i;
        }
      }
      expect(at, kDriftChecksNeeded);
    });

    test('blur gate: blurry frames are skipped until sharp again', () {
      final t0 = DateTime(2026);
      final wtch = SubjectChangeWatch();
      wtch.update(thumb: flower(), zoom: 3, now: t0, sharpness: 100);
      for (var i = 1; i <= 10; i++) {
        expect(
          wtch.update(
            thumb: fabric(),
            zoom: 3,
            now: t0.add(Duration(milliseconds: 500 * i)),
            sharpness: 30,
          ),
          isFalse,
        );
        expect(wtch.blurry, isTrue);
      }
      expect(driftFrameBlurry(40, 100), isTrue);
      expect(driftFrameBlurry(60, 100), isFalse);
    });

    test('popup stays at least 1.5 s even when back at once', () {
      final t0 = DateTime(2026);
      final ref = flower();
      final d = DriftReturn()..start(ref, t0);
      expect(
        d.update(ref, t0.add(const Duration(milliseconds: 200))),
        DriftState.waiting,
      );
      expect(
        d.update(ref, t0.add(const Duration(milliseconds: 700))),
        DriftState.waiting,
      );
      expect(
        d.update(ref, t0.add(const Duration(milliseconds: 1600))),
        DriftState.returned,
      );
    });

    test('debug line shows s / c and how the window ended', () {
      const m = DriftMetric(0.7, 0.5);
      expect(driftDebugText(m), 'drift: s0.70 c0.50');
      expect(driftDebugText(m, end: 'back'), 'drift: s0.70 c0.50 · back');
      expect(driftDebugText(m, end: 'reset'), contains('reset'));
    });
  });

  group('1x no-op while locked', () {
    test('1x always keeps the lock, whatever the view', () {
      for (final m in [
        const DriftMetric(0.99, 0.99),
        const DriftMetric(0, 0),
        null,
      ]) {
        expect(
          chipReturnAction(locked: true, chip: 1.0, metric: m, score: 0.99),
          ChipReturnAction.keepLock,
        );
      }
    });

    test('1.5x: match keeps the lock, mismatch re-detects', () {
      expect(
        chipReturnAction(
          locked: true,
          chip: 1.5,
          metric: driftMetric(flower(), flower(dx: 4)),
        ),
        ChipReturnAction.keepLock,
      );
      expect(
        chipReturnAction(
          locked: true,
          chip: 1.5,
          metric: driftMetric(flower(), fabric()),
        ),
        ChipReturnAction.redetect,
      );
    });

    test(
      'home: the return check only runs for 1.5x',
      () {
        final s = File(
          'lib/screens/home_camera_screen.dart',
        ).readAsStringSync();
        expect(s, contains('driftMetric('));
        expect(
          s,
          contains(kGuideZooming.isNotEmpty ? 'zooming: _zooming' : ''),
        );
      },
      skip: 'v11.33: replaced by level chips + box check',
    );
  });

  group('credits + inputs', () {
    test('credit mapping per level', () {
      // v11.33 HD defaults.
      expect(macroCreditsFor('macro'), 4);
      expect(macroCreditsFor('close'), 4);
      expect(macroCreditsFor('microscope'), 5);
      expect(macroCreditsFor('extreme'), 2);
      expect(macroCreditsFor('ultra'), 2);
      expect(macroLevelCostLabel('Extreme', 'extreme'), 'Extreme · 🪙2');
    });

    test('input-photo counts per level', () {
      expect(macroInputPlan('macro').maxSteps, 2);
      expect(macroInputPlan('close').maxSteps, 2);
      expect(macroInputPlan('microscope').maxSteps, 1); // v11.33
      expect(macroInputPlan('extreme').maxSteps, 2);
      expect(macroInputPlan('ultra').maxSteps, 2);
      for (final l in ['macro', 'close', 'microscope']) {
        expect(macroInputPlan(l).cropLong, 1536);
      }
      expect(macroInputPlan('extreme').cropLong, isNull);
      expect(macroInputPlan('microscope').stepLong, 768);
    });

    test('wiring: job spec + sent steps + server upload sizes', () {
      final e = File('lib/services/enhance_service.dart').readAsStringSync();
      expect(e, contains('creditsOverride: aiMode == \'macro\''));
      expect(e, contains('steps.take(macroInputs.maxSteps)'));
      expect(e, contains('leading: job.sentSteps')); // v11.30
      final en = File('lib/services/entitlements.dart').readAsStringSync();
      expect(en, contains('var remaining = spec.credits;'));
    });

    test('guide shows the zoom hint', () {
      expect(kGuideZooming, 'Hold steady while zooming');
    });
  });
}
