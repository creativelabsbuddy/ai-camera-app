// v11.68 (1.11.68+81) tests: restore enhance prompt; no-invent line on
// zoom "Beyond clear range" and Pro AI Night.
import 'dart:io';

import 'package:ai_camera/config/ai_config.dart';
import 'package:ai_camera/models/quality_tier.dart';
import 'package:ai_camera/services/clear_ref.dart';
import 'package:ai_camera/services/enhance_service.dart';
import 'package:ai_camera/services/prompt_builder.dart';
import 'package:flutter_test/flutter_test.dart';

const restore =
    'Restore this photo: remove blur, noise, pixelation and compression artifacts, and recover natural fine detail with realistic textures, without oversharpening or plastic-looking skin. Keep the exact same scene, framing, people, objects, colours and identity; do not add, remove or redesign anything, and do not invent facial details. Where details are irrecoverable, preserve natural softness rather than inventing information.';

const noInvent =
    'Where details are irrecoverable, preserve natural softness rather than inventing information; never replace unreadable text with blank shapes.';

void main() {
  group('1: Pro AI enhance restore prompt', () {
    test('exact string; HD / Full HD / Ultra HD / gallery use it', () {
      expect(kUniversalEnhancePrompt, restore);
      expect(kLockedEnhancePrompt, restore);
      expect(buildEnhancePrompt(), restore);
      expect(buildEnhancePrompt(tier: QualityTier.hd), restore);
      expect(
        buildEnhancePrompt(tier: QualityTier.fullHd),
        '$restore Target a crisp Full HD result with clean fine detail.',
      );
      expect(
        buildEnhancePrompt(tier: QualityTier.ultraHd),
        startsWith(restore),
      );
      expect(buildEnhancePrompt(tier: QualityTier.ultraHd), contains('Ultra HD'));
    });

    test('dynamic additions still append: context, boxed context, quality', () {
      final ctx = buildEnhancePrompt(hasContextImage: true);
      expect(ctx, startsWith(restore));
      expect(ctx, contains(kContextImageSentence));
      final boxed = buildEnhancePrompt(hasContextImage: true, contextBoxed: true);
      expect(boxed, startsWith(restore));
      expect(boxed, contains(kContextBoxedSentence));
    });

    test('Portrait / Macro / Extreme / Ultra prompts are unchanged', () {
      expect(
        kPortraitEnhancePrompt,
        'Clean up and sharpen this image, with a natural tone. Keep every face exactly the same person: same face shape, eyes, nose, lips, skin tone and expression. Blur only the background with a natural bokeh, and keep the subject sharp. Do not change, add or remove anything else.',
      );
      expect(buildEnhancePrompt(portrait: true), kPortraitEnhancePrompt);
      expect(kPortraitEnhancePrompt, isNot(contains(restore)));
      // Mode-level prompts live in mode_prompts.dart; v11.68 must not touch them.
      final mp = File('lib/services/mode_prompts.dart').readAsStringSync();
      expect(mp, contains('light microscope at 100x'));
      expect(mp, isNot(contains('Restore this photo')));
      expect(mp, isNot(contains(noInvent)));
    });
  });

  group('2: Beyond clear range + Night append no-invent line', () {
    test('kNoInventLine exact, and zoom prompts append it without replacing the base', () {
      expect(kNoInventLine, noInvent);
      expect(kZoomCleanPrompt, startsWith(kPhotoCleanupPrompt));
      expect(kZoomCleanPrompt, endsWith(kNoInventLine));
      expect(kZoomCleanPrompt, '$kPhotoCleanupPrompt $kNoInventLine');
      expect(kZoomCleanPrompt, isNot(kUniversalEnhancePrompt));
      expect(kZoomSourcePrompt, contains('only to match the framing'));
      expect(kZoomSourcePrompt, endsWith(kNoInventLine));
      expect(
        kZoomSourcePrompt,
        startsWith('The first image is a sharp photo of exactly the area to show.'),
      );
      expect(kZoomLadderPrompt, startsWith(kPhotoCleanupPrompt));
      expect(kZoomLadderPrompt, contains(kZoomLadderRefsLine));
      expect(kZoomLadderPrompt, endsWith(kNoInventLine));
    });

    test('clear-ref line still appends after the zoom source prompt', () {
      if (!AiConfig.kHasEmbeddedKey) return;
      final job = EnhanceJob(
        image: File('f.jpg'),
        zoomSource: File('src.jpg'),
        clearRef: true,
      );
      final p = job.prompt(hasContext: true);
      expect(p, startsWith(kZoomSourcePrompt));
      expect(p, contains(kClearRefLine));
      expect(p, contains(kNoInventLine));
      expect(p, '$kZoomSourcePrompt $kClearRefLine');
    });

    test('Night prompt constant appends the line; enhance request also gets it', () {
      expect(kNightPrompt, startsWith('A natural night photograph'));
      expect(kNightPrompt, contains('do not add anything new'));
      expect(kNightPrompt, endsWith(kNoInventLine));
      final p = buildEnhancePrompt(night: true);
      expect(p, '$restore $noInvent');
      expect(p, isNot(contains('A natural night photograph')));
      expect(buildEnhancePrompt(), restore);
      expect(buildEnhancePrompt(), isNot(contains(noInvent)));
    });
  });
}
