import 'dart:io';
import 'dart:math' as math;

import 'package:ai_camera/services/frame_stats.dart';
import 'package:ai_camera/services/macro.dart';
import 'package:flutter_test/flutter_test.dart';

/// Synthetic 48×64 RGBA preview thumb (same format as FrameStats.thumb):
/// a textured "scene" [kind], shifted by [dx]/[dy] thumb px (hand shake),
/// with exposure [gain]/[offset] and a little sensor noise.
List<int> frame(
  int kind, {
  double dx = 0,
  double dy = 0,
  double gain = 1,
  double offset = 0,
  int noiseSeed = 1,
}) {
  final rnd = math.Random(noiseSeed);
  final out = List<int>.filled(kThumbW * kThumbH * 4, 255);
  for (var y = 0; y < kThumbH; y++) {
    for (var x = 0; x < kThumbW; x++) {
      final u = x + dx, v = y + dy;
      final double g = switch (kind) {
        // a mug-like blob with a handle on a table
        0 =>
          110 +
              70 *
                  math.exp(-(math.pow(u - 22, 2) + math.pow(v - 30, 2)) / 150) +
              35 * math.sin(u / 5) * math.cos(v / 9),
        // a different place: wall corner + window light
        1 => 60 + 2.2 * v + (u > 30 ? 60 : 0) + 20 * math.cos(u / 3.5),
        // another place: floor tiles
        _ =>
          120 + 50 * ((u ~/ 12 + v ~/ 12).isEven ? 1 : -1) + 10 * math.sin(v),
      };
      final val = (g * gain + offset + rnd.nextDouble() * 6 - 3).round().clamp(
        0,
        255,
      );
      final o = (y * kThumbW + x) * 4;
      // v11.26: each place has its own colour cast (the drift check now
      // needs both structure AND colour to differ).
      final tint = switch (kind) {
        0 => const [1.0, 0.75, 0.5],
        1 => const [0.5, 0.7, 1.0],
        _ => const [0.5, 1.0, 0.6],
      };
      out[o] = (val * tint[0]).round();
      out[o + 1] = (val * tint[1]).round();
      out[o + 2] = (val * tint[2]).round();
    }
  }
  return out;
}

