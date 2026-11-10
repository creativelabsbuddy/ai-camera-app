import 'dart:io';
import 'dart:math' as math;

import 'package:ai_camera/models/quality_tier.dart';
import 'package:ai_camera/services/enhance_service.dart';
import 'package:ai_camera/services/night_pipeline.dart';
import 'package:ai_camera/services/openrouter_client.dart';
import 'package:ai_camera/services/prompt_builder.dart';
import 'package:ai_camera/services/zoom_ladder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

img.Image scene(int w, int h, {int dx = 0, int dy = 0, int seed = 1}) {
  final r = math.Random(seed);
  final im = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final sx = x + dx, sy = y + dy;
      final base =
          90 +
          60 * math.sin(sx / 5) * math.cos(sy / 7) +
          ((sx ~/ 16 + sy ~/ 16).isEven ? 30 : -30);
      int v() => (base + (r.nextDouble() - 0.5) * 30).round().clamp(0, 255);
      im.setPixelRgb(x, y, v(), v(), v());
    }
  }
  return im;
}

/// A different pattern (stands in for ghosted / moved letters).
img.Image other(int w, int h) {
  final im = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = ((x ~/ 9) * 37 + (y ~/ 13) * 91) % 200 + 20;
      im.setPixelRgb(x, y, v, v, v);
    }
  }
  return im;
}

LadderShot shot(double cp, double sharp, {double? cam}) => LadderShot(
  checkpoint: cp,
  path: '/tmp/l$cp.jpg',
  cameraZoom: cam ?? cp,
  sharpness: sharp,
);

void main() {
  group('A2 merge', () {
    test('a frame with different edges is rejected (no ghosting)', () {
      final r = mergeFrames([
        scene(160, 120),
        scene(160, 120, dx: 2, dy: -1, seed: 2),
        other(160, 120),
        scene(160, 120, dx: -1, dy: 2, seed: 3),
      ], median: true);
      expect(r.used, 3);
      expect(r.errors.length, 3);
      expect(r.errors[1], greaterThan(kMergeMaxEdgeErr));
      expect(r.errors[0], lessThan(kMergeMaxEdgeErr));
    });

    test('fewer than 2 good frames → the sharpest (first) alone', () {
      final a = scene(120, 90);
      final r = mergeFrames([a, other(120, 90), other(120, 90)]);
      expect(r.used, 1);
      expect(identical(r.image, a), isTrue);
    });

    test('median combine keeps the scene', () {
      final r = mergeFrames([
        scene(120, 90),
        scene(120, 90, seed: 5),
        scene(120, 90, seed: 6),
      ], median: true);
      expect(r.used, 3);
      expect(r.shifts, [(0, 0), (0, 0), (0, 0)]);
    });

    test('debug text', () {
      expect(
        mergeDebugText(3, 4, [0.2, 0.183, 0.64]),
        'Merged 3 of 4 · err 0.20/0.18/0.64✗',
      );
      expect(mergeDebugText(1, 4, const []), 'Sharpest of 4');
      expect(mergeDebugText(1, 4, [double.nan]), 'Sharpest of 4 · err size✗');
    });
  });

  group('A1 text-only Extreme / Ultra', () {
    test('payload without an image omits input_references', () {
      final p = buildImagesPayload(
        prompt: 'x',
        tier: QualityTier.hd,
        aspectRatio: '1:1',
        imageDataUrl: null,
      );
      expect(p.containsKey('input_references'), isFalse);
      expect(p['prompt'], 'x');
    });

    test('payload with an image keeps it last after the leading refs', () {
      final p = buildImagesPayload(
        prompt: 'x',
        tier: QualityTier.hd,
        aspectRatio: '1:1',
        imageDataUrl: 'data:main',
        leadingDataUrls: const ['data:a', 'data:b'],
      );
      final refs = p['input_references'] as List;
      expect(refs.length, 3);
      expect((refs.last as Map)['image_url'], {'url': 'data:main'});
    });
  });

  group('B zoom ladder', () {
    test('checkpoints stop at the camera max (no duplicate photos)', () {
      expect(ladderCheckpoints(4), [2, 3, 4]);
      expect(ladderCheckpoints(10), [2, 3, 4, 6, 8, 10]);
      expect(ladderCheckpoints(100), kLadderCheckpoints);
      expect(ladderCheckpoints(1), isEmpty);
    });

    test('due checkpoint, zoom out drops higher photos, retake', () {
      final l = ZoomLadder(hardwareMax: 10);
      expect(l.due(1.5), isNull);
      expect(l.due(2.2), 2);
      l.add(shot(2, 100));
      expect(l.due(2.5), isNull);
      expect(l.due(7), 6);
      l.add(shot(6, 60));
      expect(l.due(7), isNull);
      expect(l.zoomedTo(4), ['/tmp/l6.0.jpg']);
      expect(l.shots.map((s) => s.checkpoint), [2]);
      expect(l.due(5), 4); // retaken on the next zoom-in
    });

    test('last clear + refs: last clear and the 1–2 nearest below', () {
      final l = ZoomLadder(hardwareMax: 100);
      for (final s in [
        shot(2, 100),
        shot(4, 80),
        shot(8, 50),
        shot(16, 20), // blurry
        shot(32, 10), // blurry
      ]) {
        l.add(s);
      }
      expect(l.lastClear!.checkpoint, 8);
      final refs = l.selectRefs(40);
      expect(refs.map((s) => s.checkpoint), [8, 16, 32]);
      expect(refs.length, lessThanOrEqualTo(kLadderMaxRefs));
      expect(
        l.debugText(sent: refs),
        'Ladder: 2x✓ 4x✓ 8x✓ 16x✗ 32x✗ · last clear 8x · sent 8x, 16x, 32x + final',
      );
      // Final at 9x: only photos clearly wider than 9x.
      expect(l.selectRefs(9).map((s) => s.checkpoint), [2, 4, 8]);
    });

    test('flow per phone tier', () {
      expect(zoomFlowFor(ai: true, lowEnd: true, zoom: 20), ZoomFlow.ladder);
      expect(
        zoomFlowFor(ai: true, lowEnd: false, zoom: 20),
        ZoomFlow.flagshipSingle,
      );
      expect(zoomFlowFor(ai: true, lowEnd: true, zoom: 1.5), ZoomFlow.normal);
      expect(zoomFlowFor(ai: false, lowEnd: true, zoom: 20), ZoomFlow.normal);
    });

    test('ladder job: ≤3 refs, all at 768 px, no context', () {
      final f = [for (var i = 0; i < 5; i++) File('/tmp/s$i.jpg')];
      final j = EnhanceJob(
        image: File('/tmp/x.jpg'),
        steps: f,
        zoomLadder: true,
        zoom: 40,
      );
      expect(j.isLadder, isTrue);
      expect(j.sentSteps.length, 3);
      expect(j.mainLong, kLadderMainLong); // v11.31
      expect(j.stepLong, kLadderImageLong);
      final plain = EnhanceJob(image: File('/tmp/x.jpg'), steps: f, zoom: 40);
      expect(plain.isLadder, isFalse);
      expect(plain.sentSteps, isEmpty);
      expect(plain.mainLong, isNull);
    });

    test('prompt and note text', () {
      expect(
        kZoomLadderPrompt,
        startsWith(kUniversalEnhancePrompt), // v11.58
      );
      expect(kLadderNote, 'Small text may not be accurate at high zoom.');
    });
  });
}
