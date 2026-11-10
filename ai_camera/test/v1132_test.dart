import 'dart:io';

import 'package:ai_camera/services/macro.dart';
import 'package:ai_camera/services/macro_fill.dart';
import 'package:ai_camera/services/mode_prompts.dart';
import 'package:ai_camera/widgets/macro_chips.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('part / spot prompts describe the box, not one forced part', () {
    for (final p in [kDetectPartPrompt, kDetectSpotPrompt]) {
      expect(
        p,
        contains('the whole object if all of it is visible (e.g. eye)'),
      );
      expect(p, contains('eye, iris and eyelashes'));
      expect(p, contains('one part only if that part alone fills the box'));
      expect(p, isNot(contains('never just the object')));
    }
    expect(kDetectPartPrompt, contains('"fill"'));
    expect(kDetectSubjectPrompt, contains('"whole"'));
  });

  test('fill parsing', () {
    final f = FrameFill.parse('x {"part": "eye", "fill": 0.6, "whole": true}');
    expect(f!.fill, 0.6);
    expect(f.whole, isTrue);
    expect(FrameFill.parse('{"fill": 3}')!.fill, 1.0);
    expect(FrameFill.parse('plain'), isNull);
    expect(FrameFill.fromJson({'fill': null, 'whole': null}), isNull);
  });

  test('levels unlock by frame fill', () {
    const small = FrameFill(fill: 0.2, whole: true);
    const half = FrameFill(fill: 0.5, whole: true);
    const full = FrameFill(fill: 0.95, whole: true);
    const part = FrameFill(fill: 1, whole: false);
    expect(macroLevelUnlocked(MacroLevel.macro, small), isFalse);
    expect(macroLevelUnlocked(MacroLevel.macro, half), isTrue);
    expect(macroLevelUnlocked(MacroLevel.close, half), isFalse);
    expect(macroLevelUnlocked(MacroLevel.close, full), isTrue);
    expect(macroLevelUnlocked(MacroLevel.microscope, full), isFalse);
    for (final l in [
      MacroLevel.microscope,
      MacroLevel.extreme,
      MacroLevel.ultra,
    ]) {
      expect(macroLevelUnlocked(l, part), isTrue);
    }
    expect(macroChipLocked(1.5, small), isFalse);
    expect(macroChipLocked(3, small), isTrue);
    expect(macroChipLocked(12, null), isFalse); // unknown never blocks
  });

  test('auto lock + move closer checks', () {
    bool go(double chip, {bool locked = false, Set<double>? tried}) =>
        shouldAutoLock(
          chip: chip,
          locked: locked,
          busy: false,
          tried: tried ?? {},
          sharpness: 60,
          detail: 8,
        );
    expect(go(1.5), isFalse); // 1.5x keeps its own tap flow
    expect(go(3), isTrue);
    expect(go(3, locked: true), isFalse);
    expect(go(3, tried: {3.0}), isFalse);
    expect(
      shouldAutoLock(
        chip: 5,
        locked: false,
        busy: false,
        tried: {},
        sharpness: 10,
        detail: 8,
      ),
      isFalse,
    );
    expect(showMoveCloser(chip: 8, maxUseful: 8, sharpness: 5), isTrue);
    expect(showMoveCloser(chip: 4, maxUseful: 8, sharpness: 5), isFalse);
    expect(kGuideZoomInSubject, 'Zoom in on your subject');
    expect(kGuideMoveCloser, 'Move a little closer');
  });

  test('debug text', () {
    expect(
      fillDebugText(const FrameFill(fill: 0.62, whole: true), 3),
      'fill 0.62 whole · lock 3x',
    );
    expect(fillDebugText(null, null), 'fill ? · no lock');
    expect(
      fillDebugText(const FrameFill(fill: 1, whole: false), 1.5),
      'fill 1.00 part · lock 1.5x',
    );
  });

  testWidgets('locked chips show a lock icon and still tap', (t) async {
    double? tapped;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MacroChips(
            chips: const [1.0, 1.5, 2.0, 12.0],
            selected: 1.0,
            locked: {2.0, 12.0},
            onSelected: (v) => tapped = v,
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('macro_chip_12_locked')), findsOneWidget);
    expect(find.byKey(const ValueKey('macro_chip_1.5_locked')), findsNothing);
    await t.tap(find.byKey(ValueKey(macroChipKey(12))));
    expect(tapped, 12);
  });

  test(
    'wiring: lock at any zoom, shutter guide, fill debug',
    () {
      final h = File('lib/screens/home_camera_screen.dart').readAsStringSync();
      expect(h, contains('unawaited(_autoLock(_macroChip));'));
      expect(h, contains('_snack(kGuideZoomInSubject);'));
      expect(h, contains('fillDebugText(_fill, _lockZoom)'));
      expect(
        h,
        contains('if (r.fill != null) setState(() => _fill = r.fill);'),
      );
      expect(h, contains('_driftReturn.waiting')); // drift rules kept
    },
    skip: 'v11.33: replaced by level chips + box check',
  );
}
