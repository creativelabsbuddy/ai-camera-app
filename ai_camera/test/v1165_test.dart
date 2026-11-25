import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_camera/models/products.dart';
import 'package:ai_camera/models/quality_tier.dart';
import 'package:ai_camera/services/account_service.dart';
import 'package:ai_camera/services/mode_prompts.dart';
import 'package:ai_camera/services/prompt_builder.dart';
import 'package:ai_camera/services/runware_client.dart';
import 'package:ai_camera/services/tier_upscale.dart';
import 'package:ai_camera/services/upload_prep.dart';
import 'package:ai_camera/services/video_service.dart';
import 'package:ai_camera/widgets/video_style_flow.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

Uint8List _jpg(int w, int h) =>
    Uint8List.fromList(img.encodeJpg(img.Image(width: w, height: h)..clear(img.ColorRgb8(90, 140, 60))));

(int, int) _size(Uint8List b) {
  final d = img.decodeImage(b)!;
  return (d.width, d.height);
}

class _Be implements VideoBackend {
  _Be(this.states);
  final List<String> states;
  int polls = 0;
  final submitted = <VideoRequest>[];
  @override
  bool get chargesLocally => true;
  @override
  Future<String> submit(VideoRequest r) async {
    submitted.add(r);
    return '${r.provider.name}~req123456';
  }

  @override
  Future<VideoStatus> status(String jobId) async {
    final s = states[polls < states.length ? polls : states.length - 1];
    polls++;
    if (s == 'failed') return const VideoStatus('failed', error: 'boom');
    return VideoStatus(s, url: s == 'done' ? 'https://x/v.mp4' : null);
  }

