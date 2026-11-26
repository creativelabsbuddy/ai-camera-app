// v11.69 (1.11.69+82) tests: Zoom mode → Sunburst; Pro Photo Natural /
// Studio; Normal burst (best pick + review); Auto Tone; Tone presets.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_camera/config/ai_config.dart';
import 'package:ai_camera/config/features_v1169.dart';
import 'package:ai_camera/models/photo_look.dart';
import 'package:ai_camera/models/quality_tier.dart';
import 'package:ai_camera/models/capture_mode.dart';
import 'package:ai_camera/screens/burst_review_screen.dart';
import 'package:ai_camera/screens/preview_screen.dart';
import 'package:ai_camera/services/account_service.dart';
import 'package:ai_camera/services/ai_call.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_camera/services/burst_shot.dart';
import 'package:ai_camera/services/enhance_service.dart';
import 'package:ai_camera/services/macro.dart' show kMacroComingSoon;
import 'package:ai_camera/services/openrouter_client.dart';
import 'package:ai_camera/services/server_api_client.dart';
import 'package:ai_camera/services/tone.dart';
import 'package:ai_camera/widgets/tone_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

const kSunburst = 'openai/gpt-image-2.5-sunburst';
const kFlare = 'openai/gpt-image-2.5-flare';

void main() {
  _wiringTests();
  test('version 1.11.69+82', () {
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains('version: 1.11.'),
    );
  });

  test('v11.69 switches on; Macro stays Coming soon', () {
    expect(kZoomSunburst, isTrue);
    expect(kProLookToggle, isTrue);
    expect(kBurstShot, isTrue);
    expect(kAutoTone, isTrue);
    expect(kTonePresets, isTrue);
    expect(kMacroComingSoon, isTrue);
    expect(AiConfig.model, kFlare);
    expect(AiConfig.sunburstModel, kSunburst);
  });

  group('model routing', () {
    final f = File('x.jpg');

    test('pure router', () {
      expect(enhanceModelFor(aiMode: 'photo', zoomJob: true), kSunburst);
      expect(
        enhanceModelFor(aiMode: 'photo', zoomJob: true, look: PhotoLook.studio),
        kSunburst,
      );
      expect(
        enhanceModelFor(
          aiMode: 'photo',
          zoomJob: false,
          look: PhotoLook.natural,
        ),
        kSunburst,
      );
      expect(
        enhanceModelFor(
          aiMode: 'photo',
          zoomJob: false,
          look: PhotoLook.studio,
        ),
        kFlare,
      );
      expect(enhanceModelFor(aiMode: 'photo', zoomJob: false), kFlare);
      for (final m in ['portrait', 'night', 'macro']) {
        expect(
          enhanceModelFor(aiMode: m, zoomJob: false, look: PhotoLook.natural),
          kFlare,
        );
      }
    });

    test('jobs: zoom clean → Sunburst, Pro Photo by look', () {
      final zoom = EnhanceJob(image: f, zoomClean: true, zoom: 20);
      expect(zoom.isZoomJob, isTrue);
      expect(zoom.model, kSunburst);
      expect(zoom.sentLook, isNull); // Zoom mode never sends a look
      final zoomStudio = EnhanceJob(
        image: f,
        zoomClean: true,
        zoom: 20,
        photoLook: PhotoLook.studio,
      );
      expect(zoomStudio.model, kSunburst);
      final nat = EnhanceJob(image: f, photoLook: PhotoLook.natural);
      expect(nat.model, kSunburst);
      expect(nat.sentLook, PhotoLook.natural);
      final studio = EnhanceJob(image: f, photoLook: PhotoLook.studio);
      expect(studio.model, kFlare);
      expect(EnhanceJob(image: f).model, kFlare);
      // Portrait / Night / Macro unchanged.
      expect(
        EnhanceJob(
          image: f,
          mode: 'portrait',
          photoLook: PhotoLook.natural,
        ).model,
        kFlare,
      );
      expect(
        EnhanceJob(image: f, night: true, photoLook: PhotoLook.natural).model,
        kFlare,
      );
      // Same credits for both looks.
      expect(nat.spec.creditsOverride, studio.spec.creditsOverride);
      expect(nat.spec.tier, studio.spec.tier);
    });

    test('same prompt for Natural and Studio', () {
      final a = EnhanceJob(image: f, photoLook: PhotoLook.natural);
      final b = EnhanceJob(image: f, photoLook: PhotoLook.studio);
      expect(a.prompt(hasContext: false), b.prompt(hasContext: false));
    });

    test('payload: same params, model swapped', () {
      final flare = buildImagesPayload(
        prompt: 'p',
        tier: QualityTier.hd,
        aspectRatio: '3:4',
        imageDataUrl: 'data:x',
      );
      final sun = buildImagesPayload(
        prompt: 'p',
        tier: QualityTier.hd,
        aspectRatio: '3:4',
        imageDataUrl: 'data:x',
        model: kSunburst,
      );
      expect(flare['model'], kFlare);
      expect(sun['model'], kSunburst);
      expect(sun['quality'], 'low');
      expect(sun['resolution'], '1K');
      expect(sun['n'], 1);
      expect(sun['output_format'], 'jpeg');
      expect((sun['input_references'] as List).length, 1);
      expect({...sun}..remove('model'), {...flare}..remove('model'));
    });

    test('OpenRouter call sends the chosen model', () async {
      final dir = Directory.systemTemp.createTempSync('v1169m');
      addTearDown(() => dir.deleteSync(recursive: true));
      final jpg = img.encodeJpg(img.Image(width: 64, height: 48));
      final photo = File('${dir.path}/p.jpg')..writeAsBytesSync(jpg);
      final models = <String>[];
      final c = OpenRouterClient(
        apiKey: 'test',
        httpClient: MockClient((r) async {
          models.add((jsonDecode(r.body) as Map)['model'] as String);
          return http.Response(
            jsonEncode({
              'data': [
                {'b64_json': base64Encode(jpg)},
              ],
            }),
            200,
          );
        }),
      );
      await c.enhanceImages(
        image: photo,
        tier: QualityTier.hd,
        promptFor: (_) => 'p',
        model: kSunburst,
      );
      await c.enhanceImages(
        image: photo,
        tier: QualityTier.hd,
        promptFor: (_) => 'p',
      );
      expect(models, [kSunburst, kFlare]);
    });

    test('server request carries photo_look', () async {
      final dir = Directory.systemTemp.createTempSync('v1169s');
      addTearDown(() => dir.deleteSync(recursive: true));
      final jpg = img.encodeJpg(img.Image(width: 64, height: 48));
      final photo = File('${dir.path}/p.jpg')..writeAsBytesSync(jpg);
      final bodies = <String>[];
      final s = ServerApiClient(
        httpClient: MockClient((r) async {
          bodies.add(latin1.decode(r.bodyBytes, allowInvalid: true));
          return http.Response('nope', 500);
        }),
      );
      for (final look in ['natural', null]) {
        try {
          await s.enhance(
            baseUrl: 'http://x',
            deviceId: 'd',
            image: photo,
            tier: QualityTier.hd,
            zoom: 1,
            opticalLimit: 1,
            photoLook: look,
          );
        } catch (_) {}
      }
      expect(bodies.length, 2);
      expect(bodies[0], contains('name="photo_look"'));
      expect(bodies[0], contains('natural'));
      expect(bodies[1], isNot(contains('photo_look')));
    });

    test('look prefs + exact tip', () {
      expect(PhotoLook.defaultLook, PhotoLook.natural);
      expect(PhotoLook.fromId(null), PhotoLook.natural);
      expect(PhotoLook.fromId('studio'), PhotoLook.studio);
      expect(PhotoLook.fromId('bogus'), PhotoLook.natural);
      expect(kPhotoLookTip, 'Natural: as it is · Studio: picture perfect');
      expect(PhotoLook.natural.label, 'Natural');
      expect(PhotoLook.studio.label, 'Studio');
    });
  });

  group('burst best pick', () {
    test('no faces → sharpest wins', () {
      final f = [
        const BurstScore(sharpness: 10),
        const BurstScore(sharpness: 40),
        const BurstScore(sharpness: 25),
      ];
      expect(pickBestFrame(f), 1);
      expect(bestReason(f), 'Best: sharpest photo');
      expect(pickBestFrame(const []), -1);
    });

    test('faces → a blink loses even when sharper', () {
      final f = [
        const BurstScore(sharpness: 100, eyes: [0.05]), // sharp, blink
        const BurstScore(sharpness: 80, eyes: [0.95]), // eyes open
        const BurstScore(sharpness: 30, eyes: [0.97]),
      ];
      expect(pickBestFrame(f), 1);
      expect(bestReason(f), 'Best: sharpest with eyes open');
    });

    test('a frame that lost a face is pushed down', () {
      final f = [
        const BurstScore(sharpness: 100, eyes: [0.9]), // 1 of 2 faces
        const BurstScore(sharpness: 85, eyes: [0.9, 0.85]),
      ];
      expect(pickBestFrame(f), 1);
    });

    test('ties keep the earliest frame', () {
      final f = [
        const BurstScore(sharpness: 50),
        const BurstScore(sharpness: 50),
      ];
      expect(pickBestFrame(f), 0);
    });

    test('Laplacian: flat = 0, detail > blur', () {
      Uint8List frame(bool detail) {
        const w = 40, h = 30;
        final b = Uint8List(w * h * 4);
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            final v = detail
                ? (((x ~/ 2) + (y ~/ 2)) % 2 == 0 ? 230 : 20)
                : 128;
            final i = (y * w + x) * 4;
            b[i] = b[i + 1] = b[i + 2] = v;
            b[i + 3] = 255;
          }
        }
        return b;
      }

      expect(laplacianVariance(frame(false), 40, 30), 0);
      expect(laplacianVariance(frame(true), 40, 30), greaterThan(1000));
    });

    test('8 frames per burst', () {
      expect(kBurstFrames, inInclusiveRange(8, 10));
      expect(kBurstTip, 'Tip: press and hold the shutter for Burst');
    });
  });

  group('burst review screen', () {
    late Directory dir;
    late List<String> frames;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('v1169b');
      final jpg = img.encodeJpg(img.Image(width: 8, height: 6));
      frames = [
        for (var i = 0; i < 4; i++)
          (File('${dir.path}/f$i.jpg')..writeAsBytesSync(jpg)).path,
      ];
      // Frame 2 is the sharpest (checker); the rest are flat.
      BurstAnalyzer.decode = (path) async {
        const w = 20, h = 16;
        final sharp = path.endsWith('f2.jpg');
        final b = Uint8List(w * h * 4);
        for (var i = 0; i < w * h; i++) {
          final v = sharp ? (i % 2 == 0 ? 240 : 10) : 120;
          b[i * 4] = b[i * 4 + 1] = b[i * 4 + 2] = v;
          b[i * 4 + 3] = 255;
        }
        return (b, w, h);
      };
      BurstAnalyzer.eyesOf = (_) async => null;
    });
    tearDown(() {
      BurstAnalyzer.reset();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    testWidgets('Best badge, confirm, keep best, delete rest', (t) async {
      BurstResult? result;
      final prepared = <String>[];
      final saved = <String>[];
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    result = await Navigator.of(ctx).push<BurstResult>(
                      MaterialPageRoute(
                        builder: (_) => BurstReviewScreen(
                          frames: frames,
                          portraitRatio: 3 / 4,
                          prepare: (raw) async {
                            prepared.add(raw);
                            return raw;
                          },
                          save: (f) async {
                            saved.add(f.path);
                            return 'Saved to gallery · AI Camera album';
                          },
                        ),
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await t.pumpAndSettle();
      expect(find.text('Burst · 4 photos'), findsOneWidget);
      expect(find.byKey(const ValueKey('burst_best_badge')), findsWidgets);
      expect(find.text('Best: sharpest photo'), findsOneWidget);
      expect(find.text('Keep best, delete rest'), findsOneWidget);
      expect(find.text('Keep all'), findsOneWidget);

      // Another frame selected → "Keep this".
      await t.tap(find.byKey(const ValueKey('burst_thumb_0')));
      await t.pump();
      expect(find.text('Keep this, delete rest'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('burst_thumb_2')));
      await t.pump();

      await t.tap(find.byKey(const ValueKey('burst_keep_best')));
      await t.pumpAndSettle();
      expect(find.text('Keep best photo?'), findsOneWidget);
      expect(find.text('The other 3 photos will be deleted.'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('burst_confirm_ok')));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await t.pumpAndSettle();
      expect(prepared, [frames[2]]);
      expect(saved, [frames[2]]);
      expect(result, isNotNull);
      expect(result!.saved.single.path, frames[2]);
      expect(result!.deleted, 3);
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      for (final i in [0, 1, 3]) {
        expect(File(frames[i]).existsSync(), isFalse);
      }
      expect(File(frames[2]).existsSync(), isTrue);
    });

    testWidgets('Cancel in the confirm keeps everything', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: BurstReviewScreen(
            frames: frames,
            portraitRatio: 3 / 4,
            prepare: (raw) async => raw,
            save: (_) async => 'ok',
          ),
        ),
      );
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('burst_keep_best')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('burst_confirm_cancel')));
      await t.pumpAndSettle();
      for (final f in frames) {
        expect(File(f).existsSync(), isTrue);
      }
    });
  });

  group('tone', () {
    test('neutral = identity, curves monotonic at the extremes', () {
      final (r, g, b) = toneLuts(ToneParams.zero);
      for (var i = 0; i < 256; i++) {
        expect(r[i], i);
        expect(g[i], i);
        expect(b[i], i);
      }
      for (final v in [-1.0, 1.0]) {
        final t = ToneParams(
          exposure: v,
          contrast: v,
          highlights: v,
          shadows: v,
          warmth: v,
          saturation: v,
        );
        final (lr, lg, lb) = toneLuts(t);
        for (var i = 1; i < 256; i++) {
          expect(lr[i] >= lr[i - 1], isTrue);
          expect(lg[i] >= lg[i - 1], isTrue);
          expect(lb[i] >= lb[i - 1], isTrue);
        }
      }
    });

    test('mono → grey; warmth → warmer', () {
      final px = Uint8List.fromList([200, 80, 40, 255, 30, 90, 220, 255]);
      final m = toneRgba(px, ToneParams.zero, mono: true);
      expect(m[0], m[1]);
      expect(m[1], m[2]);
      expect(m[4], m[5]);
      final w = toneRgba(
        Uint8List.fromList([120, 120, 120, 255]),
        const ToneParams(warmth: 0.5),
      );
      expect(w[0], greaterThan(w[2]));
      // never touches alpha
      expect(m[3], 255);
    });

    ToneStats stats({
      double median = 0.46,
      double lo = 0.05,
      double hi = 0.95,
      double clipHigh = 0,
      double deep = 0,
      double r = 0.5,
      double g = 0.5,
      double b = 0.5,
      double chroma = 0.2,
    }) => ToneStats(
      lo: lo,
      median: median,
      hi: hi,
      clipHigh: clipHigh,
      deepShadow: deep,
      meanR: r,
      meanG: g,
      meanB: b,
      chroma: chroma,
    );

    test('Auto Tone: dark → brighter, bright → darker, gentle', () {
      expect(autoToneFor(stats(median: 0.2)).exposure, greaterThan(0));
      expect(autoToneFor(stats(median: 0.8)).exposure, lessThan(0));
      final ok = autoToneFor(stats());
      expect(ok.exposure, 0);
      expect(ok.contrast, 0);
      // Always bounded.
      final wild = autoToneFor(
        stats(
          median: 0.03,
          lo: 0.4,
          hi: 0.5,
          clipHigh: 0.5,
          deep: 0.9,
          b: 0.9,
          r: 0.1,
          chroma: 0,
        ),
      );
      expect(wild.exposure, lessThanOrEqualTo(0.40));
      expect(wild.contrast, lessThanOrEqualTo(0.28));
      expect(wild.highlights, greaterThanOrEqualTo(-0.45));
      expect(wild.shadows, lessThanOrEqualTo(0.40));
      expect(wild.warmth.abs(), lessThanOrEqualTo(0.20));
      expect(wild.saturation, lessThanOrEqualTo(0.22));
    });

    test('Auto Tone: flat → contrast, clipped → highlights, cast → warmth', () {
      expect(autoToneFor(stats(lo: 0.3, hi: 0.6)).contrast, greaterThan(0));
      expect(autoToneFor(stats(clipHigh: 0.06)).highlights, lessThan(0));
      expect(autoToneFor(stats(deep: 0.2)).shadows, greaterThan(0));
      expect(autoToneFor(stats(b: 0.6, r: 0.4)).warmth, greaterThan(0));
      expect(autoToneFor(stats(b: 0.4, r: 0.6)).warmth, lessThan(0));
    });

    test('stats of real pixels', () {
      final dark = Uint8List(64 * 4);
      for (var i = 0; i < 64; i++) {
        dark[i * 4] = dark[i * 4 + 1] = dark[i * 4 + 2] = 30;
      }
      final s = toneStatsOf(dark, 8, 8, step: 1);
      expect(s.median, closeTo(30 / 255, 0.01));
      expect(autoToneFor(s).exposure, greaterThan(0));
    });

    test('presets: 8 in order, labels, compose + Reset', () {
      expect(TonePreset.values.map((t) => t.label).toList(), [
        'Auto',
        'Vivid',
        'Natural',
        'Warm',
        'Cool',
        'Food',
        'Portrait soft',
        'B&W',
      ]);
      expect(TonePreset.auto.offset.isNeutral, isTrue);
      expect(TonePreset.bw.mono, isTrue);
      expect(TonePreset.warm.offset.warmth, greaterThan(0));
      expect(TonePreset.cool.offset.warmth, lessThan(0));
      expect(TonePreset.vivid.offset.saturation, greaterThan(0));
      expect(TonePreset.fromName('food'), TonePreset.food);
      expect(TonePreset.fromName(null), TonePreset.auto);
      const auto = ToneParams(exposure: 0.2, saturation: 0.9);
      final t = composeTone(
        auto: auto,
        autoOn: true,
        preset: TonePreset.vivid,
        manual: const ToneParams(saturation: 0.5),
      );
      expect(t.saturation, 1.0); // clamped
      final off = composeTone(
        auto: auto,
        autoOn: false,
        preset: TonePreset.auto,
      );
      expect(off.isNeutral, isTrue); // Reset = the original
      expect(toneChangesPhoto(off, TonePreset.auto), isFalse);
      expect(toneChangesPhoto(off, TonePreset.bw), isTrue);
    });

    test('live preview matrix', () {
      expect(tonePreviewMatrix(TonePreset.auto), isNull);
      final bw = tonePreviewMatrix(TonePreset.bw)!;
      expect(bw.length, 20);
      // grey: the three colour rows are equal
      expect(bw[0], closeTo(bw[5], 1e-9));
      expect(bw[5], closeTo(bw[10], 1e-9));
      final warm = tonePreviewMatrix(TonePreset.warm)!;
      expect(warm[0], greaterThan(warm[12]));
    });

    test('full-res render writes a new file, original untouched', () async {
      final dir = Directory.systemTemp.createTempSync('v1169t');
      addTearDown(() => dir.deleteSync(recursive: true));
      final src = File('${dir.path}/s.jpg')
        ..writeAsBytesSync(
          img.encodeJpg(
            img.Image(width: 40, height: 30)..clear(img.ColorRgb8(60, 60, 60)),
          ),
        );
      final before = src.readAsBytesSync();
      final out = await renderToneFile(
        src,
        const ToneParams(exposure: 0.6),
        outDir: dir.path,
      );
      expect(out.path, isNot(src.path));
      expect(src.readAsBytesSync(), before);
      final im = img.decodeJpg(out.readAsBytesSync())!;
      expect(im.width, 40);
      expect(im.getPixel(20, 15).r, greaterThan(70));
    });
  });

  group('tone widgets', () {
    testWidgets('ToneBar: Auto Tone, Adjust, Reset, 8 presets', (t) async {
      TonePreset? picked;
      var reset = 0;
      bool? auto;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ToneBar(
              autoOn: true,
              preset: TonePreset.auto,
              enabled: true,
              canReset: true,
              onAuto: (v) => auto = v,
              onPreset: (p) => picked = p,
              onAdjust: () {},
              onReset: () => reset++,
            ),
          ),
        ),
      );
      expect(find.text('Auto Tone'), findsOneWidget);
      expect(find.text('Adjust'), findsOneWidget);
      expect(find.text('Reset'), findsOneWidget);
      expect(find.text('Hold photo to compare'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('tone_reset')));
      await t.tap(find.byKey(const ValueKey('tone_auto_toggle')));
      await t.tap(find.byKey(const ValueKey('tone_vivid')));
      expect(reset, 1);
      expect(auto, isFalse);
      expect(picked, TonePreset.vivid);
    });

    testWidgets('sliders sheet: 6 sliders, live updates', (t) async {
      final seen = <ToneParams>[];
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () => showToneSliders(
                  ctx,
                  initial: ToneParams.zero,
                  onChanged: seen.add,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      for (final l in [
        'Brightness',
        'Contrast',
        'Highlights',
        'Shadows',
        'Warmth',
        'Saturation',
      ]) {
        expect(find.text(l), findsOneWidget);
      }
      await t.drag(
        find.byKey(const ValueKey('tone_slider_warmth')),
        const Offset(60, 0),
      );
      await t.pump();
      expect(seen, isNotEmpty);
      expect(seen.last.warmth, greaterThan(0));
      await t.tap(find.byKey(const ValueKey('tone_sliders_reset')));
      await t.pump();
      expect(seen.last.isNeutral, isTrue);
    });
  });

  group('preview tone (Normal capture)', () {
    late Directory dir;
    late File photo;
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AccountService.resetForTest();
      dir = Directory.systemTemp.createTempSync('v1169p');
      photo = File('${dir.path}/shot.jpg')
        ..writeAsBytesSync(
          img.encodeJpg(
            img.Image(width: 64, height: 48)..clear(img.ColorRgb8(40, 45, 70)),
          ),
        );
    });
    tearDown(() => dir.deleteSync(recursive: true));

    testWidgets('Auto Tone on, presets, hold = original, Reset', (t) async {
      final fake = _FakeEnhance();
      await t.pumpWidget(
        MaterialApp(
          home: PreviewScreen(
            imageFile: photo,
            enhanceService: fake,
            tonePreset: TonePreset.warm,
          ),
        ),
      );
      for (
        var i = 0;
        i < 40 && find.byKey(const ValueKey('tone_bar')).evaluate().isEmpty;
        i++
      ) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await t.pump();
      }
      expect(fake.jobs, isEmpty); // free, no AI
      expect(find.byKey(const ValueKey('tone_bar')), findsOneWidget);
      expect(find.textContaining('Auto Tone · Warm'), findsOneWidget);
      expect(find.textContaining('free, no AI'), findsOneWidget);

      // Press and hold → the original.
      final g = await t.startGesture(
        t.getCenter(find.byKey(const ValueKey('hold_to_compare'))),
      );
      await t.pump(const Duration(milliseconds: 700));
      expect(find.byKey(const ValueKey('hold_original')), findsOneWidget);
      expect(find.text('Original'), findsWidgets);
      await g.up();
      await t.pump();
      expect(find.byKey(const ValueKey('hold_original')), findsNothing);

      await t.tap(find.byKey(const ValueKey('tone_vivid')));
      await t.pump();
      expect(find.textContaining('Auto Tone · Vivid'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('tone_reset')));
      await t.pump();
      expect(find.textContaining('Original · free, no AI'), findsOneWidget);
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await t.pump(const Duration(seconds: 2));
    });

    testWidgets('Pro AI capture has no tone bar', (t) async {
      final fake = _FakeEnhance();
      await t.pumpWidget(
        MaterialApp(
          home: PreviewScreen(
            imageFile: photo,
            mode: CaptureMode.pro,
            enhanceService: fake,
          ),
        ),
      );
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await t.pump();
      expect(find.byKey(const ValueKey('tone_bar')), findsNothing);
      await t.pump(const Duration(seconds: 5));
    });

    testWidgets('Pro capture passes the look to the job', (t) async {
      final fake = _FakeEnhance();
      await t.pumpWidget(
        MaterialApp(
          home: PreviewScreen(
            imageFile: photo,
            mode: CaptureMode.pro,
            enhanceService: fake,
            photoLook: PhotoLook.natural,
          ),
        ),
      );
      await t.pump(const Duration(seconds: 5));
      await t.pump();
      if (fake.jobs.isNotEmpty) {
        expect(fake.jobs.first.photoLook, PhotoLook.natural);
        expect(fake.jobs.first.model, kSunburst);
      }
    });
  });
}

