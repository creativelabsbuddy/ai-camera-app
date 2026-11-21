// v11.66 (1.11.66+79) tests: one group per agreed change.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_camera/config/ai_config.dart';
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
import 'package:ai_camera/widgets/ai_working_frame.dart';
import 'package:ai_camera/widgets/quality_sheet.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
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

    test('max 15x (device-capped), gates at 1.5x and 5x', () {
      for (final l in micro) {
        expect(macroLevelZoomMax(l, 30), 15);
        expect(macroLevelZoomMax(l, 8), 8);
        expect(macroGateZooms(l, 30), [1.5, 5.0]);
        expect(macroGateZooms(l, 4), [1.5]); // 5x not reachable
      }
      expect(macroLevelZoomMax(MacroLevel.macro, 30), 10);
      expect(macroLevelZoomMax(null, 30), 10);
    });

    test('zoom stops at each gate until its photo is done', () {
      const l = MacroLevel.microscope;
      expect(macroGateCap(l, 30, {}), 1.5);
      expect(macroGateCap(l, 30, {1.5}), 5.0);
      expect(macroGateCap(l, 30, {1.5, 5.0}), 15);
      expect(macroGateDue(l, 30, {}, 1.2), isNull);
      expect(macroGateDue(l, 30, {}, 1.5), 1.5);
      expect(macroGateDue(l, 30, {1.5}, 3), isNull);
      expect(macroGateDue(l, 30, {1.5}, 5), 5.0);
      expect(macroGateDue(l, 30, {1.5, 5.0}, 12), isNull);
      // zooming back out forgets the gates above
      expect(macroGatesToDrop({1.5, 5.0}, 3), [5.0]);
      expect(macroGatesToDrop({1.5, 5.0}, 1.0), [1.5, 5.0]);
      expect(macroGatesToDrop({1.5, 5.0}, 5.0), isEmpty);
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
      expect(h, contains('(gated ? 0 : kMacroCtxMargin)'));
      expect(h, isNot(contains('checkpointMatch(')));
      expect(h, isNot(contains('_microOneHalf')));
      final sc = File('lib/services/server_api_client.dart').readAsStringSync();
      expect(sc, contains("if (microSteps) 'micro_steps': 'true',"));
    });
  });
}
