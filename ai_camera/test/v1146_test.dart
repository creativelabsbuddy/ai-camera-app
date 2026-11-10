import 'dart:io';

import 'package:ai_camera/services/macro.dart';
import 'package:ai_camera/services/macro_box.dart';
import 'package:ai_camera/services/mode_prompts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final home = File('lib/screens/home_camera_screen.dart').readAsStringSync();

  test('v11.46 version', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('version: 1.11.'));
  });

  test('step zooms strictly below Z, lowest first', () {
    expect(macroContextZooms(1), isEmpty);
    expect(macroContextZooms(2), isEmpty); // Z <= 2x: final only
    expect(macroContextZooms(3), [2]);
    expect(macroContextZooms(5), [2]);
    expect(macroContextZooms(7), [2, 5]);
    expect(macroContextZooms(10), [2, 5]);
    expect(macroContextZooms(15), [2, 5, 10]);
  });

  test('progress hint in English', () {
    expect(macroStepHint([2, 5]), 'Capturing 2x… 5x… final');
    expect(macroStepHint([2]), 'Capturing 2x… final');
  });

  test('all five levels take step photos; failed step skipped', () {
    expect(home, contains('if (_macroLevel != null) {'));
    expect(home, contains('continue; // v11.46'));
    expect(home, contains('macroStepHint(steps)'));
  });

  test(
    'level start zoom rises: Macro < Close < Microscope < Extreme < Ultra',
    () {
      final z = [for (final l in MacroLevel.values) macroLevelStartZoom(l, 30)];
      expect(z, [2, 3, 4, 6, 8]);
      expect(
        home,
        isNot(contains('macroLevelStartZoom(level, _range.hardwareMax)')),
      ); // v11.49
    },
  );

  test('macro prompt lighter than microscope, general, context line', () {
    expect(kMacroPrompt, contains('less intense than a microscope'));
    expect(kMacroPrompt, contains('do not add any new objects'));
    expect(kMacroPrompt, isNot(contains('strongly')));
    expect(kMacroMicroscopePhotoPrompt, startsWith('Based on the last photo'));
    expect(kMacroContextLine, contains('last image is the final frame'));
  });
}
