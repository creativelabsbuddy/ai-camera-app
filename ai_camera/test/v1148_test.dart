import 'dart:io';

import 'package:ai_camera/models/camera_options.dart';
import 'package:ai_camera/models/capture_mode.dart';
import 'package:ai_camera/models/shoot_mode.dart';
import 'package:ai_camera/services/hdr_merge.dart';
import 'package:ai_camera/services/macro.dart';
import 'package:ai_camera/services/night_pipeline.dart';
import 'package:ai_camera/services/prompt_builder.dart';
import 'package:ai_camera/widgets/macro_level_chips.dart';
import 'package:ai_camera/widgets/top_flash_button.dart';
import 'package:ai_camera/services/zoom_chips.dart';
import 'package:ai_camera/widgets/zoom_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

img.Image _tex(int w, int h, {int dx = 0, int add = 0}) {
  final im = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = ((((x + dx) ~/ 6) + (y ~/ 6)).isEven ? 60 : 190) + add;
      im.setPixelRgb(x, y, v.clamp(0, 255), v.clamp(0, 255), v.clamp(0, 255));
    }
  }
  return im;
}

void main() {
  final home = File('lib/screens/home_camera_screen.dart').readAsStringSync();

  test('v11.48 version', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('version: 1.11.'));
  });

  test('1: night prompt is general', () {
    expect(kNightPrompt, startsWith('A natural night photograph'));
    for (final w in ['sky', 'city', 'street', 'lamp']) {
      expect(kNightPrompt.toLowerCase(), isNot(contains(w)));
    }
  });

  test('4: Pro Night ~4 frames, Normal unchanged', () {
    expect(planNight(luma: 0.03, mode: CaptureMode.pro).frames, 4);
    expect(planNight(luma: 0.03, mode: CaptureMode.normal).frames, 15);
    expect(planNight(luma: 0.3, mode: CaptureMode.normal).frames, 8);
  });

  test('5/6: Normal has no Macro, Pro AI has no HDR bracket', () {
    expect(ShootMode.stripFor(aiMode: false), isNot(contains(ShootMode.macro)));
    expect(ShootMode.stripFor(aiMode: false), isNot(contains(ShootMode.hdr)));
    expect(ShootMode.stripFor(aiMode: true), contains(ShootMode.macro));
    expect(ShootMode.stripFor(aiMode: true), isNot(contains(ShootMode.hdr)));
    expect(routeFor(ShootMode.hdr, aiMode: true).capture, CaptureKind.single);
    expect(routeFor(ShootMode.hdr).capture, CaptureKind.single);
  });

  test('2: night merge rejects ghost pixels; misaligned → reference', () {
    final ref = _tex(96, 96);
    final ghost = _tex(96, 96);
    for (var y = 40; y < 56; y++) {
      for (var x = 40; x < 56; x++) {
        ghost.setPixelRgb(x, y, 255, 0, 0);
      }
    }
    final r = mergeFrames([ref, ghost, _tex(96, 96)]);
    final p = r.image.getPixel(48, 48);
    expect((p.r - p.b).abs(), lessThan(10)); // red block left out
    expect(kMergeGhostTol, 48);
  });

  test('2/3: HDR keeps the reference share, drops bad frames', () {
    final ref = _tex(64, 64);
    final noise = img.Image(width: 64, height: 64);
    var s = 7;
    for (var y = 0; y < 64; y++) {
      for (var x = 0; x < 64; x++) {
        s = (s * 1103515245 + 12345) & 0x7fffffff;
        final v = s % 256;
        noise.setPixelRgb(x, y, v, v, v);
      }
    }
    final r = mergeHdr([ref, noise]);
    expect(r.used, 1);
    expect(kHdrRefShare, greaterThan(0));
    expect(kHdrBlurDiv, greaterThan(96 / 4 - 1));
    final ok = mergeHdr([ref, _tex(64, 64, add: 30)]);
    expect(ok.used, 2);
  });

  testWidgets('7: level chips collapsed → arrow expands, pick collapses', (
    t,
  ) async {
    MacroLevel? picked;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MacroLevelChips(
            selected: MacroLevel.close,
            quality: 'hd',
            onSelected: (l) => picked = l,
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('macro_level_close')), findsOneWidget);
    expect(find.byKey(const ValueKey('macro_level_ultra')), findsNothing);
    await t.tap(find.byKey(const ValueKey('macro_level_arrow')));
    await t.pump();
    expect(find.byKey(const ValueKey('macro_level_ultra')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('macro_level_ultra')));
    await t.pump();
    expect(picked, MacroLevel.ultra);
    expect(find.byKey(const ValueKey('macro_level_1x')), findsNothing);
  });

  test('8 (v11.50): four-dot menu hidden only in Macro', () {
    expect(
      home,
      contains('showMenu: quickMenuVisible(aiMode: _aiMode, mode: _shootMode)'),
    );
    expect(home, contains('_menuOpen && quickMenuVisible('));
    expect(home, contains('QualityTier _macroTier = QualityTier.hd'));
    expect(
      home,
      contains('premium: _macroActive ? PremiumFilter.original : _premium'),
    );
  });

  testWidgets('8: ZoomPill shows the four-dot button unless showMenu=false', (
    t,
  ) async {
    Future<void> pump(bool show) => t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ZoomPill(
            chips: ZoomChipSet.single,
            zoom: 1,
            onSelected: (_) {},
            onOpenMenu: () {},
            showMenu: show,
          ),
        ),
      ),
    );
    await pump(true);
    expect(find.byKey(const ValueKey('quick_menu_open')), findsOneWidget);
    await pump(false);
    expect(find.byKey(const ValueKey('quick_menu_open')), findsNothing);
  });

  testWidgets('9: top Flash button cycles Off / Auto / On', (t) async {
    var taps = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TopFlashButton(flash: FlashChoice.auto, onTap: () => taps++),
        ),
      ),
    );
    expect(find.text('Auto'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('top_flash')));
    expect(taps, 1);
    expect(FlashChoice.off.next, FlashChoice.auto);
    expect(home, contains('TopFlashButton('));
    expect(home, contains('if (_torchOn) {'));
  });
}
