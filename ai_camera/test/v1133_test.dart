import 'dart:io';
import 'dart:typed_data';

import 'package:ai_camera/models/quality_tier.dart';
import 'package:ai_camera/services/frame_stats.dart';
import 'package:ai_camera/services/macro.dart';
import 'package:ai_camera/services/macro_box.dart';
import 'package:ai_camera/services/mode_prompts.dart';
import 'package:ai_camera/widgets/macro_level_chips.dart';
import 'package:ai_camera/widgets/quality_sheet.dart';
import 'package:ai_camera/widgets/credit_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 48x64 grey thumb: flat background [bg], centre box filled with
/// [fg] over [frac] of its width (checkered texture when [texture]).
Uint8List thumb({int bg = 120, int fg = 200, double frac = 1}) {
  const w = kThumbW, h = kThumbH;
  final t = Uint8List(w * h)..fillRange(0, w * h, bg);
  final x0 = w ~/ 4, y0 = h ~/ 4;
  final bw = (w ~/ 2 * frac).round();
  for (var y = y0; y < y0 + h ~/ 2; y++) {
    for (var x = x0; x < x0 + bw; x++) {
      t[y * w + x] = fg;
    }
  }
  return t;
}

FrameStats stats(Uint8List t, {double sharp = 50}) => FrameStats(
  luma: 0.5,
  sharpness: sharp,
  detail: 0,
  thumb: t,
  thumbWidth: kThumbW,
  thumbHeight: kThumbH,
);

