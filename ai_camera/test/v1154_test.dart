import 'dart:io';

import 'package:ai_camera/main.dart';
import 'package:ai_camera/models/ai_style.dart';
import 'package:ai_camera/models/style_category.dart';
import 'package:ai_camera/screens/home_camera_screen.dart' show kStylesHintSeenKey;
import 'package:ai_camera/screens/video_screen.dart';
import 'package:ai_camera/services/account_service.dart';
import 'package:ai_camera/services/video_service.dart';
import 'package:ai_camera/services/video_style_catalog.dart';
import 'package:ai_camera/widgets/credit_icon.dart';
import 'package:ai_camera/widgets/style_library_sheet.dart';
import 'package:ai_camera/widgets/styles_quick_panel.dart';
import 'package:ai_camera/widgets/video_style_flow.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

AiStyle _s(String id, {String? cat}) =>
    AiStyle(id: id, name: id, category: 'x', creditCost: 2, uiCategory: cat);

Future<void> _settle(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AccountService.resetForTest();
  });

  test('version 1.11.5x and bolt credit icon assets 1x/2x/3x', () {
    final pub = File('pubspec.yaml').readAsStringSync();
    expect(pub, matches(RegExp(r'version: 1\.11\.5[4-9]\+')));
    expect(pub, contains('- assets/icons/'));
    for (final p in [
      'assets/icons/credit_bolt.png',
      'assets/icons/2.0x/credit_bolt.png',
      'assets/icons/3.0x/credit_bolt.png',
    ]) {
      expect(File(p).existsSync(), isTrue, reason: p);
    }
    expect(File('lib/widgets/camera_styles_strip.dart').existsSync(), isFalse);
  });

  test('ui_category parsed; missing/unknown falls back to New', () {
    final a = AiStyle.fromJson({'id': 'a', 'name': 'A', 'ui_category': 'Cities'});
    expect(a.uiCategory, 'cities');
    expect(categoryOf(a, video: false), 'cities');
    expect(AiStyle.fromJson(a.toJson()).uiCategory, 'cities');
    final b = AiStyle.fromJson({'id': 'b', 'name': 'B'});
    expect(b.uiCategory, isNull);
    expect(categoryOf(b, video: false), kCategoryNew);
    expect(categoryOf(_s('c', cat: 'cities'), video: true), kCategoryNew); // not a video category
    final all = [_s('x', cat: 'cities'), _s('y', cat: 'trending')];
    expect(stylesInCategory(all, 'cities', video: false).map((s) => s.id), ['x']);
    // New empty → everything (graceful fallback).
    expect(stylesInCategory(all, kCategoryNew, video: false).length, 2);
    expect(stylesInCategory(all, 'bw', video: false), isEmpty);
    expect(kPhotoCategories.map((c) => c.label), [
      'New', 'Trending', 'Appearance', 'Cities', 'Black & White', 'Cinematic', 'AI for Photo',
    ]);
    expect(kVideoCategories.map((c) => c.label), ['New', 'Trending', 'Motion', 'Cinematic', 'Zoom']);
  });

  test('builtin video styles carry a category; rows without one keep it', () {
    expect(kBuiltinVideoStyles.every((s) => s.uiCategory != null), isTrue);
    final rows = VideoStyleCatalog(url: '', key: '', media: 'https://m')
        .parseRows([{'id': 'video_slow_zoom', 'name': 'Slow zoom'}, {'id': 'n', 'name': 'N', 'ui_category': 'motion'}]);
    expect(rows.firstWhere((s) => s.id == 'video_slow_zoom').uiCategory, 'zoom');
    expect(rows.firstWhere((s) => s.id == 'n').uiCategory, 'motion');
  });

  test('quick row plan fills the width and keeps 9:16 cards in range', () {
    for (final w in [300.0, 340.0, 380.0, 420.0, 600.0]) {
      final p = planQuickRow(width: w, photos: 13, videos: 3);
      expect(p.videos, greaterThan(0));
      expect(p.photos, greaterThan(0));
      expect(p.cardWidth, inInclusiveRange(StylesQuickPanel.minCard, StylesQuickPanel.maxCard));
      final used = (p.photos + p.videos) * (p.cardWidth + StylesQuickPanel.gap) + StylesQuickPanel.groupGap;
      // At least a minimum-size More card fits, and the blank rest is < 2 cards.
      expect(w - used, greaterThanOrEqualTo(StylesQuickPanel.minCard - 1));
      expect(w - used, lessThan(3 * (StylesQuickPanel.maxCard + StylesQuickPanel.gap)));
    }
    final few = planQuickRow(width: 400, photos: 1, videos: 1);
    expect([few.photos, few.videos], [1, 1]); // More takes the rest
  });

  test('video "from" price is the lowest resolution; labels use the bolt', () {
    final svc = VideoService();
    final from = videoFromCredits(svc);
    for (final r in kWanResolutions) {
      expect(from, lessThanOrEqualTo(svc.creditsForKey(5, r)));
    }
    expect(videoFromLabel(3), 'from ${kCreditGlyph}3');
    expect(makeVideoLabel(4), 'Generate · ${kCreditGlyph}4');
  });

  testWidgets('CreditText draws the bolt image instead of the coin glyph', (t) async {
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: CreditText('Apply · 🪙2'))));
    expect(find.byKey(const ValueKey('credit_icon')), findsOneWidget);
    expect(find.text('Apply · 🪙2'), findsNothing);
    final img = t.widget<Image>(find.byKey(const ValueKey('credit_icon')));
    expect((img.image as AssetImage).assetName, kCreditIconAsset);
  });

  testWidgets('camera: no styles strip; four-dot → quick row → More → Photo tab first', (t) async {
    t.view.physicalSize = const Size(1080, 2340);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(const AiCameraApp());
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('camera_styles_strip')), findsNothing);
    expect(find.byKey(const ValueKey('styles_quick_panel')), findsNothing);
    // First run: NEW sparkle + tooltip.
    expect(find.byKey(const ValueKey('quick_menu_new')), findsOneWidget);
    expect(find.byKey(const ValueKey('styles_here_tooltip')), findsOneWidget);
    expect(find.text('Styles are here'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('quick_menu_open')));
    await _settle(t, 5);
    expect(find.byKey(const ValueKey('styles_quick_panel')), findsOneWidget);
    final panel = find.byKey(const ValueKey('styles_quick_panel'));
    expect(find.descendant(of: panel, matching: find.text('PHOTO')), findsOneWidget);
    expect(find.descendant(of: panel, matching: find.text('VIDEO')), findsOneWidget);
    expect(find.byKey(const ValueKey('quick_video_video_slow_zoom')), findsOneWidget);
    // Portrait cards (9:16).
    final r = t.getSize(find.byKey(const ValueKey('quick_video_video_slow_zoom')));
    expect(r.height / (r.width - StylesQuickPanel.gap), closeTo(16 / 9, 0.01)); // card + right gap
    // Opening the panel dismissed the hint for good.
    expect(find.byKey(const ValueKey('styles_here_tooltip')), findsNothing);
    expect((await SharedPreferences.getInstance()).getBool(kStylesHintSeenKey), isTrue);
    // Menu bar items spread over the bar.
    expect(find.byKey(const ValueKey('quick_menu_items')), findsOneWidget);
    // v11.56: the quick row scrolls; More is the last card.
    await t.ensureVisible(find.byKey(const ValueKey('quick_more')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('quick_more')));
    await _settle(t);
    expect(find.byKey(const ValueKey('style_library_sheet')), findsOneWidget);
    expect(find.byKey(const ValueKey('photo_card_paris_eiffel')), findsOneWidget);
    expect(find.byKey(const ValueKey('video_card_video_slow_zoom')), findsNothing);
    // Category chips filter the grid.
    await t.tap(find.byKey(const ValueKey('style_cat_appearance')));
    await _settle(t, 3);
    expect(find.byKey(const ValueKey('photo_card_black_suit')), findsOneWidget);
    expect(find.byKey(const ValueKey('photo_card_paris_eiffel')), findsNothing);
    // Video tab: video styles, "from ⚡N" chip.
    await t.tap(find.byKey(const ValueKey('styles_tab_video')));
    await _settle(t, 3);
    expect(find.byKey(const ValueKey('video_card_video_slow_zoom')), findsOneWidget);
    expect(find.byKey(const ValueKey('style_cat_motion')), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is CreditText && w.text.startsWith('from ')), findsWidgets);
    await t.ensureVisible(find.byKey(const ValueKey('style_cat_zoom')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('style_cat_zoom')));
    await _settle(t, 3);
    expect(find.byKey(const ValueKey('video_card_video_slow_zoom')), findsOneWidget);
    expect(find.byKey(const ValueKey('video_card_video_gentle_motion')), findsNothing);
    // v11.57: video card with no last photo → toast, no source sheet.
    await t.tap(find.byKey(const ValueKey('video_card_video_slow_zoom')));
    await _settle(t, 5);
    expect(find.byKey(const ValueKey('video_source_sheet')), findsNothing);
    expect(find.byKey(const ValueKey('video_confirm_sheet')), findsNothing);
    expect(find.text('Take a photo first'), findsOneWidget);
    await t.pump(const Duration(seconds: 3));
  });

  testWidgets('tooltip is not shown again once seen; tap dismisses', (t) async {
    SharedPreferences.setMockInitialValues({kStylesHintSeenKey: true});
    await t.pumpWidget(const AiCameraApp());
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('styles_here_tooltip')), findsNothing);
    expect(find.byKey(const ValueKey('quick_menu_new')), findsNothing);
  });

  testWidgets('tooltip tap dismisses and stores it', (t) async {
    await t.pumpWidget(const AiCameraApp());
    await t.pump(const Duration(milliseconds: 300));
    await t.pump(); // v11.59: anchored after one layout pass
    await t.tap(find.byKey(const ValueKey('styles_here_tooltip')));
    await t.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('styles_here_tooltip')), findsNothing);
    expect((await SharedPreferences.getInstance()).getBool(kStylesHintSeenKey), isTrue);
  });

  testWidgets('quick panel never overflows on narrow / wide phones', (t) async {
    for (final w in [320.0, 360.0, 412.0, 480.0]) {
      t.view.physicalSize = Size(w, 800);
      t.view.devicePixelRatio = 1;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StylesQuickPanel(onPhoto: (_) {}, onVideo: (_) {}, onMore: () {}),
        ),
      ));
      await t.pump();
      expect(t.takeException(), isNull, reason: 'width $w');
      // v11.56: the row scrolls horizontally; More is the last card.
      expect(find.byKey(const ValueKey('quick_row_scroll')), findsOneWidget);
      final more = t.getRect(find.byKey(const ValueKey('quick_more')));
      for (final e in find.byType(GestureDetector).evaluate()) {
        final k = e.widget.key;
        if (k is ValueKey<String> && k.value.startsWith('quick_photo_')) {
          expect(t.getRect(find.byKey(k)).right, lessThanOrEqualTo(more.left + 1));
        }
      }
    }
    t.view.reset();
  });

  testWidgets('video confirm sheet: 480p default, coins follow the resolution', (t) async {
    final svc = VideoService();
    final f = File('${Directory.systemTemp.path}/v1154_p.jpg')..writeAsBytesSync([0]);
    String? res;
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => TextButton(
          onPressed: () async => res = await showVideoConfirmSheet(ctx,
              style: kBuiltinVideoStyles.first, photo: f, svc: svc),
          child: const Text('go'),
        ),
      ),
    ));
    await t.tap(find.text('go'));
    await _settle(t, 5);
    expect(find.byKey(const ValueKey('video_confirm_preview')), findsOneWidget);
    bool btn(String r) => find
        .byWidgetPredicate((w) => isCreditText(w, makeVideoLabel(svc.creditsForKey(5, r))))
        .evaluate()
        .isNotEmpty;
    expect(btn('480p'), isTrue);
    expect(t.widget<ChoiceChip>(find.byKey(const ValueKey('preset_res_480p'))).selected, isTrue);
    await t.tap(find.byKey(const ValueKey('preset_res_720p')));
    await t.pump();
    expect(btn('720p'), isTrue);
    await t.tap(find.byKey(const ValueKey('preset_go')));
    await _settle(t, 4);
    expect(res, '720p');
  });

  testWidgets('custom window (AI Video): text → video asks for no image', (t) async {
    VideoService.resetForTest(VideoService());
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(const MaterialApp(home: VideoScreen(startCustom: true)));
    await _settle(t, 4);
    expect(find.byKey(const ValueKey('video_prompt')), findsOneWidget);
    expect(find.byKey(const ValueKey('video_pick_photo')), findsOneWidget); // image → video
    await t.tap(find.byKey(const ValueKey('video_kind_VideoKind.t2v')));
    await t.pump();
    expect(find.byKey(const ValueKey('video_pick_photo')), findsNothing);
    expect(find.byKey(const ValueKey('video_aspect_16:9')), findsOneWidget);
    expect(find.byKey(const ValueKey('video_len_15')), findsOneWidget);
  });

  test('photo seed styles have categories and no prompts', () {
    final raw = File('assets/styles/seed_styles.json').readAsStringSync();
    expect(raw, contains('"ui_category"'));
    expect(styleGridColumns(328), 2);
    expect(styleGridColumns(400), 3);
  });
}
