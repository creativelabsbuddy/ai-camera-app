// v11.66 (1.11.67+80) tests: one group per agreed change.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_camera/config/ai_config.dart';
import 'package:ai_camera/models/ai_style.dart';
import 'package:ai_camera/services/account_service.dart';
import 'package:ai_camera/services/look_service.dart';
import 'package:ai_camera/services/saved_styles.dart';
import 'package:ai_camera/services/server_api_client.dart';
import 'package:ai_camera/services/style_samples.dart';
import 'package:ai_camera/widgets/look_sheet.dart';
import 'package:ai_camera/widgets/variant_pager.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_camera/models/quality_tier.dart';
import 'package:ai_camera/services/enhance_service.dart';
import 'package:ai_camera/services/macro.dart';
import 'package:ai_camera/services/macro_gates.dart';
import 'package:ai_camera/services/mode_prompts.dart';
import 'package:ai_camera/services/network_check.dart';
import 'package:ai_camera/services/openrouter_client.dart';
import 'package:ai_camera/services/runware_client.dart';
import 'package:ai_camera/services/step_timings.dart';
import 'package:ai_camera/services/tier_upscale.dart';
import 'package:ai_camera/services/zoom_assist.dart';
import 'package:ai_camera/widgets/ai_working_frame.dart';
import 'package:ai_camera/widgets/quality_sheet.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('version 1.11.67+80', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('version: 1.11.67+80'));
  });

  group('2: blur note in the waves', () {
    testWidgets('note sits centred over the waves while active', (t) async {
      await t.pumpWidget(
        const MaterialApp(
          home: SizedBox(
            width: 400,
            height: 600,
            child: AiWorkingFrame(
              active: true,
              label: 'AI',
              note: kAiBlurNote,
              child: ColoredBox(color: Colors.grey),
            ),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 500));
      expect(find.text(kAiBlurNote), findsOneWidget);
      expect(
        kAiBlurNote,
        'AI may change faces and details if the photo is too blurry. '
        'For best results, wipe the lens and add more light.',
      );
      final c = t.getCenter(find.byKey(const ValueKey('ai_blur_note')));
      final f = t.getCenter(find.byType(AiWorkingFrame));
      expect((c.dx - f.dx).abs(), lessThan(2));
      expect((c.dy - f.dy).abs(), lessThan(2));
      await t.pumpWidget(const SizedBox());
    });

    test('wired into enhance and style screens', () {
      for (final f in [
        'lib/screens/preview_screen.dart',
        'lib/screens/look_screen.dart',
      ]) {
        expect(File(f).readAsStringSync(), contains('note: kAiBlurNote'));
      }
    });
  });

  group('3: per-step timing line (test builds)', () {
    test('line format: local path and server path', () {
      final l = StepTimings(
        netMs: 180,
        uploadMs: 1240,
        flareMs: 17400,
        upscaleMs: 2900,
        resizeMs: 310,
      ).line();
      expect(
        l,
        'Net 180ms · Upload 1.2s · Flare 17.4s · Upscale 2.9s · Resize 310ms',
      );
      expect(
        StepTimings(netMs: 90, serverMs: 25100).line(),
        'Net 90ms · Server 25.1s (upload+Flare+upscale) · Upscale — · Resize —',
      );
    });

    test('NetworkCheck records the last real probe time', () async {
      final n = NetworkCheck(
        probes: [
          (_) async {
            await Future<void>.delayed(const Duration(milliseconds: 30));
            return true;
          },
        ],
      );
      expect(n.lastProbeMs, isNull);
      expect(await n.online(fresh: true), isTrue);
      expect(n.lastProbeMs, greaterThanOrEqualTo(25));
    });

    test('TimedRequest fires once the body is sent', () async {
      var sent = false;
      final c = MockClient((req) async {
        return http.Response('ok', 200);
      });
      final req = TimedRequest('POST', Uri.parse('https://x.test'), () {
        sent = true;
      })..body = '{"a":1}';
      final r = await http.Response.fromStream(await c.send(req));
      expect(r.body, 'ok');
      expect(sent, isTrue);
    });

    test('upscaleForTier reports upscale + resize times', () async {
      final hd = await upscaleForTier(
        Uint8List.fromList([1, 2, 3]),
        QualityTier.hd,
      );
      expect(hd.upscaleMs, isNull);
      expect(hd.resizeMs, isNull);
      // Runware not set up → resize fallback, both steps timed.
      final full = await upscaleForTier(
        Uint8List.fromList([1, 2, 3]),
        QualityTier.fullHd,
        runware: RunwareClient(apiKey: ''),
        resize: (b, n) async => b,
      );
      expect(full.outcome, UpscaleOutcome.resize);
      expect(full.upscaleMs, isNotNull);
      expect(full.resizeMs, isNotNull);
    });

    test('wired: enhance result → preview line only with embedded key', () {
      final e = File('lib/services/enhance_service.dart').readAsStringSync();
      expect(e, contains('timings: StepTimings('));
      final p = File('lib/screens/preview_screen.dart').readAsStringSync();
      expect(p, contains("ValueKey('ai_timing_line')"));
      expect(
        p,
        contains('_timing = AiConfig.hasEmbeddedApiKey ? r.timings?.line() : null;'),
      );
    });
  });

  group('4: quality sheet', () {
    testWidgets('only HD / Full HD / Ultra HD, no 2K, no ~K labels, 1/2/4', (
      t,
    ) async {
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showQualitySheet(ctx, QualityTier.hd),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text('Choose AI quality'), findsOneWidget);
      for (final n in ['HD', 'Full HD', 'Ultra HD']) {
        expect(find.text(n), findsOneWidget);
      }
      expect(find.text('2K'), findsNothing);
      expect(find.textContaining('Coming soon'), findsNothing);
      expect(find.textContaining('~'), findsNothing);
      expect(find.text('1 credit'), findsOneWidget);
      expect(find.text('2 credits'), findsOneWidget);
      expect(find.text('4 credits'), findsOneWidget);
      expect(
        QualityTier.picker.map((q) => q.credits).toList(),
        [1, 2, 4],
      );
    });
  });

  group('5: Microscope / Extreme / Ultra stepwise zoom', () {
    const micro = [MacroLevel.microscope, MacroLevel.extreme, MacroLevel.ultra];

    test('max 15x (device-capped), gates (v11.67: 5x and 10x)', () {
      for (final l in micro) {
        expect(macroLevelZoomMax(l, 30), 15);
        expect(macroLevelZoomMax(l, 8), 8);
        expect(macroGateZooms(l, 30), [5.0, 10.0]);
        expect(macroGateZooms(l, 8), [5.0]); // 10x not reachable
        expect(macroGateZooms(l, 4), isEmpty);
      }
      expect(macroLevelZoomMax(MacroLevel.macro, 30), 10);
      expect(macroLevelZoomMax(null, 30), 10);
    });

    test('zoom stops at each gate until its photo is done', () {
      const l = MacroLevel.microscope;
      // v11.67 gates 5x / 10x
      expect(macroGateCap(l, 30, {}), 5.0);
      expect(macroGateCap(l, 30, {5.0}), 10.0);
      expect(macroGateCap(l, 30, {5.0, 10.0}), 15);
      expect(macroGateDue(l, 30, {}, 4.2), isNull);
      expect(macroGateDue(l, 30, {}, 5), 5.0);
      expect(macroGateDue(l, 30, {5.0}, 8), isNull);
      expect(macroGateDue(l, 30, {5.0}, 10), 10.0);
      expect(macroGateDue(l, 30, {5.0, 10.0}, 12), isNull);
      // zooming back out forgets the gates above
      expect(macroGatesToDrop({5.0, 10.0}, 7), [10.0]);
      expect(macroGatesToDrop({5.0, 10.0}, 1.0), [5.0, 10.0]);
      expect(macroGatesToDrop({5.0, 10.0}, 10.0), isEmpty);
    });

    test('lock follows the highest gate; debug text', () {
      expect(macroGateLock({}), isNull);
      final lk = macroGateLock({
        1.5: (name: 'white paper napkin', part: 'surface'),
        5.0: (name: 'red soda can', part: 'side'),
      });
      expect(lk!.name, 'red soda can');
      expect(
        macroGateDebug(1.5, 'white paper napkin', 'surface'),
        '1.5x: white paper napkin · surface',
      );
      expect(macroGateDebug(5, 'red soda can', 'side', newSubject: true),
          '5x: red soda can · side · new subject');
      expect(macroGateDebug(1.5, null, ''), '1.5x: detect failed');
      expect(macroGateDebug(1.5, '', ''), '1.5x: (vague)');
    });

    test('fully blurry final frame → fail closed message', () {
      expect(microFinalTooBlurry(0), isTrue);
      expect(microFinalTooBlurry(40), isFalse);
      expect(
        kMicroTooBlurry,
        'Too close or blurry. Move back and zoom in instead.',
      );
    });

    test('3 photos to the AI: gate photos first, final last, name + part',
        () {
      final f = File('a.jpg');
      final job = EnhanceJob(
        image: f,
        mode: 'macro',
        macroLevel: 'extreme',
        subject: 'red soda can',
        part: 'side of a red soda can',
        steps: [File('s15.jpg'), File('s5.jpg')],
      );
      expect(job.microSteps, isTrue);
      expect(job.deepTextOnly, isFalse); // photos are sent
      expect(job.sentSteps.length, 2);
      if (AiConfig.kHasEmbeddedKey) {
        final p = job.prompt(hasContext: true);
        expect(p, startsWith(kMicroStepsLine));
        expect(p, contains('side of a red soda can'));
      }
      // no gate photos → the old text-only spot prompt stays
      final old = EnhanceJob(
        image: f,
        mode: 'macro',
        macroLevel: 'extreme',
        subject: 'red soda can',
        part: 'side',
      );
      expect(old.microSteps, isFalse);
      expect(old.deepTextOnly, isTrue);
      expect(macroInputPlan('microscope').maxSteps, 2);
    });

    test('home wiring: gates, no pixel match, no post-shutter 1.5x', () {
      final h = File('lib/screens/home_camera_screen.dart').readAsStringSync();
      expect(h, contains('math.min(requested, _macroGateCapZoom)'));
      expect(h, contains('_onMacroZoom();'));
      expect(h, contains('await _refocusCentre();\n      await Future<void>.delayed(kMacroGateFocusWait);'));
      expect(h, contains('gateSteps = _gateStepPhotos();'));
      expect(h, contains('? (gated\n                  ? 0 // v11.67'));
      expect(h, isNot(contains('checkpointMatch(')));
      expect(h, isNot(contains('_microOneHalf')));
      final sc = File('lib/services/server_api_client.dart').readAsStringSync();
      expect(sc, contains("if (microSteps) 'micro_steps': 'true',"));
    });
  });

  group('6: Macro / Close step photos during the zoom', () {
    test('v11.67: gates at 5x and 10x (10x = the max still runs)', () {
      for (final l in [MacroLevel.macro, MacroLevel.close]) {
        expect(macroLevelZoomMax(l, 30), 10);
        expect(macroGateZooms(l, 30), [5.0, 10.0]);
        expect(macroGateZooms(l, 3), isEmpty);
        expect(macroGateCap(l, 30, {}), 5.0);
        expect(macroGateCap(l, 30, {5.0}), 10.0);
        expect(macroGateCap(l, 30, {5.0, 10.0}), 10);
        expect(macroGateDue(l, 30, {}, 5.0), 5.0);
        expect(macroGateDue(l, 30, {5.0}, 9.9), isNull);
        expect(macroGateDue(l, 30, {5.0}, 10), 10.0);
      }
      expect(macroGateZooms(null, 30), isEmpty);
    });

    test('home wiring: gate photos at the shutter, no post-shutter steps', () {
      final h = File('lib/screens/home_camera_screen.dart').readAsStringSync();
      // v11.67: every level detects at its gates.
      expect(h, contains('      await _detectAtGate(g, shot.path, dig, gen);'));
      expect(h, isNot(contains('if (level.isMicroscopic) await _detectAtGate(')));
      expect(h, isNot(contains('_takeMacroContext(')));
      expect(h, isNot(contains('_macroCtx')));
      expect(h, contains('subject = kMacroGeneralSubject;'));
    });
  });

  group('7: manual Bright spot button replaces the automatic latch', () {
    test('label + no automatic latch left', () {
      expect(kBrightSpotLabel, 'Bright spot ☀️');
      final h = File('lib/screens/home_camera_screen.dart').readAsStringSync();
      final z = File('lib/services/zoom_assist.dart').readAsStringSync();
      expect(z, isNot(contains('class BrightMeter')));
      expect(z, isNot(contains('kLatchOnZoom')));
      expect(h, isNot(contains('_bright.update(')));
      expect(h, isNot(contains('kLatchIdle')));
      expect(h, isNot(contains('auto_focus_chip')));
      // off by default; on = the old manual 1/250 s ISO 100 (EV-min fallback)
      expect(h, contains('bool _brightApplied = false;'));
      expect(h, contains('await _engageLatch();'));
      expect(h, contains('_latchEv = await c.setExposureOffset(_minExposureOffset);'));
      expect(kLatchStartNs, 4000000);
      expect(kLatchIso, 100);
      // Zoom-mode only button; off when leaving Zoom mode / app paused
      expect(h, contains("key: const ValueKey('bright_spot_chip')"));
      expect(h, contains('if (_zoomModeActive) ...['));
      expect(h, contains('if (_brightApplied) await _releaseLatch();'));
      expect(h, contains('if (_brightApplied) unawaited(_releaseLatch()); // v11.39'));
    });
  });

  group('8: style variants (swipe inside the card)', () {
    final json = {
      'id': 'neon',
      'name': 'Neon',
      'category': 'Mood',
      'credit_cost': 2,
      'variants': [
        {'id': 'v_b', 'name': 'Blue', 'sample_url': '/media/styles/b.jpg', 'sort_order': 1},
        {'id': 'v_a', 'name': 'Pink', 'sample_url': 'https://cdn/a.jpg', 'sort_order': 0},
        {'id': 'v_c', 'name': 'Green', 'sort_order': 2},
      ],
    };

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AccountService.resetForTest();
      SavedStyles.resetForTest(SavedStyles());
      StyleSamples.resetForTest(StyleSamples(url: '', key: ''));
    });

    test('parses variants (ordered, URLs resolved); no prompts in the app', () {
      final s = AiStyle.fromJson(json, baseUrl: 'https://srv/');
      expect(s.hasVariants, isTrue);
      expect([for (final v in s.variants) v.id], ['v_a', 'v_b', 'v_c']);
      expect(s.variants[1].sampleUrl, 'https://srv/media/styles/b.jpg');
      expect(s.variants[2].sampleUrl, isNull);
      expect(s.variantId, isNull);
      expect(s.displayName, 'Neon');
      // Cache round trip keeps them.
      final back = AiStyle.fromJson(s.toJson());
      expect([for (final v in back.variants) v.name], ['Pink', 'Blue', 'Green']);
      expect(jsonEncode(s.toJson()), isNot(contains('prompt')));
    });

    test('0 or 1 variant → normal card; old servers without the field', () {
      final one = AiStyle.fromJson({
        ...json,
        'variants': [(json['variants'] as List).first],
      });
      expect(one.variants.length, 1);
      expect(one.hasVariants, isFalse);
      expect(one.withVariant('v_b').variantId, isNull);
      final none = AiStyle.fromJson({'id': 'x', 'name': 'X'});
      expect(none.variants, isEmpty);
      expect(none.hasVariants, isFalse);
      expect(AiStyle.fromJson({'id': 'y', 'variants': 'junk'}).variants, isEmpty);
    });

    test('withVariant: chosen look, same credits / model; unknown id → none', () {
      final s = AiStyle.fromJson(json);
      final c = s.withVariant('v_b');
      expect(c.variantId, 'v_b');
      expect(c.variantIndex, 1);
      expect(c.displayName, 'Neon · Blue');
      expect(c.creditCost, s.creditCost);
      expect(c.model, s.model);
      expect(c.id, 'neon');
      expect(s.withVariant('nope').variantId, isNull);
      expect(c.withAsset('a.png').variantId, 'v_b');
      final job = LookJob(image: File('x'), style: c);
      expect(job.variantId, 'v_b');
      expect(job.label, 'Neon · Blue');
      expect(job.creditCostPerImage, 2);
      expect(LookJob(image: File('x'), style: s).variantId, isNull);
      expect(variantCountLabel(1, 7), '2/7');
    });

    test('applyLook sends only variant_id (never a prompt) with the style', () async {
      final dir = Directory.systemTemp.createTempSync('v1166v');
      final im = img.Image(width: 64, height: 64);
      final f = File('${dir.path}/p.jpg')..writeAsBytesSync(img.encodeJpg(im));
      final bodies = <String>[];
      final mock = MockClient((req) async {
        bodies.add(latin1.decode(req.bodyBytes));
        return http.Response(
          jsonEncode({
            'images': [base64Encode(img.encodeJpg(im))],
            'credits_charged': 2,
            'trials_used': [],
          }),
          200,
        );
      });
      final c = ServerApiClient(httpClient: mock);
      await c.applyLook(baseUrl: 'https://x', deviceId: 'd', image: f, styleId: 'neon', variantId: 'v_b');
      expect(bodies.last, contains('name="variant_id"'));
      expect(bodies.last, contains('v_b'));
      expect(bodies.last, isNot(contains('name="custom_prompt"')));
      await c.applyLook(baseUrl: 'https://x', deviceId: 'd', image: f, styleId: 'neon');
      expect(bodies.last, isNot(contains('variant_id')));
      await c.applyLook(baseUrl: 'https://x', deviceId: 'd', image: f, customPrompt: 'hat', variantId: 'v_b');
      expect(bodies.last, isNot(contains('variant_id')));
    });

    Future<LookSheetResult?> openSheet(WidgetTester t, AiStyle s) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 2.6;
      addTearDown(t.view.reset);
      LookSheetResult? out;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () async => out = await showLookSheet(ctx, style: s),
              child: const Text('go'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('go'));
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      return out;
    }

    testWidgets('swipe inside the card → the visible variant is applied', (t) async {
      final s = AiStyle.fromJson(json);
      LookSheetResult? out;
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 2.6;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () async => out = await showLookSheet(ctx, style: s),
              child: const Text('go'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('look_variant_pager')), findsOneWidget);
      expect(find.byKey(const ValueKey('look_frame_look')), findsNothing);
      expect(find.text('1/3'), findsOneWidget);
      final frame = t.getRect(find.byKey(const ValueKey('look_variant_frame')));
      expect(frame.width / frame.height, closeTo(9 / 16, 1e-6));
      await t.drag(find.byKey(const ValueKey('look_variant_pager')), Offset(-frame.width * 0.7, 0));
      await t.pumpAndSettle();
      expect(find.text('2/3'), findsOneWidget);
      expect(find.text('Blue'), findsOneWidget); // frame label = variant name
      await t.tap(find.byKey(const ValueKey('look_take_photo')));
      await t.pumpAndSettle();
      expect(out!.action, LookSheetAction.takePhoto);
      expect(out!.style!.id, 'neon');
      expect(out!.style!.variantId, 'v_b');
    });

    testWidgets('reopening starts on the chosen variant', (t) async {
      final s = AiStyle.fromJson(json).withVariant('v_c');
      await openSheet(t, s);
      await t.pumpAndSettle();
      expect(find.text('3/3'), findsOneWidget);
    });

    testWidgets('one variant → normal card, no variant id', (t) async {
      final s = AiStyle.fromJson({
        ...json,
        'variants': [(json['variants'] as List).first],
      });
      LookSheetResult? out;
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 2.6;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () async => out = await showLookSheet(ctx, style: s),
              child: const Text('go'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('look_variant_pager')), findsNothing);
      expect(find.byKey(const ValueKey('look_frame_look')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('look_take_photo')));
      await t.pumpAndSettle();
      expect(out!.style!.variantId, isNull);
    });

    test('wiring: variant flows to the server call and pending look', () {
      final svc = File('lib/services/look_service.dart').readAsStringSync();
      expect(svc, contains('variantId: job.variantId'));
      expect(svc, contains("'This look needs the server'"));
      final ls = File('lib/screens/look_screen.dart').readAsStringSync();
      expect('r.style ?? style'.allMatches(ls).length, 3);
      final home = File('lib/screens/home_camera_screen.dart').readAsStringSync();
      expect(home, contains('style: r.style ?? pick.style'));
      final lib = File('lib/widgets/style_library_sheet.dart').readAsStringSync();
      expect(lib, contains('StylePick.style(chosen)'));
    });
  });
}
