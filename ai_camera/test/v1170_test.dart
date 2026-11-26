// v11.70 (1.11.70+83) tests: preview, no Filters panel, no camera tone chips,
// free photo editor (Crop / Adjust / Retouch / Skin Tone), single tier.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ai_camera/config/features_v1170.dart';
import 'package:ai_camera/models/quality_tier.dart';
import 'package:ai_camera/models/style_preset.dart';
import 'package:ai_camera/screens/photo_editor_screen.dart';
import 'package:ai_camera/services/adjust_presets.dart';
import 'package:ai_camera/services/edit_v1170.dart';
import 'package:ai_camera/services/enhance_service.dart';
import 'package:ai_camera/services/prompt_builder.dart';
import 'package:ai_camera/widgets/slim_style_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

double _luma(Uint8List px, int i) =>
    0.299 * px[i] + 0.587 * px[i + 1] + 0.114 * px[i + 2];

/// A skin-coloured "face" square with fine noise (pores) on a blue wall.
(Uint8List, int, int) _facePhoto({int w = 160, int h = 160, int seed = 3}) {
  final rnd = math.Random(seed);
  final px = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      final inFace = x >= 40 && x < 120 && y >= 40 && y < 120;
      final n = rnd.nextInt(17) - 8; // ±8 "pores"
      final blotch = ((x ~/ 12 + y ~/ 12) % 2 == 0) ? 6 : -6; // uneven tone
      if (inFace) {
        px[i] = (196 + n + blotch).clamp(0, 255);
        px[i + 1] = (150 + n + blotch).clamp(0, 255);
        px[i + 2] = (124 + n + blotch).clamp(0, 255);
      } else {
        px[i] = 40;
        px[i + 1] = 80;
        px[i + 2] = 190;
      }
      px[i + 3] = 255;
    }
  }
  return (px, w, h);
}

const _face = FaceGeom(box: Rect.fromLTWH(0.25, 0.25, 0.5, 0.5));

double _std(List<double> v) {
  final m = v.reduce((a, b) => a + b) / v.length;
  return math.sqrt(
    v.map((e) => (e - m) * (e - m)).reduce((a, b) => a + b) / v.length,
  );
}

/// High-frequency energy (pixel minus its 3x3 mean) inside the face.
double _hf(Uint8List px, int w) {
  final v = <double>[];
  for (var y = 60; y < 100; y++) {
    for (var x = 60; x < 100; x++) {
      var s = 0.0;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          s += _luma(px, ((y + dy) * w + x + dx) * 4);
        }
      }
      v.add(_luma(px, (y * w + x) * 4) - s / 9);
    }
  }
  return _std(v);
}

/// Low-frequency spread (12x12 block means) inside the face.
double _lf(Uint8List px, int w) {
  final v = <double>[];
  for (var by = 48; by < 108; by += 12) {
    for (var bx = 48; bx < 108; bx += 12) {
      var s = 0.0;
      for (var y = by; y < by + 12; y++) {
        for (var x = bx; x < bx + 12; x++) {
          s += _luma(px, (y * w + x) * 4);
        }
      }
      v.add(s / 144);
    }
  }
  return _std(v);
}

