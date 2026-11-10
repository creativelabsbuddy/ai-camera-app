import 'dart:io';

import 'package:ai_camera/services/color_match.dart';
import 'package:ai_camera/services/macro_box.dart';
import 'package:ai_camera/services/mode_prompts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('v11.41 version', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('version: 1.11.'));
  });

  test('macro zoom 1x–10x, chips within the device max', () {
    expect(macroLevelMaxZoom(30), 10);
    expect(macroLevelMaxZoom(8), 8);
    expect(macroZoomChips(30), [1, 2, 3, 5, 10]);
    expect(macroZoomChips(8), [1, 2, 3, 5]);
  });

  test('general no-tint line, nothing test-photo specific', () {
    expect(
      kMacroMicroscopePhotoPrompt,
      contains('do not let the background colour tint the subject'),
    );
    for (final t in [
      kMacroPrompt,
      kMacroClosePrompt,
      kMacroMicroscopePhotoPrompt,
    ]) {
      expect(t, contains("subject's own natural colours")); // v11.42
      for (final w in ['peanut', 'purple', 'cloth']) {
        expect(t.toLowerCase(), isNot(contains(w)));
      }
    }
  });

  test('regional colour shift capped', () {
    expect(kRegionMaxShift, 10);
  });
}
