import 'dart:io';

import 'package:ai_camera/services/macro.dart';
import 'package:ai_camera/services/mode_prompts.dart';
import 'package:flutter_test/flutter_test.dart';

// v11.58: material-aware texts (no hardcoded cells).
final ext = kMacroExtremePrompt;
final ult = kMacroUltraPrompt;

void main() {
  test('Extreme / Ultra prompts (app defaults)', () {
    expect(ext, contains('1000x magnification'));
    expect(ult, contains('2000x magnification'));
    expect(ext.toLowerCase(), isNot(contains('cells')));
  });

  test('spot filled; capital only at the sentence start', () {
    expect(
      macroPrompt('eye', level: 'ultra', part: 'brown human eye brown iris'),
      startsWith('Close-up of brown human eye brown iris under a scanning'), // part names the eye
    );
    expect(
      macroPrompt('eye', level: 'extreme', part: 'brown iris'),
      startsWith('A tiny area of brown iris on the eye under a light microscope at 1000x'), // v11.58
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
