import 'dart:math' as math;

import 'package:ai_camera/models/camera_options.dart';
import 'package:ai_camera/models/capture_mode.dart';
import 'package:ai_camera/services/night_pipeline.dart';
import 'package:ai_camera/services/prompt_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  group('pipeline selection', () {
    test('night off → normal single shot', () {
      final p = selectCapturePipeline(
        night: false,
        mode: CaptureMode.pro,
        maxExposureOffset: 4,
      ).pipeline;
      expect(p.night, isFalse);
      expect(p.frames, 1);
      expect(p.steps, isEmpty);
      expect(p.aiNight, isFalse);
    });

    test('night + Normal: free burst merge + exposure boost, no AI', () {
      final sel = selectCapturePipeline(
        night: true,
        mode: CaptureMode.normal,
        maxExposureOffset: 4,
      );
      final p = sel.pipeline;
      expect(p.frames, 10); // default luma 0.15 → 10 frames
      expect(p.exposureBoostEv, 2.0);
      expect(p.steps, [NightStep.exposureBoost, NightStep.burstMerge]);
      expect(p.holdSteadyHint, isTrue);
      expect(p.aiNight, isFalse);
      expect(sel.note(mergedFrames: 3), 'Night · 3 frames merged');
    });

    test('night + Pro AI: adds the AI night prompt step', () {
      final p = selectCapturePipeline(
        night: true,
        mode: CaptureMode.pro,
        maxExposureOffset: 2,
      ).pipeline;
      expect(p.steps, [
        NightStep.exposureBoost,
        NightStep.burstMerge,
        NightStep.aiNightPrompt,
      ]);
      expect(p.aiNight, isTrue);
    });

    test('boost clamped to camera max; no compensation → no boost step', () {
      expect(
        selectCapturePipeline(
          night: true,
          mode: CaptureMode.normal,
          maxExposureOffset: 0.5,
        ).pipeline.exposureBoostEv,
        0.5,
      );
      final p = selectCapturePipeline(
        night: true,
        mode: CaptureMode.normal,
      ).pipeline;
      expect(p.exposureBoostEv, 0);
      expect(p.has(NightStep.exposureBoost), isFalse);
      expect(p.has(NightStep.burstMerge), isTrue);
    });

    test('flash forced on → single frame, no boost, AI night still in Pro', () {
      final p = selectCapturePipeline(
        night: true,
        mode: CaptureMode.pro,
        flash: FlashChoice.on,
        maxExposureOffset: 4,
      ).pipeline;
      expect(p.frames, 1);
      expect(p.exposureBoostEv, 0);
      expect(p.holdSteadyHint, isFalse);
      expect(p.steps, [NightStep.aiNightPrompt]);
    });
  });

  test('AI night prompt goes right after the locked prompt (exact text)', () {
    final p = buildEnhancePrompt(night: true, hasContextImage: true);
    expect(p.startsWith('$kLockedEnhancePrompt $kNightPrompt'), isTrue);
    // v11 night prompt (mirrors the server's default; admin-editable).
    // v11.48: general night prompt.
    expect(kNightPrompt, startsWith('A natural night photograph'));
    expect(kNightPrompt, contains('do not add anything new'));
    expect(buildEnhancePrompt().contains(kNightPrompt), isFalse);
  });

  group('burst merge', () {
    img.Image scene(
      int w,
      int h, {
      int dx = 0,
      int dy = 0,
      int seed = 1,
      double noise = 30,
    }) {
      final r = math.Random(seed);
      final im = img.Image(width: w, height: h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          // Textured base pattern (shifted by dx,dy) + per-frame noise.
          final sx = x + dx;
          final sy = y + dy;
          final base =
              90 +
              60 * math.sin(sx / 5) * math.cos(sy / 7) +
              ((sx ~/ 16 + sy ~/ 16).isEven ? 30 : -30);
          int v() =>
              (base + (r.nextDouble() - 0.5) * 2 * noise).round().clamp(0, 255);
          im.setPixelRgb(x, y, v(), v(), v());
        }
      }
      return im;
    }

    double noiseVs(img.Image a, img.Image clean) {
      var s = 0.0;
      var n = 0;
      for (var y = 10; y < a.height - 10; y++) {
        for (var x = 10; x < a.width - 10; x++) {
          s += (a.getPixel(x, y).r - clean.getPixel(x, y).r).abs();
          n++;
        }
      }
      return s / n;
    }

    test('aligns shifted frames and reduces noise', () {
      final clean = scene(160, 120, noise: 0);
      final frames = [
        scene(160, 120, seed: 1),
        scene(160, 120, dx: 3, dy: -2, seed: 2), // hand shake
        scene(160, 120, dx: -2, dy: 1, seed: 3),
      ];
      final r = mergeFrames(frames);
      expect(r.used, 3);
      expect(r.shifts, [(0, 0), (-3, 2), (2, -1)]);
      expect(
        noiseVs(r.image, clean),
        lessThan(noiseVs(frames.first, clean) * 0.75),
      );
    });

    test('frame with a different scene (big motion) is dropped', () {
      final a = scene(120, 90, seed: 1);
      final moved = img.Image(width: 120, height: 90);
      img.fill(moved, color: img.ColorRgb8(250, 250, 250));
      final r = mergeFrames([a, moved, scene(120, 90, seed: 4)]);
      expect(r.used, 2);
    });

    test('mismatched size skipped; single frame passes through', () {
      final r = mergeFrames([scene(80, 60), scene(60, 80)]);
      expect(r.used, 1);
      expect(r.image.width, 80);
    });
  });
}
