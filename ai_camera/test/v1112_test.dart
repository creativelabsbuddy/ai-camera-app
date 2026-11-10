import 'dart:io';

import 'package:ai_camera/models/quality_tier.dart';
import 'package:ai_camera/services/mode_prompts.dart';
import 'package:ai_camera/services/openrouter_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('one image call: step photos first, then the crop', () {
    final p = buildImagesPayload(
      prompt: kMacroPrompt,
      tier: QualityTier.fullHd,
      aspectRatio: '4:3',
      imageDataUrl: 'data:crop',
      leadingDataUrls: const ['data:2x', 'data:3x', 'data:4x'],
    );
    final refs = [
      for (final r in p['input_references'] as List) r['image_url']['url'],
    ];
    expect(refs, ['data:2x', 'data:3x', 'data:4x', 'data:crop']);
    expect(p['model'], 'openai/gpt-image-2.5-flare');
  });

  test('no describe step left in the app', () {
    final src = File('lib/services/openrouter_client.dart').readAsStringSync();
    expect(src, isNot(contains('describeSpot')));
    expect(src, isNot(contains('chat/completions')));
    expect(
      File('lib/config/ai_config.dart').readAsStringSync(),
      isNot(contains('gemini')),
    );
  });
}