void main() {
  test('root cause: old RGBA mean-abs-diff could never reach 0.30', () {
    final r = math.Random(7);
    List<int> noise() => [
      for (var i = 0; i < kThumbW * kThumbH; i++) ...[
        r.nextInt(256),
        r.nextInt(256),
        r.nextInt(256),
        255,
      ],
    ];
    // Two completely unrelated random frames: old metric ~0.25 < 0.30.
    expect(frameDiff(noise(), noise()), lessThan(0.30));
    expect(frameDiff(frame(0), frame(1)), lessThan(0.30));
    // New metric: clearly a drift.
    expect(driftScore(frame(0), frame(1))!, greaterThan(kDriftDiffThreshold));
  });

  test('calibration: new place triggers, hand shake / exposure do not', () {
    final base = frame(0);
    for (final s in [
      frame(0, noiseSeed: 2),
      frame(0, dx: 1, dy: 1, noiseSeed: 3),
      frame(0, dx: -2, dy: 1.5, noiseSeed: 4),
      frame(0, gain: 0.8, offset: 20, noiseSeed: 5), // auto exposure
    ]) {
      expect(driftScore(base, s)!, lessThan(kDriftReturnDiff));
    }
    for (final k in [1, 2]) {
      expect(driftScore(base, frame(k))!, greaterThan(kDriftDiffThreshold));
      expect(driftScore(base, frame(k))!, greaterThan(kDriftDeepThreshold));
    }
    expect(driftScore(base, [1, 2]), isNull);
  });

  group('home-screen drift path (MacroDriftMonitor, synthetic frames)', () {
    final t0 = DateTime(2026, 10, 14, 12);
    DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

    test('locked at 1.5x: moving away → popup, then reset after 3 s', () {
      final m = MacroDriftMonitor();
      final events = <DriftEvent>[];
      var ms = 0;
      // steady on the subject (~2 s, small shake)
      for (; ms <= 2000; ms += 100) {
        events.add(
          m.onFrame(
            thumb: frame(0, dx: (ms % 300) / 300, noiseSeed: ms),
            chip: 1.5,
            now: at(ms),
            locked: true,
          ),
        );
      }
      expect(events, everyElement(DriftEvent.none));
      expect(m.score!, lessThan(kDriftDiffThreshold));
      // move to a new place: started within ~1.5 s
      DriftEvent? started;
      var startedAt = 0;
      for (; ms <= 5000 && started == null; ms += 100) {
        final e = m.onFrame(
          thumb: frame(2, noiseSeed: ms), // v11.26: textured new place
          chip: 1.5,
          now: at(ms),
          locked: true,
        );
        if (e != DriftEvent.none) {
          started = e;
          startedAt = ms;
        }
      }
      expect(started, DriftEvent.started);
      expect(startedAt, lessThanOrEqualTo(4600)); // v11.26: 2 s confirm
      expect(m.waiting, isTrue);
      expect(m.score!, greaterThan(kDriftDiffThreshold));
      // stays away → reset after the 3 s window (timer tick, no frames)
      expect(m.tick(at(startedAt + 4900)), DriftEvent.none);
      expect(m.tick(at(startedAt + 5000)), DriftEvent.reset);
      expect(m.waiting, isFalse);
    });

    test('comes back within 3 s → lock restored, no reset', () {
      final m = MacroDriftMonitor();
      var ms = 0;
      for (; ms <= 1000; ms += 100) {
        m.onFrame(thumb: frame(0), chip: 3, now: at(ms), locked: true);
      }
      var e = DriftEvent.none;
      for (; e == DriftEvent.none; ms += 100) {
        e = m.onFrame(thumb: frame(2), chip: 3, now: at(ms), locked: true);
      }
      expect(e, DriftEvent.started);
      final back = <DriftEvent>[];
      for (var i = 0; i < 25; i++, ms += 100) {
        // ≥1.5 s popup minimum
        back.add(
          m.onFrame(
            thumb: frame(0, dx: 1, noiseSeed: i),
            chip: 3,
            now: at(ms),
            locked: true,
          ),
        );
      }
      expect(back, contains(DriftEvent.returned));
      expect(back, isNot(contains(DriftEvent.reset)));
      expect(m.waiting, isFalse);
    });

    test('checked through all zoom steps; not before the lock', () {
      for (final chip in [1.5, 2.0, 3.0, 4.0, 5.0, 6.0, 12.0, 21.0, 30.0]) {
        final m = MacroDriftMonitor();
        var ms = 0, fired = false;
        for (; ms <= 1000; ms += 100) {
          m.onFrame(thumb: frame(0), chip: chip, now: at(ms), locked: true);
        }
        for (; ms <= 5000 && !fired; ms += 100) {
          fired =
              m.onFrame(
                thumb: frame(2),
                chip: chip,
                now: at(ms),
                locked: true,
              ) ==
              DriftEvent.started;
        }
        expect(fired, isTrue, reason: 'chip $chip');
      }
      final m = MacroDriftMonitor();
      for (var ms = 0; ms <= 5000; ms += 100) {
        expect(
          m.onFrame(
            thumb: frame(ms < 1000 ? 0 : 1),
            chip: 1.5,
            now: at(ms),
            locked: false,
          ),
          DriftEvent.none,
        );
      }
      expect(m.score, isNull);
    });

    test('hand shake at deep zoom does not trigger', () {
      final m = MacroDriftMonitor();
      for (var ms = 0; ms <= 6000; ms += 100) {
        expect(
          m.onFrame(
            thumb: frame(
              0,
              dx: 2 * math.sin(ms / 300),
              dy: 1.5 * math.cos(ms / 410),
              noiseSeed: ms,
            ),
            chip: 21,
            now: at(ms),
            locked: true,
          ),
          DriftEvent.none,
        );
      }
    });

    test('debug text', () {
      expect(
        driftDebugText(const DriftMetric(0.4567, 0.1234)),
        'drift: s0.46 c0.12',
      );
      expect(driftDebugText(null), 'drift: –');
    });
  });

  test(
    'home screen routes every Macro frame through the monitor',
    () {
      final s = File('lib/screens/home_camera_screen.dart').readAsStringSync();
      expect(s, contains('_drift.onFrame('));
      expect(
        s,
        contains('locked: _macroStage >= 1 && _subjectLock.parent != null'),
      );
      expect(s, contains('case DriftEvent.started:'));
      expect(s, contains('case DriftEvent.reset:'));
      expect(s, contains('_drift.tick(now)'));
      expect(s, contains("ValueKey('macro_drift_debug')"));
      expect(s, isNot(contains('_macroStage < 1 ||\n              _ctxBusy')));
    },
    skip: 'v11.33: replaced by level chips + box check',
  );

  test('thresholds are constants', () {
    expect(kDriftDiffThreshold, 0.65);
    expect(kDriftCheckInterval, const Duration(milliseconds: 500));
    expect(kDriftReturnTimeout, const Duration(seconds: 5));
  });
}
