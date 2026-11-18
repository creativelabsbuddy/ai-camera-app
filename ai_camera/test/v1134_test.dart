import 'dart:io';
import 'dart:typed_data';

import 'package:ai_camera/services/prompt_builder.dart';
import 'package:ai_camera/services/zoom_assist.dart';
import 'package:ai_camera/services/zoom_ladder.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List frame({int bg = 20, int spot = 255, int size = 6}) {
  const w = 48, h = 64;
  final t = Uint8List(w * h)..fillRange(0, w * h, bg);
  for (var y = 10; y < 10 + size; y++) {
    for (var x = 30; x < 30 + size; x++) {
      t[y * w + x] = spot;
    }
  }
  return t;
}

LadderShot shot(double cp, double sharp) =>
    LadderShot(checkpoint: cp, path: '/x$cp', cameraZoom: cp, sharpness: sharp);

void main() {
  group('bright region (luminance only)', () {
    test('small clipping spot in a dark frame → centroid', () {
      final s = findBrightSpot(frame(), 48, 64)!;
      expect(s.centroid.dx, closeTo(33 / 48, 0.01));
      expect(s.centroid.dy, closeTo(13 / 64, 0.01));
    });
    test('bright frame, no clipping, or huge area → none', () {
      expect(findBrightSpot(frame(bg: 150), 48, 64), isNull);
      expect(
        findBrightSpot(frame(spot: 150), 48, 64),
        isNotNull,
      ); // v11.36 relative (no 200 floor)
      expect(findBrightSpot(frame(size: 40), 48, 64), isNull);
    });
    test('EV clamped to device range', () {
      expect(brightEvFor(-4, 4), -2.5);
      expect(brightEvFor(-2, 2), -2);
      expect(brightEvFor(-1, 1), -1);
    });
    test('meter hysteresis: on after 3, off after 10', () {
      final m = BrightMeter();
      const s = BrightSpot(Offset(0.5, 0.5), 0.01, 10);
      expect(m.update(s), isFalse);
      expect(m.update(s), isFalse);
      expect(m.update(s), isTrue);
      for (var i = 0; i < 9; i++) {
        expect(m.update(null), isFalse);
      }
      expect(m.update(null), isTrue);
      expect(m.active, isFalse);
    });
  });

  group('step-by-step checkpoints', () {
    test('fast jump walks every missing checkpoint', () {
      expect(checkpointsToWalk(1, 20, kLadderCheckpoints, {3}), [
        2,
        4,
        6,
        8,
        12,
        16,
      ]);
      expect(checkpointsToWalk(20, 4, kLadderCheckpoints, {}), isEmpty);
    });
    test('missed below only inside the chain', () {
      final l = ZoomLadder(hardwareMax: 100);
      expect(l.missedBelow(8), isFalse);
      l.add(shot(2, 50));
      l.add(shot(3, 50));
      expect(l.missedBelow(4), isFalse);
      expect(l.missedBelow(8), isTrue); // 4, 6 skipped
      expect(l.below(8)!.checkpoint, 3);
      expect(l.takenCheckpoints, {2.0, 3.0});
    });
  });

  group('subject match', () {
    test('ncc + centre resample', () {
      final a = [for (var i = 0; i < 100; i++) (i % 10).toDouble()];
      expect(ncc(a, a), closeTo(1, 1e-9));
      expect(ncc(a, [for (final v in a) 9 - v]), closeTo(-1, 1e-9));
      final c = centreResample(a, 10, 10, 2, 5, 5);
      expect(c.length, 25);
      expect(c.first, 3.0);
      expect(isSameSubject(0.9), isTrue);
      expect(isSameSubject(0.1), isFalse);
    });
  });

  group('clear limit', () {
    test('highest clear before the first blurry', () {
      expect(observedClearLimit([(2, true), (4, true), (8, false)]), 4);
      expect(observedClearLimit([(2, true), (4, true)]), isNull);
      expect(observedClearLimit([(2, false)]), isNull);
    });
    test('hint only past the limit after a change, tap only', () {
      expect(
        showNewSubjectHint(subjectChanged: true, zoom: 16, clearLimit: 8),
        isTrue,
      );
      expect(
        showNewSubjectHint(subjectChanged: true, zoom: 6, clearLimit: 8),
        isFalse,
      );
      expect(
        showNewSubjectHint(subjectChanged: false, zoom: 16, clearLimit: 8),
        isFalse,
      );
      expect(kNewSubjectHint, 'New subject – tap to capture detail');
    });
  });

  test('zoom prompt + wiring', () {
    // v11.63: zoom uses the same simple prompt as Pro Photo.
    expect(kZoomCleanPrompt, kUniversalEnhancePrompt);
    expect(kZoomLadderPrompt.startsWith(kZoomCleanPrompt), isTrue);
    final h = File('lib/screens/home_camera_screen.dart').readAsStringSync();
    expect(h, contains('zoomClean: zoomFlow != ZoomFlow.normal'));
    expect(h, contains('_walkCheckpoints()'));
    expect(h, contains('_captureAtClearLimit()'));
    // v11.59: refs are matched to the final AREA (aligned, sharpness-aware).
    expect(h, contains('await pickZoomSource('));
    final e = File('lib/services/enhance_service.dart').readAsStringSync();
    expect(e, contains('framingCheckApplies(')); // v11.42
  });
}