void main() {
  group('credits by quality (config)', () {
    test('HD / Full HD / 2K tables', () {
      String row(String q) => MacroLevel.values
          .map((l) => macroCreditsFor(l.id, quality: q))
          .join(',');
      expect(row('hd'), '4,4,5,2,2');
      expect(row('full_hd'), '5,5,6,3,3');
      expect(row('2k'), '13,13,14,10,10');
      expect(kMacroLockedQualities, {'2k'});
      expect(kMacroQualities.map((q) => q.$3), ['low', 'medium', 'high']);
      expect(QualityTier.hd.flareQuality, 'low');
      expect(QualityTier.fullHd.flareQuality, 'medium');
      expect(kMacroCredits.containsKey('4k'), isFalse);
    });
    test('retry + labels follow the quality', () {
      expect(
        macroRetryCredits(MacroLevel.microscope, 2, quality: 'full_hd'),
        6,
      );
      expect(
        macroLevelCostLabel('Close Macro', 'close', quality: 'hd'),
        'Close Macro · 🪙4',
      );
    });
  });

  group('zoom', () {
    test('level range 1x–10x clamped to the device', () {
      // v11.40: 1x–5x, manual zoom (a chip keeps the user's zoom).
      expect(macroLevelMaxZoom(30), 10);
      expect(macroLevelMaxZoom(4), 4);
      expect(macroLevelPickZoom(1, 30), 1);
      expect(macroLevelPickZoom(12, 30), 10);
    });
    test('smooth path: ~1 s, eased, ends on target, no jump', () {
      final p = smoothZoomPath(1, 8);
      expect(p.length, 20);
      expect(p.last, 8);
      var prev = 1.0;
      for (final z in p) {
        expect(z - prev, lessThan(1.0));
        expect(z, greaterThanOrEqualTo(prev));
        prev = z;
      }
    });
  });

  group('box check', () {
    test('fill: full box vs small subject vs empty', () {
      expect(boxFill(thumb(), kThumbW, kThumbH), greaterThan(0.9));
      expect(boxFill(thumb(frac: 0.3), kThumbW, kThumbH), lessThan(0.5));
      expect(boxFill(thumb(fg: 120), kThumbW, kThumbH), 0);
    });
    test('v11.40 soft hints: tap to focus / put in box / hold steady', () {
      expect(
        macroBoxGuideFor(fill: 0.9, sharpness: 5),
        MacroBoxGuide.tapToFocus,
      );
      expect(
        macroBoxGuideFor(fill: 0.15, sharpness: 50),
        MacroBoxGuide.putInBox,
      );
      // Smooth even view (skin filling the frame) is fine.
      expect(
        macroBoxGuideFor(fill: 0, sharpness: 50),
        MacroBoxGuide.holdSteady,
      );
      expect(
        macroBoxGuideFor(fill: 0.9, sharpness: 50),
        MacroBoxGuide.holdSteady,
      );
      for (final g in MacroBoxGuide.values) {
        expect(g.text, isNot(contains('closer')));
        expect(g.text, isNot(contains('Zoom in')));
      }
    });
    test('2-frame hysteresis', () {
      final c = MacroBoxCheck();
      expect(c.ready, isTrue);
      expect(c.update(stats(thumb(), sharp: 2)), isFalse);
      expect(c.update(stats(thumb(), sharp: 2)), isTrue);
      expect(c.guide, MacroBoxGuide.tapToFocus);
      c.reset();
      expect(c.ready, isTrue);
    });
  });

  group('prompts', () {
    test('levels use the description; depth rises', () {
      expect(
        macroPrompt('brown eye, iris and eyelashes', level: 'macro'),
        kMacroPrompt, // v11.39: general, no subject
      );
      expect(kMacroPrompt, contains('macro photograph'));
      expect(kMacroClosePrompt, contains('same framing')); // v11.42
      expect(kMacroMicroscopePhotoPrompt, contains('brightfield microscope'));
      expect(kMacroMicroscopePhotoPrompt, contains('centre of the frame'));
      expect(kMacroExtremePrompt, contains('1000x magnification'));
      expect(macroInputPlan('microscope').maxSteps, 1);
      expect(macroInputPlan('extreme').maxSteps, 2); // v11.40
    });
    test('box detection prompt + reply', () {
      expect(kDetectBoxPrompt, contains('common name'));
      expect(kDetectBoxPrompt, contains('not its colour'));
      expect(
        parseBoxReply(
          '{"part": "brown eye, iris and eyelashes", "clear": true}',
        ),
        ('brown eye, iris and eyelashes', true),
      );
      expect(parseBoxReply('{"part": "x", "clear": false}').$2, isFalse);
      expect(parseBoxReply('').$2, isFalse);
    });
  });

  testWidgets('chips show 1x + 5 levels with credits', (t) async {
    MacroLevel? picked = MacroLevel.macro;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MacroLevelChips(
            selected: null,
            quality: 'full_hd',
            onSelected: (l) => picked = l,
          ),
        ),
      ),
    );
    expect(find.text('1x'), findsOneWidget);
    // v11.48: collapsed → the arrow opens the full list.
    await t.tap(find.byKey(const ValueKey('macro_level_arrow')));
    await t.pump();
    expect(find.byWidgetPredicate((w) => isCreditText(w, 'Microscope 🪙6')), findsOneWidget);
    expect(find.byWidgetPredicate((w) => isCreditText(w, 'Ultra 🪙3')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('macro_level_1x')));
    expect(picked, isNull);
  });

  testWidgets('quality sheet: 2K locked, Coming soon', (t) async {
    QualityTier? got = QualityTier.k4;
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) => TextButton(
            onPressed: () async =>
                got = await showMacroQualitySheet(c, QualityTier.fullHd),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.text('Coming soon'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => isCreditText(w, '🪙 13 / 13 / 14 / 10 / 10')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('macro_quality_2k')));
    await t.pumpAndSettle();
    expect(find.text('Coming soon'), findsOneWidget); // still open
    await t.tap(find.byKey(const ValueKey('macro_quality_hd')));
    await t.pumpAndSettle();
    expect(got, QualityTier.hd);
  });

  test('home wiring: no charge before the box is ready / detection', () {
    final h = File('lib/screens/home_camera_screen.dart').readAsStringSync();
    expect(h, isNot(contains('if (!_boxCheck.ready) {'))); // v11.40
    expect(h, isNot(contains('await _detectBoxArea('))); // v11.59 F6
    expect(h, contains('MacroLevelChips('));
    expect(h, contains("ValueKey('macro_box')"));
    expect(h, isNot(contains('DriftPopup(')));
    expect(h, isNot(contains('_SubjectPicker')));
    // closing the result → 1x, burst + merge kept.
    expect(h, contains('_freshMacroStart()'));
    expect(h, contains('_burstSharpest(c, n, crop, merge: lowEnd)'));
    final e = File('lib/services/enhance_service.dart').readAsStringSync();
    expect(e, contains('macroCreditsFor(macroLevel, quality: tier.id)'));
  });
}
