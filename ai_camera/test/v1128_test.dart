import 'dart:io';

import 'package:ai_camera/services/macro.dart';
import 'package:ai_camera/services/mode_prompts.dart';
import 'package:flutter_test/flutter_test.dart';

const ext =
    'A tiny area of {spot} under a light microscope at 1000x magnification, microscopic cells and structure filling the frame. One single full-frame image, no text or labels. Photorealistic.';
const ult =
    'Close-up of {spot} under a scanning electron microscope at 2000x magnification. Show how it looks. One single full-frame image, no text or labels. Photorealistic.';

void main() {
  test('Extreme / Ultra prompts (app defaults)', () {
    expect(kMacroExtremePrompt, ext);
    expect(kMacroUltraPrompt, ult);
  });

  test('spot filled; capital only at the sentence start', () {
    expect(
      macroPrompt('eye', level: 'ultra', part: 'brown human eye brown iris'),
      startsWith('Close-up of brown human eye brown iris under a scanning'),
    );
    expect(
      macroPrompt('eye', level: 'extreme', part: 'brown iris'),
      startsWith('A tiny area of brown iris under a light microscope at 1000x'),
    );
  });

  test('level-sent labels', () {
    expect(
      macroLevelSentLabel(MacroLevel.extreme),
      'Level sent: Extreme Microscope (1000x light)',
    );
    expect(
      macroLevelSentLabel(MacroLevel.ultra),
      'Level sent: Ultra Electron Microscope',
    );
  });

  test('inputs unchanged: crop only for both', () {
    expect(macroInputPlan('extreme').maxSteps, 2);
    expect(macroInputPlan('ultra').maxSteps, 2);
    expect(macroInputPlan('extreme').cropLong, isNull);
  });

  test('no 5000x left anywhere in lib/', () {
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is File && f.path.endsWith('.dart')) {
        expect(
          f.readAsStringSync(),
          isNot(contains(RegExp(r'[^0-9]5000x'))),
          reason: f.path,
        );
      }
    }
  });
}
