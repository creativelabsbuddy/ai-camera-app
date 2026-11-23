// v11.63: Phosor-only video, simple enhance prompts, last photo always sent.
import 'dart:io';

import 'package:ai_camera/services/enhance_service.dart';
import 'package:ai_camera/services/prompt_builder.dart';
import 'package:ai_camera/services/mode_prompts.dart';
import 'package:ai_camera/services/video_service.dart';
import 'package:ai_camera/services/zoom_root.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('version 1.11.68+81', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('version: 1.11.68+81'));
  });

  group('video: Phosor MiniMax only', () {
    test('every length is MiniMax; 5 s resolutions are 480p/768p', () {
      for (final s in kVideoLengths) {
        expect(providerFor(s), VideoProvider.minimax);
        expect(resolutionsFor(s), ['480p', '768p']);
      }
      expect(kVideoLengths, [5, 8, 10, 15]);
    });

    test('credits: 5 s 480p=3, 5 s 768p=7; 8/10/15 unchanged', () {
      final t = defaultVideoCredits();
      expect(t['minimax_5_480p'], 3);
      expect(t['minimax_5_768p'], 7);
      expect(t['minimax_8_480p'], 7);
      expect(t['minimax_8_768p'], 11);
      expect(t['minimax_10_480p'], 9);
      expect(t['minimax_10_768p'], 13);
      expect(t['minimax_15_480p'], 13);
      expect(t['minimax_15_768p'], 20);
      expect(t.containsKey('wan_5_480p'), isFalse);
      expect(
        const VideoRequest(kind: VideoKind.t2v, prompt: 'x', seconds: 5, resolution: '480p')
            .creditKey,
        'minimax_5_480p',
      );
    });

    test('DirectVideoBackend source has no 8scale submit/status/cancel', () {
      final v = File('lib/services/video_service.dart').readAsStringSync();
      expect(v, isNot(contains('8scale.run')));
      expect(v, isNot(contains('/wan-2.2/')));
      expect(v, contains('AiConfig.phosorBaseUrl'));
      expect(v, contains("providerFor(int seconds) => VideoProvider.minimax;"));
    });
  });

  group('prompts', () {
    const restore = 'Restore this photo: remove blur, noise, pixelation and compression artifacts, and recover natural fine detail with realistic textures, without oversharpening or plastic-looking skin. Keep the exact same scene, framing, people, objects, colours and identity; do not add, remove or redesign anything, and do not invent facial details. Where details are irrecoverable, preserve natural softness rather than inventing information.';
    const cleanup = 'Clean up and sharpen this image, with a natural tone. Keep every face exactly the same person: same face shape, eyes, nose, lips, skin tone and expression. Do not change, add or remove anything; keep all shapes, text and details as they are.';
    const portrait =
        'Clean up and sharpen this image, with a natural tone. Keep every face exactly the same person: same face shape, eyes, nose, lips, skin tone and expression. Blur only the background with a natural bokeh, and keep the subject sharp. Do not change, add or remove anything else.';

    test('exact Photo / zoom / Portrait strings; no maintain / DSLR', () {
      expect(kUniversalEnhancePrompt, restore);
      expect(kPhotoCleanupPrompt, cleanup);
      expect(kZoomCleanPrompt, '$kPhotoCleanupPrompt $kNoInventLine');
      expect(kLockedEnhancePrompt, restore);
      expect(kPortraitEnhancePrompt, portrait);
      expect(kPortraitPrompt, portrait);
      expect(kPortraitEnhancePrompt.toLowerCase(), isNot(contains('maintain')));
      expect(kPortraitEnhancePrompt.toLowerCase(), isNot(contains('do not invent')));
      expect(kPortraitEnhancePrompt.toLowerCase(), isNot(contains('dslr')));
      for (final p in [kUniversalEnhancePrompt, kZoomCleanPrompt]) {
        expect(p.toLowerCase(), isNot(contains('maintain')));
        expect(p.toLowerCase(), isNot(contains('dslr')));
      }
    });

    test('1x Photo uses the restore prompt; Portrait at 100x uses bokeh', () {
      expect(buildEnhancePrompt(), restore);
      expect(buildEnhancePrompt(zoom: 1), restore);
      expect(buildEnhancePrompt(zoom: 80, opticalLimit: 2), restore);
      expect(buildEnhancePrompt(zoom: 100, opticalLimit: 2), restore);
      expect(buildEnhancePrompt(portrait: true), portrait);
      expect(buildEnhancePrompt(portrait: true, zoom: 100, opticalLimit: 2), portrait);
    });

    test('EnhanceJob: zoomed photo uses zoom-clean (= simple); zoomed portrait does not', () {
      final photoJob = EnhanceJob(
        image: File('x.jpg'),
        zoom: 80,
        opticalLimit: 2,
        mode: 'photo',
        zoomClean: true,
      );
      expect(photoJob.isZoomClean, isTrue);
      expect(photoJob.isZoomSource, isFalse);
      expect(photoJob.primaryImage.path, 'x.jpg');

      final port = EnhanceJob(
        image: File('p.jpg'),
        zoom: 100,
        opticalLimit: 2,
        mode: 'portrait',
        zoomClean: true,
      );
      expect(port.isZoomClean, isFalse);
      expect(port.prompt(hasContext: false), portrait);
    });
  });

  group('shutter: last photo always, no Hold steady block', () {
    test('zoomFailClosed never blocks', () {
      expect(zoomFailClosed(ok: false, need: true, tiny: false), isFalse);
      expect(zoomFailClosed(ok: false, need: true, tiny: true), isFalse);
      expect(zoomFailClosed(ok: false, need: false, tiny: false), isFalse);
    });

    test('live note never shows the clear-base or Hold-steady messages', () {
      expect(
        liveZoomNote(
          ladderMode: true,
          zoom: 80,
          opticalLimit: 1,
          hasRoot: false,
          clearLimit: 10,
        ),
        isNot(kRootMissingHint),
      );
      expect(
        liveZoomNote(
          ladderMode: true,
          zoom: 80,
          opticalLimit: 1,
          hasRoot: false,
          clearLimit: 10,
        ),
        kBeyondClearLabel, // label only, past the clear limit
      );
      expect(
        liveZoomNote(
          ladderMode: true,
          zoom: 4,
          opticalLimit: 1,
          hasRoot: false,
          clearLimit: 10,
        ),
        isNull,
      );
    });

    test('home shutter sends the last photo and does not block', () {
      final h = File('lib/screens/home_camera_screen.dart').readAsStringSync();
      expect(h, contains("sent = 'sent final only';"));
      expect(h, isNot(contains('zoomSource = File(d.path!)')));
      expect(h, isNot(contains('_snack(zoomFailMessage')));
      expect(h, isNot(contains('Hold steady at lower zoom first')));
      expect(kHoldLowerZoomFirst, contains('Hold steady at lower zoom first'));
    });
  });
}
