// v11.58: microscope lock + material-aware prompts, refunds, video timeout /
// Phosor 202 / notification / AI-generated label, per-style model routing,
// universal DSLR prompt, no q90 / 1920 upscale.
import 'dart:convert';
import 'dart:io';

import 'package:ai_camera/config/ai_config.dart';
import 'package:ai_camera/models/ai_style.dart';
import 'package:ai_camera/models/products.dart';
import 'package:ai_camera/models/quality_tier.dart';
import 'package:ai_camera/services/account_service.dart';
import 'package:ai_camera/services/entitlements.dart';
import 'package:ai_camera/services/filter_catalog.dart';
import 'package:ai_camera/services/look_service.dart';
import 'package:ai_camera/services/micro_lock.dart';
import 'package:ai_camera/services/mode_prompts.dart';
import 'package:ai_camera/services/openrouter_client.dart';
import 'package:ai_camera/services/prompt_builder.dart';
import 'package:ai_camera/services/runware_client.dart';
import 'package:ai_camera/services/upload_prep.dart';
import 'package:ai_camera/services/video_notifier.dart';
import 'package:ai_camera/services/video_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SlowBackend implements VideoBackend {
  int cancels = 0;
  @override
  bool get chargesLocally => true;
  @override
  Future<String> submit(VideoRequest r) async => 'minimax~r1';
  @override
  Future<VideoStatus> status(String jobId) async => const VideoStatus('running');
  @override
  Future<void> cancel(String jobId) async => cancels++;
}

