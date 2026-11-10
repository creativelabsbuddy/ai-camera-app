import 'dart:io';

import 'package:ai_camera/models/ai_style.dart';
import 'package:ai_camera/screens/video_screen.dart';
import 'package:ai_camera/services/account_service.dart';
import 'package:ai_camera/services/saved_styles.dart';
import 'package:ai_camera/services/style_catalog.dart';
import 'package:ai_camera/services/style_samples.dart';
import 'package:ai_camera/services/video_service.dart';
import 'package:ai_camera/services/video_style_catalog.dart';
import 'package:ai_camera/widgets/look_sheet.dart';
import 'package:ai_camera/widgets/style_library_sheet.dart';
import 'package:ai_camera/widgets/styles_quick_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

AiStyle _s(String id, {String kind = 'style'}) =>
    AiStyle(id: id, name: id, category: 'x', creditCost: 2, kind: kind);

Future<void> _settle(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AccountService.resetForTest();
    SavedStyles.resetForTest(SavedStyles());
    StyleSamples.resetForTest(StyleSamples(url: '', key: ''));
  });

  // Version asserted in v1157_test.dart (1.11.57+70).

  group('saved styles order', () {
    test('toggle appends after earlier saves; unsave removes', () {
      var l = toggleSavedId(const [], 'a');
      l = toggleSavedId(l, 'b');
      l = toggleSavedId(l, 'c');
      expect(l, ['a', 'b', 'c']);
      expect(toggleSavedId(l, 'b'), ['a', 'c']);
    });

    test('saved first (saved order), then defaults without duplicates; unknown ids ignored', () {
      final defs = [_s('d1'), _s('d2'), _s('d3')];
      final all = [...defs, _s('x'), _s('y')];
      expect(orderWithSaved(['y', 'gone', 'd2', 'x'], defs, all).map((s) => s.id),
          ['y', 'd2', 'x', 'd1', 'd3']);
      // Unsave a default style → back at its default position.
      expect(orderWithSaved(['y', 'x'], defs, all).map((s) => s.id), ['y', 'x', 'd1', 'd2', 'd3']);
      expect(orderWithSaved(const [], defs, all).map((s) => s.id), ['d1', 'd2', 'd3']);
    });

    test('persists by id per group (shared prefs)', () async {
      final a = SavedStyles();
      await a.toggle('paris_eiffel', video: false);
      await a.toggle('santorini', video: false);
      await a.toggle('video_slow_zoom', video: true);
      final p = await SharedPreferences.getInstance();
      expect(p.getStringList(SavedStyles.photoKey), ['paris_eiffel', 'santorini']);
      expect(p.getStringList(SavedStyles.videoKey), ['video_slow_zoom']);
      final b = SavedStyles();
      await b.ensureLoaded();
      expect(b.photo.value, ['paris_eiffel', 'santorini']);
      expect(b.isSaved('video_slow_zoom', video: true), isTrue);
      await b.toggle('paris_eiffel', video: false);
      expect(p.getStringList(SavedStyles.photoKey), ['santorini']);
    });
  });

  testWidgets('quick row: saved photo/video styles first in their group, More last, scrolls', (t) async {
    t.view.physicalSize = const Size(412, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    StyleCatalog.instance.styles.value = [_s('p1'), _s('p2'), _s('p3'), _s('p4')];
    VideoStyleCatalog.instance.styles.value = [_s('v1'), _s('v2')];
    await SavedStyles.instance.toggle('p3', video: false);
    await SavedStyles.instance.toggle('p1', video: false);
    await SavedStyles.instance.toggle('v2', video: true);
    await SavedStyles.instance.toggle('ghost', video: false); // removed style: ignored
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StylesQuickPanel(
          filters: [_s('vivid', kind: 'filter')],
          onPhoto: (_) {},
          onVideo: (_) {},
          onMore: () {},
        ),
      ),
    ));
    await t.pump();
    expect(t.takeException(), isNull);
    expect(find.byKey(const ValueKey('quick_row_scroll')), findsOneWidget);
    double x(String k) => t.getTopLeft(find.byKey(ValueKey(k))).dx;
    // PHOTO: p3, p1 (saved order) → vivid filter → p2, p4 (no duplicate p1/p3).
    expect(x('quick_photo_p3'), lessThan(x('quick_photo_p1')));
    expect(x('quick_photo_p1'), lessThan(x('quick_photo_vivid')));
    expect(x('quick_photo_vivid'), lessThan(x('quick_photo_p2')));
    expect(find.byKey(const ValueKey('quick_photo_p1')), findsOneWidget);
    expect(find.byKey(const ValueKey('quick_photo_ghost')), findsNothing);
    expect(find.byKey(const ValueKey('quick_saved_p3')), findsOneWidget);
    // VIDEO: v2 first.
    expect(x('quick_video_v2'), lessThan(x('quick_video_v1')));
    expect(x('quick_photo_p4'), lessThan(x('quick_video_v2')));
    expect(x('quick_more'), greaterThan(x('quick_video_v1')));
    // Unsave p3 → falls back to its default position (after p2).
    await SavedStyles.instance.toggle('p3', video: false);
    await t.pump();
    expect(x('quick_photo_p1'), lessThan(x('quick_photo_vivid')));
    expect(x('quick_photo_p2'), lessThan(x('quick_photo_p3')));
  });

  testWidgets('Styles sheet: bookmark on photo + video cards; Custom opens the window by tab', (t) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 2.6;
    addTearDown(t.view.reset);
    StyleCatalog.instance.styles.value = [_s('p1'), _s('p2')];
    VideoStyleCatalog.instance.styles.value = [_s('v1')];
    StylePick? pick;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async => pick = await showStyleLibrarySheet(ctx),
            child: const Text('go'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('go'));
    await _settle(t);
    expect(find.byKey(const ValueKey('save_photo_p2')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('save_photo_p2')));
    await _settle(t, 3);
    expect(SavedStyles.instance.photo.value, ['p2']);
    expect(find.byIcon(Icons.bookmark_rounded), findsWidgets);
    // Custom from the Photo tab → AI Photo, no "photo or video?" step.
    await t.tap(find.byKey(const ValueKey('style_card_custom')));
    await _settle(t);
    expect(find.byKey(const ValueKey('custom_kind_sheet')), findsNothing);
    expect(pick?.custom, isTrue);
    expect(pick?.video, isFalse);

    await t.tap(find.text('go'));
    await _settle(t);
    await t.tap(find.byKey(const ValueKey('styles_tab_video')));
    await _settle(t, 3);
    await t.tap(find.byKey(const ValueKey('save_video_v1')));
    await _settle(t, 3);
    expect(SavedStyles.instance.video.value, ['v1']);
    await t.tap(find.byKey(const ValueKey('style_card_custom')));
    await _settle(t);
    expect(pick?.custom, isTrue);
    expect(pick?.video, isTrue);
  });

  testWidgets('Custom window: AI Photo | AI Video segments, default by entry, switchable', (t) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 2.6;
    addTearDown(t.view.reset);
    VideoService.resetForTest(VideoService());
    await t.pumpWidget(const MaterialApp(home: VideoScreen(custom: true, customPhotoFirst: true)));
    await _settle(t, 4);
    expect(find.text('Custom'), findsOneWidget);
    expect(find.byKey(const ValueKey('custom_seg_photo')), findsOneWidget);
    expect(find.byKey(const ValueKey('custom_seg_video')), findsOneWidget);
    expect(find.text('Styles'), findsNothing); // no Styles section
    expect(find.byKey(const ValueKey('custom_photo_panel')), findsOneWidget);
    expect(find.text('Write your prompt…'), findsOneWidget);
    expect(find.text('Black suit'), findsNothing);
    expect(find.text('Describe a change'), findsNothing);
    // Switch to AI Video.
    await t.tap(find.byKey(const ValueKey('custom_seg_video')));
    await _settle(t, 3);
    expect(find.byKey(const ValueKey('video_prompt')), findsOneWidget);
    expect(find.byKey(const ValueKey('video_pick_photo')), findsOneWidget); // image → video
    await t.tap(find.byKey(const ValueKey('video_kind_VideoKind.t2v')));
    await t.pump();
    expect(find.byKey(const ValueKey('video_pick_photo')), findsNothing);
    expect(find.byKey(const ValueKey('video_aspect_9:16')), findsOneWidget);
    expect(find.byKey(const ValueKey('video_aspect_16:9')), findsOneWidget);
    // Back to AI Photo.
    await t.tap(find.byKey(const ValueKey('custom_seg_photo')));
    await _settle(t, 3);
    expect(find.byKey(const ValueKey('custom_photo_panel')), findsOneWidget);

    // From the Video tab → AI Video selected.
    await t.pumpWidget(MaterialApp(key: UniqueKey(), home: const VideoScreen(custom: true, customPhotoFirst: false)));
    await _settle(t, 4);
    expect(find.byKey(const ValueKey('video_prompt')), findsOneWidget);
    expect(find.byKey(const ValueKey('custom_photo_panel')), findsNothing);
  });

  group('samples', () {
    test('rows: http only, video has no BEFORE', () {
      final m = parseSampleRows([
        {'id': 'a', 'media_type': 'photo', 'sample_before_url': 'https://x/b.jpg', 'sample_after_url': 'https://x/a.jpg'},
        {'id': 'v', 'media_type': 'video', 'sample_before_url': 'https://x/b.jpg', 'sample_after_url': 'https://x/v.jpg'},
        {'id': 'bad', 'media_type': 'photo', 'sample_after_url': 'javascript:x'},
      ]);
      expect(m['a']!.hasSlider, isTrue);
      expect(m['v']!.before, isNull);
      expect(m['v']!.after, 'https://x/v.jpg');
      expect(m['bad']!.after, isNull);
    });

    test('AiStyle parses sample urls (relative → server root) and round-trips', () {
      final s = AiStyle.fromJson({
        'id': 'p', 'name': 'P',
        'sample_before_url': '/media/styles/b.jpg',
        'sample_after_url': 'https://cdn/a.jpg',
      }, baseUrl: 'https://srv/');
      expect(s.sampleBeforeUrl, 'https://srv/media/styles/b.jpg');
      expect(s.sampleAfterUrl, 'https://cdn/a.jpg');
      expect(AiStyle.fromJson(s.toJson()).sampleAfterUrl, 'https://cdn/a.jpg');
      expect(AiStyle.fromJson({'id': 'q'}).sampleAfterUrl, isNull);
    });

    test('of(): server fields win; video uses its own AFTER only', () {
      final svc = StyleSamples(url: '', key: '');
      svc.samples.value = {
        'p': const StyleSample(before: 'https://x/b.jpg', after: 'https://x/a.jpg'),
      };
      expect(svc.of(_s('p'))!.hasSlider, isTrue);
      expect(svc.of(_s('nope')), isNull);
      expect(svc.of(_s('p'), video: true)!.before, isNull);
    });
  });

  testWidgets('apply sheet: before/after sample slider on top, Save toggle, one image only', (t) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 2.6;
    addTearDown(t.view.reset);
    StyleSamples.instance.samples.value = {
      'paris_eiffel': const StyleSample(before: 'https://x/b.jpg', after: 'https://x/a.jpg'),
    };
    final style = AiStyle(id: 'paris_eiffel', name: 'Paris', category: 'Travel', creditCost: 2);
    final nos = AiStyle(id: 'swiss_alps', name: 'Alps', category: 'Travel', creditCost: 2);
    Future<void> open(AiStyle s) async {
      await t.pumpWidget(MaterialApp(
        key: UniqueKey(),
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showLookSheet(ctx, style: s),
              child: const Text('go'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('go'));
      await _settle(t, 5);
    }

    await open(style);
    expect(find.byKey(const ValueKey('look_sample_slider')), findsOneWidget);
    expect(find.byKey(const ValueKey('sample_compare_slider')), findsOneWidget);
    final slider = t.getRect(find.byKey(const ValueKey('look_sample_slider')));
    expect(slider.width / slider.height, closeTo(9 / 16, 1e-6));
    // Slider sits above the photo selection.
    expect(slider.bottom, lessThan(t.getRect(find.byKey(const ValueKey('look_pick_gallery'))).top));
    await t.drag(find.byKey(const ValueKey('sample_compare_slider')), const Offset(-60, 0));
    await t.pump();
    expect(t.takeException(), isNull);
    expect(find.byKey(const ValueKey('variations_toggle')), findsNothing);
    expect(find.text('4 variations'), findsNothing);
    await t.tap(find.byKey(const ValueKey('look_sheet_save')));
    await _settle(t, 3);
    expect(SavedStyles.instance.photo.value, ['paris_eiffel']);
    expect(find.text('Saved'), findsWidgets);

    // No sample → placeholder look frame, no slider.
    await open(nos);
    expect(find.byKey(const ValueKey('look_sample_slider')), findsNothing);
    expect(find.byKey(const ValueKey('look_frame_look')), findsOneWidget);
  });

  testWidgets('custom photo sheet: titled Prompt, hint, no chips', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => showLookSheet(ctx),
            child: const Text('go'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('go'));
    await _settle(t, 5);
    expect(find.byKey(const ValueKey('look_sheet_title')), findsOneWidget);
    expect((t.widget<Text>(find.byKey(const ValueKey('look_sheet_title')))).data, 'Prompt');
    expect(find.text('Write your prompt…'), findsOneWidget);
    for (final c in ['Black suit', 'Beach at sunset', 'Red saree', 'Snowy winter', 'Describe a change']) {
      expect(find.text(c), findsNothing, reason: c);
    }
  });

  test('no "Describe a change" / 4-variations UI text left in lib/', () {
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final src = f.readAsStringSync();
      expect(src.contains("'Describe a change"), isFalse, reason: f.path);
      expect(src.contains("'4 variations'"), isFalse, reason: f.path);
      expect(src.contains('showCustomKindSheet'), isFalse, reason: f.path);
    }
  });
}
