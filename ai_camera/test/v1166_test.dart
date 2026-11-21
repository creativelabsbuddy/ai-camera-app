// v11.66 (1.11.66+79) tests: one group per agreed change.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_camera/models/quality_tier.dart';
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
}