void main() {
  test('version 1.11.70+83', () {
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains('version: 1.11.70+83'),
    );
  });

  test('all v11.70 flags are on (each one is a kill switch)', () {
    expect(kPreviewV1170, isTrue);
    expect(kNoFiltersPanel, isTrue);
    expect(kNoToneChips, isTrue);
    expect(kEditorV1170, isTrue);
    expect(kRetouch, isTrue);
    expect(kSkinTone, isTrue);
    expect(kSingleEnhanceTier, isTrue);
  });

  group('6: single enhance tier', () {
    test('every tier maps to the one HD tier: 1 credit', () {
      for (final t in QualityTier.values) {
        expect(enhanceTierFor(t), QualityTier.hd);
      }
      expect(enhanceTierFor(QualityTier.k4).credits, 1);
    });

    test('prompt = UNIVERSAL + the Ultra HD sentence; synced with server', () {
      expect(
        kSingleTierSentence,
        'Target a very detailed Ultra HD result with crisp fine texture.',
      );
      expect(qualitySentence(QualityTier.hd), kSingleTierSentence);
      expect(
        buildEnhancePrompt(tier: QualityTier.hd),
        '$kUniversalEnhancePrompt $kSingleTierSentence',
      );
      final job = EnhanceJob(image: File('x.jpg'), tier: QualityTier.hd);
      expect(
        job.prompt(hasContext: false),
        '$kUniversalEnhancePrompt $kSingleTierSentence',
      );
      final py = File('../enhance-server/prompts.py').readAsStringSync();
      expect(py, contains(kSingleTierSentence));
      expect(py, contains('SINGLE_TIER_SENTENCE'));
    });

    test(
      'server: SINGLE_TIER flag, upscale off, products expose enhance_tier',
      () {
        final ledger = File('../enhance-server/ledger.py').readAsStringSync();
        expect(ledger, contains('SINGLE_TIER'));
        final main = File('../enhance-server/main.py').readAsStringSync();
        expect(main, contains('UPSCALE_TIERS = {} if L.SINGLE_TIER'));
        expect(main, contains('"enhance_tier"'));
      },
    );

    test('camera hides the quality chip / quick-menu quality item', () {
      final src = File(
        'lib/screens/home_camera_screen.dart',
      ).readAsStringSync();
      expect(src, contains('showQuality: !kSingleEnhanceTier'));
      expect(src, contains('!kNoToneChips'));
    });

    test('5: Zoom mode chip only on the back lens', () {
      final src = File(
        'lib/screens/home_camera_screen.dart',
      ).readAsStringSync();
      final i = src.indexOf('_showZoomModeChip');
      expect(i, greaterThan(0));
      expect(src.substring(i, i + 400), contains('CameraLensDirection.back'));
    });
  });

  group('4: editor engine', () {
    test('Adjust: 8 sliders and 4 presets', () {
      expect(kAdjustSliders.map((s) => s.label), [
        'Brightness',
        'Contrast',
        'Shadows',
        'Highlights',
        'Saturation',
        'Warmth',
        'Sharpness',
        'Definition',
      ]);
      expect(kAdjustPresets.map((p) => p.name), [
        'Clear',
        'Bright',
        'Punchy',
        'Soft',
      ]);
      for (final p in kAdjustPresets) {
        expect(p.params.isNeutral, isFalse);
      }
    });

    test('recipe json round trip', () {
      const r = EditRecipe(
        quarterTurns: 1,
        crop: Rect.fromLTWH(0.1, 0.2, 0.5, 0.6),
        adjust: AdjustParams(brightness: 0.2, definition: -0.3),
        retouch: RetouchParams(
          smooth: 0.5,
          teeth: 0.3,
          spots: [BlemishSpot(0.4, 0.5, 0.01)],
        ),
        skinTone: -0.4,
      );
      final back = EditRecipe.fromJson(r.toJson());
      expect(back.pixelKey, r.pixelKey);
      expect(back.quarterTurns, 1);
      expect(back.crop.left, closeTo(0.1, 1e-6));
      expect(back.skinTone, closeTo(-0.4, 1e-6));
      expect(back.retouch.spots.single.x, closeTo(0.4, 1e-6));
      expect(const EditRecipe().isIdentity, isTrue);
    });

    test('unrotatePoint inverts the quarter turns', () {
      const p = Offset(0.2, 0.7);
      expect(unrotatePoint(p, 0), p);
      expect(unrotatePoint(p, 2).dx, closeTo(0.8, 1e-9));
      expect(unrotatePoint(p, 2).dy, closeTo(0.3, 1e-9));
      expect(unrotatePoint(p, 1).dx, closeTo(0.7, 1e-9));
      expect(unrotatePoint(p, 1).dy, closeTo(0.8, 1e-9));
      expect(unrotatePoint(p, 3).dx, closeTo(0.3, 1e-9));
      expect(unrotatePoint(p, 3).dy, closeTo(0.2, 1e-9));
    });

    test('guided smooth keeps a hard edge', () {
      const w = 40, h = 10;
      final p = Float32List(w * h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          p[y * w + x] = x < 20 ? 0.2 : 0.8;
        }
      }
      final o = guidedSmooth(p, w, h, 4, 0.0004);
      expect(o[5 * w + 10], closeTo(0.2, 0.02));
      expect(o[5 * w + 30], closeTo(0.8, 0.02));
      expect((o[5 * w + 21] - o[5 * w + 18]).abs(), greaterThan(0.4));
    });

    test('smooth skin evens tone but keeps pores; background untouched', () {
      final (px, w, h) = _facePhoto();
      final before = Uint8List.fromList(px);
      renderEditPixels(
        px,
        w,
        h,
        const EditRecipe(retouch: RetouchParams(smooth: 1)),
        faces: const [_face],
      );
      final hf0 = _hf(before, w), hf1 = _hf(px, w);
      final lf0 = _lf(before, w), lf1 = _lf(px, w);
      expect(lf1, lessThan(lf0 * 0.9), reason: 'blotches evened');
      expect(hf1, greaterThan(hf0 * 0.6), reason: 'pores kept');
      // Blue wall (not skin) is unchanged.
      expect(px.sublist(0, 4 * 20), before.sublist(0, 4 * 20));
    });

    test('Skin Tone: about 1–2 shades, skin only, both ways', () {
      double faceLuma(Uint8List p, int w) {
        var s = 0.0;
        for (var y = 60; y < 100; y++) {
          for (var x = 60; x < 100; x++) {
            s += _luma(p, (y * w + x) * 4);
          }
        }
        return s / 1600;
      }

      final (base, w, h) = _facePhoto();
      final l0 = faceLuma(base, w);
      final lighter = Uint8List.fromList(base);
      applySkinTone(lighter, w, h, 1, faces: const [_face]);
      final darker = Uint8List.fromList(base);
      applySkinTone(darker, w, h, -1, faces: const [_face]);
      final up = faceLuma(lighter, w) - l0;
      final down = l0 - faceLuma(darker, w);
      expect(up, inInclusiveRange(6, 40));
      expect(down, inInclusiveRange(6, 40));
      // The wall keeps its colour.
      expect(lighter.sublist(0, 40), base.sublist(0, 40));
      expect(darker.sublist(0, 40), base.sublist(0, 40));
    });

    test('blemish heal flattens a dark spot', () {
      final (px, w, h) = _facePhoto();
      for (var y = 78; y < 82; y++) {
        for (var x = 78; x < 82; x++) {
          final i = (y * w + x) * 4;
          px[i] = 90;
          px[i + 1] = 50;
          px[i + 2] = 40;
        }
      }
      final spot = _luma(px, (80 * w + 80) * 4);
      renderEditPixels(
        px,
        w,
        h,
        const EditRecipe(
          retouch: RetouchParams(spots: [BlemishSpot(0.5, 0.5, 0.03)]),
        ),
        faces: const [_face],
      );
      expect(_luma(px, (80 * w + 80) * 4), greaterThan(spot + 40));
    });

    test('Adjust brightness lifts the image; neutral recipe is a no-op', () {
      final (px, w, h) = _facePhoto();
      final before = Uint8List.fromList(px);
      renderEditPixels(px, w, h, const EditRecipe(), faces: const [_face]);
      expect(px, before);
      renderEditPixels(
        px,
        w,
        h,
        const EditRecipe(adjust: AdjustParams(brightness: 0.5)),
      );
      expect(
        _luma(px, (80 * w + 80) * 4),
        greaterThan(_luma(before, (80 * w + 80) * 4)),
      );
    });

    test('Save as preset: stored on the phone, newest first, max 12', () async {
      SharedPreferences.setMockInitialValues({});
      await AdjustPresetStore.add('Mine', const AdjustParams(contrast: 0.3));
      var l = await AdjustPresetStore.add(
        'Evening',
        const AdjustParams(warmth: 0.4),
      );
      expect(l.map((p) => p.name), ['Evening', 'Mine']);
      l = await AdjustPresetStore.load();
      expect(l.last.params.contrast, closeTo(0.3, 1e-6));
      l = await AdjustPresetStore.remove('Mine');
      expect(l.map((p) => p.name), ['Evening']);
      for (var i = 0; i < 20; i++) {
        l = await AdjustPresetStore.add('p$i', const AdjustParams());
      }
      expect(l.length, AdjustPresetStore.maxPresets);
    });
  });

  group('4: editor screen', () {
    late Directory dir;
    late File photo;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      dir = Directory.systemTemp.createTempSync('v1170');
      photo = File('${dir.path}/p.png')
        ..writeAsBytesSync(
          img.encodePng(
            img.Image(width: 30, height: 40)
              ..clear(img.ColorRgb8(200, 150, 120)),
          ),
        );
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Future<EditedPhoto?> openEditor(
      WidgetTester t, {
      required Future<void> Function() actions,
      List<EditRecipe>? saved,
    }) async {
      EditedPhoto? result;
      final (px, w, h) = _facePhoto(w: 30, h: 40);
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  result = await Navigator.of(context).push<EditedPhoto>(
                    MaterialPageRoute(
                      builder: (_) => PhotoEditorScreen(
                        file: photo,
                        proxyLoader: (_) async =>
                            (rgba: px, width: w, height: h),
                        faceDetector: (_, _, _) async => const [],
                        saver: (f, r, faces) async {
                          saved?.add(r);
                          return File('${dir.path}/edited.jpg')
                            ..writeAsBytesSync([1, 2, 3]);
                        },
                        gallerySaver: (_) async => true,
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      for (var i = 0; i < 10; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await t.pump(const Duration(milliseconds: 100));
      }
      await actions();
      return result;
    }

    testWidgets('four tabs; Save writes a new copy with the recipe', (t) async {
      final saved = <EditRecipe>[];
      await openEditor(
        t,
        saved: saved,
        actions: () async {
          for (final tab in ['crop', 'adjust', 'retouch', 'skin']) {
            expect(find.byKey(ValueKey('edit_tab_$tab')), findsOneWidget);
          }
          await t.tap(find.byKey(const ValueKey('preset_Punchy')));
          await t.pump();
          await t.tap(find.byKey(const ValueKey('edit_tab_crop')));
          await t.pump();
          await t.tap(find.byKey(const ValueKey('edit_rotate')));
          await t.pump();
          await t.tap(find.byKey(const ValueKey('edit_tab_retouch')));
          await t.pump();
          // No face found → a note, no crash.
          expect(find.textContaining('face'), findsWidgets);
          await t.tap(find.byKey(const ValueKey('edit_save')));
          for (var i = 0; i < 10; i++) {
            await t.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await t.pump(const Duration(milliseconds: 100));
          }
        },
      );
      expect(saved, hasLength(1));
      expect(saved.single.quarterTurns, 1);
      expect(saved.single.adjust.isNeutral, isFalse);
      expect(find.byType(PhotoEditorScreen), findsNothing);
      expect(photo.existsSync(), isTrue, reason: 'original kept');
    });

    testWidgets('no change → Save just closes (nothing written)', (t) async {
      final saved = <EditRecipe>[];
      await openEditor(
        t,
        saved: saved,
        actions: () async {
          await t.tap(find.byKey(const ValueKey('edit_save')));
          await t.pump();
          await t.pump(const Duration(milliseconds: 400));
        },
      );
      expect(saved, isEmpty);
      expect(find.byType(PhotoEditorScreen), findsNothing);
    });
  });

  group('1 + 2: slim Styles row with AI filters', () {
    testWidgets('AI filter tiles (credits), See all, Custom', (t) async {
      StylePreset? picked;
      var seeAll = 0;
      var custom = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SlimStyleRow(
              styles: const [],
              onStyle: (_) {},
              onSeeAll: () => seeAll++,
              onCustom: () => custom++,
              aiFilters: kStylePresets,
              onAiFilter: (p) => picked = p,
              aiFilterCost: 1,
              isPro: true,
            ),
          ),
        ),
      );
      final first = kStylePresets.first;
      expect(find.byKey(ValueKey('ai_${first.id}')), findsOneWidget);
      await t.tap(find.byKey(ValueKey('ai_${first.id}')));
      expect(picked?.id, first.id);
      await t.tap(find.byKey(const ValueKey('styles_see_all')));
      expect(seeAll, 1);
      await t.tap(find.byKey(const ValueKey('slim_custom')));
      expect(custom, 1);
      expect(find.text('See all'), findsOneWidget);
    });
  });
}
