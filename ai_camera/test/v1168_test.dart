// v11.68 (1.11.69+82) tests: restore enhance prompt; no-invent line on
// zoom "Beyond clear range" and Pro AI Night; clear reference off;
// Macro held behind kMacroComingSoon.
import 'dart:io';

import 'package:ai_camera/config/ai_config.dart';
import 'package:ai_camera/models/quality_tier.dart';
import 'package:ai_camera/models/shoot_mode.dart';
import 'package:ai_camera/services/clear_ref.dart';
import 'package:ai_camera/services/enhance_service.dart';
import 'package:ai_camera/services/macro.dart';
import 'package:ai_camera/services/prompt_builder.dart';
import 'package:flutter_test/flutter_test.dart';

const restore =
    'Restore this photo: remove blur, noise, pixelation and compression artifacts, and recover natural fine detail with realistic textures, without oversharpening or plastic-looking skin. Keep the exact same scene, framing, people, objects, colours and identity; do not add, remove or redesign anything, and do not invent facial details. Where details are irrecoverable, preserve natural softness rather than inventing information.';

const noInvent =
    'Where details are irrecoverable, preserve natural softness rather than inventing information; never replace unreadable text with blank shapes.';

void main() {
  test('version 1.11.69+82', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('version: 1.11.69+82'));
  });

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

  group('3: clear reference switched off', () {
    test('kClearRefEnabled is false; wiring kept', () {
      expect(kClearRefEnabled, isFalse);
      final home = File(
        'lib/screens/home_camera_screen.dart',
      ).readAsStringSync();
      // Path still exists, only the switch is off.
      expect(
        home,
        contains(
          '      kClearRefEnabled &&\n      _snapshotMode &&\n      !_macroActive &&',
        ),
      );
      expect(
        File('lib/services/clear_ref.dart').readAsStringSync(),
        contains('const bool kClearRefEnabled = false;'),
      );
    });
  });

  group('4: Macro on hold (kMacroComingSoon)', () {
    test('one flag, English Coming soon, existing pipeline intact', () {
      expect(kMacroComingSoon, isTrue);
      expect(kMacroComingSoonMessage, 'Coming soon');
      // Credits / level tables are unchanged (hold is UI-only).
      expect(kMacroLevelCredits['microscope'], 5);
      expect(kMacroLevelCredits['extreme'], 2);
      expect(kMacroLevelCredits['ultra'], 2);
      final macro = File('lib/services/macro.dart').readAsStringSync();
      expect(macro, contains('const bool kMacroComingSoon = true;'));
      final home = File(
        'lib/screens/home_camera_screen.dart',
      ).readAsStringSync();
      expect(
        home,
        contains(
          '  bool get _macroActive =>\n'
          '      _shootMode == ShootMode.macro && _aiMode && !kMacroComingSoon;',
        ),
      );
      expect(home, contains('if (_macroComingSoonView) return;'));
      expect(
        home,
        contains("const Positioned.fill(child: _MacroComingSoon())"),
      );
      expect(home, contains('kMacroComingSoonMessage'));
      // Existing Macro camera flow is still in the source (reopen by flipping the flag).
      expect(home, contains('CaptureKind.macroBurst'));
      expect(home, contains('if (_macroActive) {'));
      expect(home, contains('MacroLevelChips('));
    });

    test('mode strip still lists Macro in Pro AI, not in Normal', () {
      expect(ShootMode.stripFor(aiMode: true), contains(ShootMode.macro));
      expect(
        ShootMode.stripFor(aiMode: false),
        isNot(contains(ShootMode.macro)),
      );
    });
  });
}