void _wiringTests() {
  group('home wiring', () {
    final h = File('lib/screens/home_camera_screen.dart').readAsStringSync();
    test('look chip, tone strip, burst, model hand-off', () {
      expect(
        h,
        contains('onLongPress: _burstAvailable && !_processingCapture'),
      );
      expect(h, contains('BurstReviewScreen('));
      expect(h, contains('_PhotoLookChip('));
      expect(h, contains('TonePresetStrip('));
      expect(h, contains('tonePreviewMatrix(_tonePreset)'));
      expect(
        h,
        contains("photoLook: ai && aiModeId == 'photo' && kProLookToggle"),
      );
      expect(h, contains('PhotoLook.prefsKey'));
      expect(h, contains('PhotoLook.tipSeenKey'));
      // Natural | Studio never shows in Zoom mode (always Sunburst there).
      expect(h, contains('!_zoomModeActive &&'));
      // Macro still on hold.
      expect(h, contains('kMacroComingSoon && _shootMode == ShootMode.macro'));
    });
  });
}

class _FakeEnhance extends EnhanceService {
  final jobs = <EnhanceJob>[];

  @override
  Future<EnhanceResult> enhance(EnhanceJob job, {AiCancelToken? cancel}) async {
    jobs.add(job);
    return const EnhanceResult();
  }
}
