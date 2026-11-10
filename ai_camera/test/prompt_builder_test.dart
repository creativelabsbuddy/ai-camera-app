import 'package:ai_camera/models/quality_tier.dart';
import 'package:ai_camera/services/prompt_builder.dart';
import 'package:flutter_test/flutter_test.dart';

/// Verbatim copy of the v6 locked prompt — must never change.
const v6Locked =
    'Enhance this real photo only. Keep the exact same framing, crop, '
    'geometry, and aspect ratio — no stretch, no reframe. Preserve every '
    'person’s identity and face exactly, including small/distant/background '
    'faces; do not invent, morph, smear, or replace faces. Keep natural '
    'colors and skin texture — no oversaturation, no plastic/airbrushed look, '
    'no cartoon or painted style. Improve only: mild sharpness, noise '
    'reduction, and balanced lighting. Also upscale for cleaner higher '
    'resolution where the model allows, without changing composition. Do not '
    'change clothes, background layout, or objects.';

void main() {
  test('locked prompt unchanged and always first', () {
    expect(
      kLockedEnhancePrompt,
      startsWith('Enhance this real photo and keep it the same photo'),
    ); // v11.39
    final v6Locked = kLockedEnhancePrompt;
    expect(buildEnhancePrompt(), v6Locked);
    expect(
      buildEnhancePrompt(
        hasContextImage: true,
        zoom: 30,
        opticalLimit: 5,
        tier: QualityTier.k4,
        stylePrompt: 'warm',
        customPrompt: 'blue sky',
      ),
      startsWith(v6Locked),
    );
  });

  test('context sentence exactly as specified', () {
    final p = buildEnhancePrompt(hasContextImage: true);
    expect(
      p,
      contains(
        'Use the second image only to understand the scene; enhance and '
        'upscale only the first image, do not invent new content.',
      ),
    );
    expect(buildEnhancePrompt(), isNot(contains('second image')));
  });

  test('zoom emphasis scales with zoom / optical', () {
    expect(zoomEmphasisLevel(1.0), 0);
    expect(zoomEmphasisLevel(1.04), 0);
    expect(zoomEmphasisLevel(2.0), 1);
    expect(zoomEmphasisLevel(3.0), 2);
    expect(zoomEmphasisLevel(20), 3);
    expect(zoomSentence(zoom: 5, opticalLimit: 5), isEmpty);
    expect(zoomSentence(zoom: 8, opticalLimit: 5), contains('gently'));
    expect(zoomSentence(zoom: 15, opticalLimit: 5), contains('carefully'));
    expect(zoomSentence(zoom: 100, opticalLimit: 5), contains('heavy 100x'));
  });

  test('custom prompt sanitized and length-capped', () {
    final long = 'a ' * 400;
    final p = buildEnhancePrompt(customPrompt: '  make\n\nit   warm  ');
    expect(p, endsWith('intact): make it warm'));
    expect(sanitizeCustomPrompt(long).length, 200);
  });
}