void main() {
  test('version (v11.61: 1.11.61+74)', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('version: 1.11.61+74'));
  });

  group('microscope: lock at 1.5x, part only, material-aware', () {
    test('prompts never hardcode cells and name the material', () {
      for (final t in [kMacroMicroscopePrompt, kMacroExtremePrompt, kMacroUltraPrompt]) {
        expect(t.toLowerCase(), isNot(contains('cells')));
        expect(t, contains('{spot}'));
        expect(t, contains('{on_object}'));
        expect(t, contains('material'));
      }
      expect(kMacroMicroscopePrompt, contains('painted metal shows paint grains, printing dots and light scratches'));
      expect(kMacroMicroscopePrompt, contains('100x'));
      expect(kMacroExtremePrompt, contains('1000x'));
      expect(kMacroUltraPrompt, contains('2000x'));
    });

    test('part first, locked object after; never replaced', () {
      final p = macroPrompt('red painted metal soda can', level: 'microscope', part: 'white printed logo');
      expect(p, startsWith('A tiny area of white printed logo on the red painted metal soda can under a light microscope'));
      final e = macroPrompt('red painted metal soda can', level: 'extreme', part: 'white printed logo');
      expect(e, contains('white printed logo on the red painted metal soda can'));
      // Part already names the object → no " on the …".
      expect(onObjectText('soda can', 'soda can rim'), '');
      expect(onObjectText('close-up', 'tiny hairs'), '');
      expect(microPartText('', 'red soda can'), 'red soda can');
      expect(microPartText('shiny', 'red soda can'), 'red soda can'); // vague
      expect(microPartText('ring pull tab', 'red soda can'), 'ring pull tab');
    });

    test('frame mismatch rule', () {
      expect(microFrameMismatch(pixelScore: 0.9, inScene: true), isFalse);
      expect(microFrameMismatch(pixelScore: 0.9, inScene: false), isTrue);
      expect(microFrameMismatch(pixelScore: -0.2, inScene: null), isTrue);
      expect(microFrameMismatch(pixelScore: -0.2, inScene: true), isFalse);
      expect(kMicroHoldSteady, 'Hold steady');
      expect(kMicroRetakes, 2);
    });

    test('home wiring: 1.5x photo, lock, part, retake', () {
      final h = File('lib/screens/home_camera_screen.dart').readAsStringSync();
      expect(h, contains('planZoom(requested: kMacroDetectZoom'));
      expect(h, contains('_detector.detectSubjectTimed(File(half.path))'));
      expect(h, contains('_detector.detectPart('));
      expect(h, contains('_showToast(kMicroHoldSteady)'));
      expect(h, contains('final r = await _takeMacro(c);'));
      expect(h, contains('bool get _macroLowEnd => _cameraClass.lowEnd;'));
    });
  });

  group('refund a bad Microscope result', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AccountService.resetForTest();
    });

    test('refundDecision gives back the same buckets', () async {
      final acct = AccountService.instance;
      await acct.ledger.purchase(kProducts.firstWhere((p) => p.id == 'pack_25'));
      final before = await acct.refresh();
      final d = await acct.commitLocal(const EnhanceSpec(tier: QualityTier.fullHd));
      expect(d.allowed, isTrue);
      final mid = await acct.refresh();
      expect(mid.freeDaily + mid.packCredits, before.freeDaily + before.packCredits - d.credits);
      await acct.refundLocal(d);
      final after = await acct.refresh();
      expect(after.freeDaily, before.freeDaily);
      expect(after.packCredits, before.packCredits);
    });

    test('preview offers the refund only for microscopic local charges', () {
      final p = File('lib/screens/preview_screen.dart').readAsStringSync();
      expect(p, contains("ValueKey('micro_refund')"));
      expect(p, contains('_isMicroscope && lc != null'));
      expect(p, contains('Bad result? Refund'));
    });
  });

  group('video', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      AccountService.resetForTest();
      await AccountService.instance.ledger.purchase(kProducts.firstWhere((p) => p.id == 'pack_25'));
    });

    test('30 min timeout → refunded message, provider cancelled, no charge, notified', () async {
      final notes = <String>[];
      VideoNotifier.debugSink = (t, b) => notes.add('$t|$b');
      addTearDown(() => VideoNotifier.debugSink = null);
      final be = _SlowBackend();
      final s = VideoService(
        backend: (_) async => be,
        pollEvery: const Duration(milliseconds: 1),
        maxWait: const Duration(milliseconds: 30),
      );
      final st = await AccountService.instance.refresh();
      final before = st.freeDaily + st.packCredits + st.subCredits;
      await s.start(const VideoRequest(kind: VideoKind.t2v, prompt: 'x', seconds: 10, resolution: '480p'));
      for (var i = 0; i < 200 && s.job.value!.active; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(s.job.value!.phase, VideoPhase.failed);
      expect(s.job.value!.error, kVideoTimeoutMessage);
      expect(be.cancels, 1);
      final a = await AccountService.instance.refresh();
      expect(a.freeDaily + a.packCredits + a.subCredits, before);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(notes.single, startsWith('Your AI video could not be made|No video after 30 min'));
    });

    test('defaults and texts', () {
      expect(kVideoTimeout, const Duration(minutes: 30));
      expect(VideoService().maxWait, const Duration(minutes: 30));
      expect(kLongVideoWaitNote, 'Usually ready in 15–20 min');
      expect(kAiGeneratedLabel, 'AI-generated');
      final v = File('lib/services/video_service.dart').readAsStringSync();
      expect(v, contains('if (rr.statusCode == 202) return const VideoStatus(\'running\');'));
      // Routing unchanged: 8scale ≤5 s, MiniMax > 5 s.
      expect(providerFor(5), VideoProvider.wan);
      expect(providerFor(8), VideoProvider.minimax);
    });

    test('done → "ready" notification', () async {
      final notes = <String>[];
      VideoNotifier.debugSink = (t, b) => notes.add(t);
      addTearDown(() => VideoNotifier.debugSink = null);
      await VideoNotifier.instance.show('Your AI video is ready', 'x');
      expect(notes, ['Your AI video is ready']);
    });
  });

  group('styles model routing', () {
    test('AiStyle.model: default Klein, unknown → Custom', () {
      expect(AiStyle.fromJson({'id': 'a'}).model, kStyleModelKlein);
      expect(AiStyle.fromJson({'id': 'a', 'model': 'runware_klein4b'}).model, kStyleModelRunware);
      expect(AiStyle.fromJson({'id': 'a', 'model': 'zzz'}).model, kStyleModelCustom);
      expect(AiStyle.fromJson({'id': 'a', 'model': 'klein'}).toJson()['model'], 'klein');
    });

    test('Runware without a key falls back to Custom', () {
      const s = AiStyle(id: 'x', name: 'x', category: 'x', creditCost: 2, model: kStyleModelRunware);
      expect(styleModelFor(s, runwareReady: false), kStyleModelCustom);
      expect(styleModelFor(s, runwareReady: true), kStyleModelRunware);
      expect(styleModelFor(null, runwareReady: true), kStyleModelCustom);
    });

    test('Klein payload: photo only, no quality / resolution', () {
      final p = buildLookPayload(
        prompt: 'p',
        tier: QualityTier.fullHd,
        aspectRatio: '3:4',
        imageDataUrl: 'data:x',
        referenceDataUrls: const ['data:r'],
        model: AiConfig.kleinModel,
      );
      expect(p['model'], 'black-forest-labs/flux-3-image-klein');
      expect(p.containsKey('quality'), isFalse);
      expect(p.containsKey('resolution'), isFalse);
      final f = buildLookPayload(prompt: 'p', tier: QualityTier.fullHd, aspectRatio: '3:4', imageDataUrl: 'd');
      expect(f['model'], AiConfig.model);
      expect(f['quality'], 'medium');
    });

    test('Runware task', () {
      final t = buildRunwareTask(prompt: 'p', imageDataUrl: 'data:x', width: 3000, height: 4000, taskUuid: 'u');
      expect(t['taskType'], 'imageInference');
      expect(t['model'], 'runware:400@4');
      expect((t['width'], t['height']), (768, 1024));
      expect(((t['inputs'] as Map)['referenceImages'] as List).single, 'data:x');
      expect(runwareSize(1080, 1920).$2, 1024);
      expect(jsonEncode(t), isNot(contains('Bearer')));
    });
  });

  group('enhance prompt + upload', () {
    test('one universal DSLR prompt; Portrait variant replaces it', () {
      expect(kUniversalEnhancePrompt, startsWith('Enhance this photo so it looks like it was shot on a professional DSLR camera'));
      expect(buildEnhancePrompt(zoom: 30, opticalLimit: 3, night: true), kUniversalEnhancePrompt);
      final p = buildEnhancePrompt(portrait: true);
      expect(p, kPortraitEnhancePrompt);
      expect(kPortraitEnhancePrompt, contains('100% sharp'));
      expect(kPortraitEnhancePrompt, contains('bokeh'));
      expect(kPortraitPrompt, kPortraitEnhancePrompt);
    });

    test('no q90 re-encode, no 1920 upscale', () {
      expect(kUploadJpegQuality, 100);
      final o = File('lib/services/openrouter_client.dart').readAsStringSync();
      expect(o, isNot(contains('ensureMinLongSide(bytes')));
    });
  });

  test('filters keep the Custom model by default', () {
    expect(kVividFilter.model, kStyleModelCustom);
    expect(AiStyle.fromJson({'id': 'f', 'name': 'F', 'kind': 'filter'}).model, kStyleModelCustom);
    expect(AiStyle.fromJson({'id': 's', 'name': 'S', 'kind': 'style'}).model, kStyleModelKlein);
    expect(File('lib/services/filter_catalog.dart').readAsStringSync(), contains('kind,model'));
  });
}
