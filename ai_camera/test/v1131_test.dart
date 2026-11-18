import 'dart:io';
import 'dart:math' as math;

import 'package:ai_camera/models/quality_tier.dart';
import 'package:ai_camera/services/ai_call.dart';
import 'package:ai_camera/services/image_guard.dart';
import 'package:ai_camera/services/openrouter_client.dart';
import 'package:ai_camera/services/prompt_builder.dart';
import 'package:ai_camera/services/zoom_ladder.dart';
import 'package:flutter_test/flutter_test.dart';

/// Grey proxy of a synthetic scene seen at [zoom] (centre crop).
List<double> view(int w, int h, double zoom, {int dx = 0}) => [
  for (var y = 0; y < h; y++)
    for (var x = 0; x < w; x++)
      () {
        final sx = (x - w / 2 + dx) / zoom, sy = (y - h / 2) / zoom;
        return 128 +
            60 * math.sin(sx / 3) * math.cos(sy / 4) +
            ((sx ~/ 6 + sy ~/ 6).isEven ? 40.0 : -40.0);
      }(),
];

void main() {
  test('framing: same view passes (shift ok), wide reference view fails', () {
    const w = 48, h = 36;
    final fin = view(w, h, 4);
    expect(framingSimilarity(fin, fin, w, h), greaterThan(0.95));
    expect(
      framingSimilarity(fin, view(w, h, 4, dx: 2), w, h),
      greaterThanOrEqualTo(kFramingMin),
    );
    expect(framingSimilarity(fin, view(w, h, 1), w, h), lessThan(kFramingMin));
  });

  test('final photo first, reference crops after', () {
    final p = buildImagesPayload(
      prompt: 'x',
      tier: QualityTier.hd,
      aspectRatio: '1:1',
      imageDataUrl: 'data:final',
      trailingDataUrls: const ['data:r1', 'data:r2'],
    );
    final urls = [
      for (final r in p['input_references'] as List)
        ((r as Map)['image_url'] as Map)['url'],
    ];
    expect(urls, ['data:final', 'data:r1', 'data:r2']);
  });

  test('prompt, message, sizes', () {
    expect(kZoomLadderPrompt.startsWith(kZoomCleanPrompt), isTrue);
    expect(kZoomLadderPrompt, isNot(contains('box')));
    expect(
      aiFailureMessage(AiFailureKind.framingChanged),
      "Couldn't enhance this zoom — credit refunded",
    );
    expect(
      ladderSizesText((4000, 3000), [(1000, 750), (500, 375)]),
      'sizes 1536x1152 (final) + 768x576, 500x375',
    );
    expect(ladderSizesText((1200, 900), []), 'sizes 1200x900 (final)');
  });

  test('wiring: crop-only refs, framing check before charge', () {
    final h = File('lib/screens/home_camera_screen.dart').readAsStringSync();
    expect(
      h,
      contains(
        'stepCropMargin: macroCtx.isNotEmpty', // v11.42
      ), // v11.40,
    );
    final e = File('lib/services/enhance_service.dart').readAsStringSync();
    expect(
      e.indexOf('framingCheck('),
      lessThan(e.indexOf('await _account.commitLocal(spec);')),
    );
  });
}
