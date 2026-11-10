import 'package:ai_camera/services/macro.dart';
import 'package:ai_camera/services/mode_prompts.dart';
import 'package:ai_camera/widgets/macro_chips.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> _labels(WidgetTester t) => t
    .widgetList<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('macro_chips')),
        matching: find.byType(Text),
      ),
    )
    .map((w) => w.data!)
    .toList();

void main() {
  test('levels: Macro ≤5 · Close 6 · Micro 12 · Extreme 21 · Ultra 30', () {
    expect(macroLevelFor(1.5), MacroLevel.macro);
    expect(macroLevelFor(5), MacroLevel.macro);
    expect(macroLevelFor(6), MacroLevel.close);
    expect(macroLevelFor(12), MacroLevel.microscope);
    expect(macroLevelFor(21), MacroLevel.extreme);
    expect(macroLevelFor(30), MacroLevel.ultra);
    // in between → nearest band
    expect(macroLevelFor(8), MacroLevel.close);
    expect(macroLevelFor(10), MacroLevel.microscope);
    expect(macroLevelFor(18), MacroLevel.extreme);
    expect(macroLevelFor(27), MacroLevel.ultra);
    expect(MacroLevel.ultra.id, 'ultra');
    expect(MacroLevel.ultra.isDeep && MacroLevel.extreme.isDeep, isTrue);
    expect(MacroLevel.microscope.isDeep, isFalse);
  });

  test('chips: 1x 1.5x → 2x → 3x → 4x → 5x → level chips only', () {
    expect(visibleMacroChips(0), [1.0, 1.5]);
    expect(visibleMacroChips(4), [1.0, 1.5, 2.0, 3.0, 4.0, 5.0]);
    expect(visibleMacroChips(5), [
      1.0,
      1.5,
      2.0,
      3.0,
      4.0,
      5.0,
      6.0,
      12.0,
      21.0,
      30.0,
    ]);
    var st = 0;
    for (final z in [1.5, 2.0, 3.0, 4.0, 5.0]) {
      st = macroStageAfter(st, z);
    }
    expect(st, 5);
    expect(macroStageAfter(2, 5.0), 2); // no skipping
  });

  testWidgets('chip labels rendered', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MacroChips(
            chips: visibleMacroChips(5),
            selected: 21,
            onSelected: (_) {},
          ),
        ),
      ),
    );
    expect(_labels(t), [
      '1x', '1.5x', '2x', '3x', '4x', '5x', //
      '6x Close', '12x Micro', '21x Extreme', '30x Ultra',
    ]);
  });

  test('clear photos only past the 5x step', () {
    expect(
      wantClearPhoto(stage: 4, chip: 6, cam: 6, stopped: false, fourXCam: 4),
      isFalse,
    );
    expect(
      wantClearPhoto(stage: 5, chip: 6, cam: 6, stopped: false, fourXCam: 4),
      isTrue,
    );
    expect(
      macroFlowGuide(chip: 4, stage: 3, detecting: false),
      'Focus… now tap 5x',
    );
    expect(macroFlowGuide(chip: 5, stage: 5, detecting: false), kGuideDone);
  });

  test('Extreme / Ultra: spot only (not the broad subject)', () {
    expect(
      kMacroExtremePrompt,
      'A tiny area of {spot} under a light microscope at 1000x magnification, microscopic cells and structure filling the frame. One single full-frame image, no text or labels. Photorealistic.',
    );
    expect(
      kMacroUltraPrompt,
      'Close-up of {spot} under a scanning electron microscope at 2000x magnification. Show how it looks. One single full-frame image, no text or labels. Photorealistic.',
    );
    expect(
      macroPrompt(
        'human face',
        level: 'extreme',
        part: 'brown iris near pupil',
      ),
      'A tiny area of brown iris near pupil under a light microscope at 1000x magnification, microscopic cells and structure filling the frame. One single full-frame image, no text or labels. Photorealistic.',
    );
    expect(
      macroPrompt('white styrofoam', level: 'ultra'),
      'Close-up of white styrofoam under a scanning electron microscope at 2000x magnification. Show how it looks. One single full-frame image, no text or labels. Photorealistic.',
    );
    expect(
      macroPrompt(null, level: 'extreme'),
      'A tiny area of this under a light microscope at 1000x magnification, microscopic cells and structure filling the frame. One single full-frame image, no text or labels. Photorealistic.',
    );
  });

  test('Microscope 400x; detection prompts ask for colour', () {
    expect(kMacroMicroscopePhotoPrompt, contains('brightfield microscope'));
    expect(kDetectSubjectPrompt, contains('brown human eye, white styrofoam'));
    expect(kDetectPartPrompt, contains('colour + what is in the box'));
    expect(kDetectSpotPrompt, contains('Include its colour'));
  });
}