  @override
  Future<void> cancel(String jobId) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('version 1.11.69+82', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('version: 1.11.69+82'));
  });

  group('prompts', () {
    const face =
        'Keep every face exactly the same person: same face shape, eyes, nose, lips, skin tone and expression.';
    test('face/detail-preserving zoom + portrait prompts', () {
      expect(kUniversalEnhancePrompt, 'Restore this photo: remove blur, noise, pixelation and compression artifacts, and recover natural fine detail with realistic textures, without oversharpening or plastic-looking skin. Keep the exact same scene, framing, people, objects, colours and identity; do not add, remove or redesign anything, and do not invent facial details. Where details are irrecoverable, preserve natural softness rather than inventing information.');
      expect(kPhotoCleanupPrompt, 'Clean up and sharpen this image, with a natural tone. $face Do not change, add or remove anything; keep all shapes, text and details as they are.');
      expect(kZoomCleanPrompt, '$kPhotoCleanupPrompt $kNoInventLine');
      expect(kPortraitEnhancePrompt,
          'Clean up and sharpen this image, with a natural tone. $face Blur only the background with a natural bokeh, and keep the subject sharp. Do not change, add or remove anything else.');
      expect(kPortraitPrompt, kPortraitEnhancePrompt);
    });

    test('macro frame-fill: Microscope 3–4 threads, Extreme one thread, Ultra 2–3 SEM fibres', () {
      expect(kMacroMicroscopePrompt, contains('three or four threads and their weave filling the whole frame'));
      expect(kMacroExtremePrompt, contains('one single thread filling the whole frame, with no weave visible'));
      expect(kMacroUltraPrompt, contains('two or three fibres with their fine SEM-style surface scales'));
      for (final t in [kMacroExtremePrompt, kMacroUltraPrompt]) {
        expect(t, isNot(contains('woven')));
      }
      for (final t in [kMacroMicroscopePrompt, kMacroExtremePrompt, kMacroUltraPrompt]) {
        expect(t, contains('{spot}{on_object}'));
      }
    });
  });

  group('tiers', () {
    test('picker has no 4K; stored 4k → Ultra HD; credits unchanged', () {
      expect(QualityTier.picker, [QualityTier.hd, QualityTier.fullHd, QualityTier.ultraHd]);
      expect(QualityTier.pickable('4k'), QualityTier.ultraHd);
      expect([QualityTier.hd.credits, QualityTier.fullHd.credits, QualityTier.ultraHd.credits], [1, 2, 4]);
      expect(QualityTier.hd.upscaleLongSide, isNull);
      expect(QualityTier.fullHd.upscaleLongSide, 1920);
      expect(QualityTier.ultraHd.upscaleLongSide, 2560);
      expect(QualityTier.k4.upscaleLongSide, 2560);
    });

    test('Runware upscale task: Real-ESRGAN 2x, no prompt', () {
      final t = buildRunwareUpscaleTask(imageDataUrl: 'data:image/jpeg;base64,xx', taskUuid: 'u');
      expect(t, {
        'taskType': 'upscale',
        'taskUUID': 'u',
        'model': 'runware:504@1',
        'upscaleFactor': 2,
        'inputs': {'image': 'data:image/jpeg;base64,xx'},
        'outputType': 'base64Data',
        'outputFormat': 'JPG',
        'includeCost': true,
      });
    });

    setUp(() => UploadPrep.nativeDecode = false);
    tearDown(() => UploadPrep.nativeDecode = true);

    test('HD: delivered as-is, no Runware call', () async {
      var calls = 0;
      final rw = RunwareClient(apiKey: 'k', client: MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      }));
      final src = _jpg(96, 128);
      final r = await upscaleForTier(src, QualityTier.hd, runware: rw);
      expect(r.outcome, UpscaleOutcome.none);
      expect(identical(r.bytes, src), isTrue);
      expect(calls, 0);
    });

    for (final (tier, long) in [(QualityTier.fullHd, 1920), (QualityTier.ultraHd, 2560)]) {
      test('${tier.label}: ESRGAN 2x then resized to $long', () async {
        late Map<String, Object?> sent;
        final rw = RunwareClient(apiKey: 'k', client: MockClient((req) async {
          sent = ((jsonDecode(req.body) as List).first as Map).cast<String, Object?>();
          final b64 = '${(sent['inputs'] as Map)['image']}'.split(',').last;
          final d = img.decodeImage(base64Decode(b64))!;
          final up = img.copyResize(d, width: d.width * 2, height: d.height * 2);
          return http.Response(jsonEncode({
            'data': [
              {'taskType': 'imageUpscale', 'imageBase64Data': base64Encode(img.encodeJpg(up)), 'cost': 0.0006},
            ],
          }), 200);
        }));
        final r = await upscaleForTier(_jpg(576, 768), tier, runware: rw);
        expect(r.outcome, UpscaleOutcome.esrgan);
        expect(sent['taskType'], 'upscale');
        expect(sent['model'], 'runware:504@1');
        final (w, h) = _size(r.bytes);
        expect(h, long);
        expect(w, (long * 3 / 4).round());
      });
    }

    test('insufficientCredits → resize fallback, never throws', () async {
      final rw = RunwareClient(apiKey: 'k', client: MockClient((_) async => http.Response(
          '{"errors":[{"code":"insufficientCredits","message":"Insufficient credits"}]}', 400)));
      final r = await upscaleForTier(_jpg(576, 768), QualityTier.ultraHd, runware: rw);
      expect(r.outcome, UpscaleOutcome.resize);
      expect(_size(r.bytes).$2, 2560);
    });

    test('no Runware key → resize fallback', () async {
      final r = await upscaleForTier(_jpg(576, 768), QualityTier.fullHd, runware: RunwareClient(apiKey: ''));
      expect(r.outcome, UpscaleOutcome.resize);
      expect(_size(r.bytes).$2, 1920);
    });

    test('resizeToLongSide downsizes too', () async {
      final out = await resizeToLongSide(_jpg(300, 400), 200);
      expect(_size(out), (150, 200));
    });
  });

  group('Fast ⚡ video (fal)', () {
    test('credits: Fast = Standard for now (TBD)', () {
      final t = defaultVideoCredits();
      for (final r in kMiniMaxResolutions) {
        for (final s in kVideoLengths) {
          expect(t['fal_${s}_$r'], t['minimax_${s}_$r']);
        }
      }
      const r = VideoRequest(kind: VideoKind.t2v, prompt: 'x', fast: true);
      expect(r.provider, VideoProvider.fal);
      expect(r.creditKey, 'fal_5_480p');
      expect(const VideoRequest(kind: VideoKind.t2v, prompt: 'x').provider, VideoProvider.minimax);
    });

    test('fal body params', () {
      expect(
        buildFalBody(VideoKind.i2v, prompt: 'p', seconds: 8, resolution: '768p', aspect: '9:16', imageUrl: 'data:x'),
        {
          'prompt': 'p',
          'duration': 8,
          'resolution': '768P',
          'prompt_expansion_mode': 'disabled',
          'enable_safety_checker': true,
          'image_url': 'data:x',
        },
      );
      final t = buildFalBody(VideoKind.t2v, prompt: 'p', seconds: 5, resolution: '480p', aspect: '16:9');
      expect(t['aspect_ratio'], '16:9');
      expect(t.containsKey('image_url'), isFalse);
      expect(falModelPath(VideoKind.i2v), 'minimax/h3-max-turbo/image-to-video');
      expect(falModelPath(VideoKind.t2v), 'minimax/h3-max-turbo/text-to-video');
    });

    test('direct fal: submit → queue → done; failed result → failed', () async {
      final calls = <http.Request>[];
      var state = 'IN_QUEUE';
      var resultCode = 200;
      final be = DirectVideoBackend(client: MockClient((r) async {
        calls.add(r);
        final p = r.url.path;
        if (r.method == 'POST' && p == '/minimax/h3-max-turbo/text-to-video') {
          return http.Response('{"request_id":"falreq123"}', 200);
        }
        if (p == '/minimax/h3-max-turbo/requests/falreq123/status') {
          return http.Response('{"status":"$state"}', 200);
        }
        if (p == '/minimax/h3-max-turbo/requests/falreq123') {
          return resultCode == 200
              ? http.Response('{"video":{"url":"https://v3.fal.media/x.mp4"}}', 200)
              : http.Response('{"detail":"failed"}', resultCode);
        }
        return http.Response('{}', 404);
      }));
      final id = await be.submit(const VideoRequest(kind: VideoKind.t2v, prompt: 'waves', aspect: '16:9', fast: true));
      expect(id, 'fal~falreq123');
      expect(calls.first.url.host, 'queue.fal.run');
      expect(calls.first.headers['Authorization'], startsWith('Key '));
      expect((jsonDecode(calls.first.body) as Map)['resolution'], '480P');
      expect((await be.status(id)).state, 'queued');
      state = 'IN_PROGRESS';
      expect((await be.status(id)).state, 'running');
      state = 'COMPLETED';
      final st = await be.status(id);
      expect(st.state, 'done');
      expect(st.url, 'https://v3.fal.media/x.mp4');
      resultCode = 422;
      expect((await be.status(id)).state, 'failed');
    });

    group('service', () {
      setUp(() async {
        SharedPreferences.setMockInitialValues({});
        AccountService.resetForTest();
        await AccountService.instance.ledger.purchase(kProducts.firstWhere((p) => p.id == 'pack_25'));
      });

      test('Make it Fast after a failed Standard job: same video on fal, charged once', () async {
        final std = _Be(['running', 'failed']);
        final fast = _Be(['queued', 'done']);
        final s = VideoService(
          backend: (p) async => p == VideoProvider.fal ? fast : std,
          download: (u) async => File('${Directory.systemTemp.path}/v1165.mp4')..writeAsBytesSync([1]),
          pollEvery: const Duration(milliseconds: 1),
        );
        await s.start(const VideoRequest(kind: VideoKind.t2v, prompt: 'waves', seconds: 8, resolution: '768p'));
        for (var i = 0; i < 200 && s.job.value!.active; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        expect(s.job.value!.phase, VideoPhase.failed);
        expect(s.job.value!.canMakeFast(DateTime.now()), isTrue);
        await s.makeFast();
        for (var i = 0; i < 200 && s.job.value!.active; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        expect(fast.submitted.single.fast, isTrue);
        expect(fast.submitted.single.seconds, 8);
        expect(fast.submitted.single.resolution, '768p');
        expect(s.job.value!.phase, VideoPhase.done);
        expect(s.job.value!.creditsCharged, defaultVideoCredits()['minimax_8_768p']);
        expect(s.job.value!.canMakeFast(DateTime.now()), isFalse);
      });

      test('a Standard job waiting 3+ min can switch to Fast', () {
        final j = VideoJob(
          request: const VideoRequest(kind: VideoKind.t2v, prompt: 'x'),
          phase: VideoPhase.queued,
          started: DateTime.now().subtract(const Duration(minutes: 4)),
          credits: 3,
        );
        expect(j.canMakeFast(DateTime.now()), isTrue);
        final fresh = VideoJob(
          request: const VideoRequest(kind: VideoKind.t2v, prompt: 'x'),
          phase: VideoPhase.queued,
          started: DateTime.now(),
          credits: 3,
        );
        expect(fresh.canMakeFast(DateTime.now()), isFalse);
      });
    });

    testWidgets('speed chips: hidden without Fast, Standard / Fast labels when available', (t) async {
      final s = VideoService(backend: (_) async => null);
      await t.pumpWidget(MaterialApp(home: Scaffold(body: VideoSpeedChips(svc: s))));
      expect(find.byKey(const ValueKey('video_speed_fast')), findsNothing);
      s.fastAvailable.value = true;
      await t.pump();
      expect(find.text('Standard · May take 10–15 min'), findsOneWidget);
      expect(find.text('Fast ⚡ · Ready in seconds'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('video_speed_fast')));
      await t.pump();
      expect(s.preferFast.value, isTrue);
      expect(wantsFast(s), isTrue);
    });
  });
}
