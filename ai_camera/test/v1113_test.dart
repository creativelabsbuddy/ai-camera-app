import 'dart:ui';

import 'package:ai_camera/services/capture_crop.dart';
import 'package:ai_camera/services/live_policies.dart';
import 'package:ai_camera/services/macro.dart';
import 'package:ai_camera/services/scene_suggest.dart';
import 'package:ai_camera/services/mode_prompts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('prompts: prefix + level + suffix + live hint line', () {
    // v11.33: simple prompts with {subject} (the box description).
    for (final t in [
      kMacroPrompt,
      kMacroClosePrompt,
      kMacroMicroscopePhotoPrompt,
    ]) {
      expect(t, isNot(contains('{subject}'))); // v11.39
      expect(t.endsWith('Photorealistic.'), isTrue);
    }
    expect(kMacroExtremePrompt, contains('1000x magnification'));
    expect(
      macroPrompt('Eye', level: 'microscope', zoom: 15),
      kMacroMicroscopePhotoPrompt.replaceAll('{subject}', 'eye'),
    );
    expect(
      macroPrompt(null, level: 'macro', zoom: 5),
      kMacroPrompt.replaceAll('{subject}', fallbackDescription(null)),
    );
  });

  // 'subject change: sustained diff past 4x, debounced' superseded by v1123_test (new drift metric).
  test('eye label: eye words win; eye region is wider', () {
    expect(
      eyeFromLabels(const [
        SceneLabel('Skin', 0.9),
        SceneLabel('Eyelash', 0.5),
      ]),
      'Eye',
    );
    expect(eyeFromLabels(const [SceneLabel('Eye', 0.2)]), isNull);
    const face = LiveFace(box: Rect.fromLTWH(0, 0, 1, 1));
    // Lid area off the eye centre (0.32, 0.40) → still Eye (was Skin).
    expect(facePartAt(const Offset(0.45, 0.46), face), 'Eye');
  });

  test('extreme spot: centre third window', () {
    final r = extremeSpotRect(List<double>.filled(300 * 300, 128), 300, 300);
    expect(r.width, 100);
    expect(r.x, inInclusiveRange(90, 110));
  });
}
