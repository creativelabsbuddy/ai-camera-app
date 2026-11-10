import 'dart:io';

import 'package:ai_camera/models/quality_tier.dart';
import 'package:ai_camera/services/context_snapshot.dart';
import 'package:ai_camera/services/mode_prompts.dart';
import 'package:ai_camera/services/prompt_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('v11.39 version', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('version: 1.11.'));
  });

  test('picker has no 4K; old 4K pick maps to Ultra HD; 2K locked', () {
    expect(QualityTier.picker, isNot(contains(QualityTier.k4)));
    expect(QualityTier.pickable('4k'), QualityTier.ultraHd);
    final w = File('lib/widgets/quality_sheet.dart').readAsStringSync();
    expect(w, contains('tier_2k_coming_soon'));
  });

  test('short general prompts, no subject, no RGB subpixels', () {
    for (final t in [
      kMacroPrompt,
      kMacroClosePrompt,
      kMacroMicroscopePhotoPrompt,
    ]) {
      expect(t, isNot(contains('{subject}')));
      expect(t.toLowerCase(), isNot(contains('subpixel')));
      expect(t.length, lessThan(500));
    }
    expect(kMacroMicroscopePhotoPrompt, contains('brightfield'));
    expect(kZoomCleanPrompt, isNot(contains('strongly reduce')));
    expect(kLockedEnhancePrompt, contains('nothing added'));
  });

  test('cheap-phone merge from 2x', () {
    expect(shouldMergeZoom(lowEnd: true, zoom: 2, opticalLimit: 1), isTrue);
    expect(shouldMergeZoom(lowEnd: false, zoom: 10, opticalLimit: 1), isFalse);
  });

  test('colour gain capped; latch released; centre AF on zoom', () {
    expect(
      File('lib/services/color_match.dart').readAsStringSync(),
      contains('softenChroma'),
    );
    final h = File('lib/screens/home_camera_screen.dart').readAsStringSync();
    expect(h, contains('_scheduleZoomAf'));
    expect(h, contains('_zoomAfTimer?.cancel()'));
  });
}
