import 'dart:io';
import 'dart:math' as math;

import 'package:ai_camera/models/capture_mode.dart';
import 'package:ai_camera/models/quality_tier.dart';
import 'package:ai_camera/screens/preview_screen.dart';
import 'package:ai_camera/services/account_service.dart';
import 'package:ai_camera/services/ai_call.dart';
import 'package:ai_camera/services/enhance_service.dart';
import 'package:ai_camera/services/macro.dart';
import 'package:ai_camera/widgets/credit_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _png = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

class _FakeEnhance extends EnhanceService {
  _FakeEnhance(this.results);
  final List<EnhanceResult> results;
  final jobs = <EnhanceJob>[];

  @override
  Future<EnhanceResult> enhance(EnhanceJob job, {AiCancelToken? cancel}) async {
    jobs.add(job);
    return results[math.min(jobs.length - 1, results.length - 1)];
  }
}

void main() {
  group('level mapping', () {
    test('chips reach 30x, every level has a chip', () {
      expect(kMacroChips.first, 1);
      expect(kMacroChips.last, 30);
      expect(kMacroMaxZoom, 30);
      expect(kMacroChips.map(macroLevelFor).toSet(), MacroLevel.values.toSet());
    });
  });

  group('subject lock', () {
    test('detect at low zoom, keep at 10x, unlock on scene change', () {
      final l = SubjectLock();
      expect(l.update(zoom: 2, detected: null), isFalse);
      expect(l.update(zoom: 2, detected: 'eye'), isTrue);
      expect(l.subject, 'Eye');
      // Zooming in: only texture is seen, labels change → still locked.
      l.update(zoom: 6, detected: 'pattern');
      l.update(zoom: 10, detected: 'skin', frameChange: 0.5);
      expect(l.subject, 'Eye');
      // Same object at low zoom, small motion → stays.
      l.update(zoom: 3, detected: 'skin', frameChange: 0.05);
      expect(l.subject, 'Eye');
      // Camera moved to another object at low zoom → re-detect.
      expect(l.update(zoom: 3, detected: 'leaf', frameChange: 0.3), isTrue);
      expect(l.subject, 'Leaf');
    });

    test('no detection at high zoom when nothing is locked', () {
      final l = SubjectLock();
      l.update(zoom: 8, detected: 'fabric');
      expect(l.subject, isNull);
    });

    test('manual correction wins until the scene changes', () {
      final l = SubjectLock()..update(zoom: 2, detected: 'flower');
      l.setManual('Insect');
      expect(l.subject, 'Insect');
      expect(l.manual, isTrue);
      l.update(zoom: 2, detected: 'flower', frameChange: 0.02);
      expect(l.subject, 'Insect');
      l.update(zoom: 2, detected: 'coin', frameChange: 0.4);
      expect(l.subject, 'Coin');
      expect(l.manual, isFalse);
      l.setManual('  ');
      expect(l.subject, isNull);
      expect(kMacroSubjectChoices, containsAll(['Eye', 'Skin', 'Wood']));
    });

    test('frameDiff', () {
      expect(frameDiff([0, 0, 0], [0, 0, 0]), 0);
      expect(frameDiff([0, 0], [255, 255]), 1);
      expect(frameDiff([0], [1, 2]), 0);
      expect(frameDiff(null, [1]), 0);
    });
  });

  group('extras + disclaimer', () {
    test('hold steady from 6x when moving', () {
      expect(showHoldSteady(zoom: 5, motion: 0.2), isFalse);
      expect(showHoldSteady(zoom: 6, motion: 0.01), isFalse);
      expect(showHoldSteady(zoom: 6, motion: 0.05), isTrue);
    });
    test('torch hint when dark and torch off', () {
      expect(macroTooDark(0.05, torchOn: false), isTrue);
      expect(macroTooDark(0.05, torchOn: true), isFalse);
      expect(macroTooDark(0.4, torchOn: false), isFalse);
    });
    test('disclaimer only at 12x–20x', () {
      expect(showMicroscopeDisclaimer(8), isFalse);
      expect(showMicroscopeDisclaimer(12), isTrue);
      expect(showMicroscopeDisclaimer(20), isTrue);
    });
    test('retry costs full tier credits', () {
      expect(
        macroRetryCredits(MacroLevel.macro, QualityTier.fullHd.credits),
        4, // v11.33 HD Macro
      );
      expect(macroRetryLabel(2), 'Try again · 🪙2');
      expect(macroRetryLabel(QualityTier.k4.credits), 'Try again · 🪙8');
    });
  });

  group('preview: macro result', () {
    late Directory dir;
    late File photo;
    late File out;
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AccountService.resetForTest();
      dir = Directory.systemTemp.createTempSync('v111');
      photo = File('${dir.path}/shot.png')..writeAsBytesSync(_png);
      out = File('${dir.path}/ai.png')..writeAsBytesSync(_png);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Future<_FakeEnhance> pump(
      WidgetTester t,
      MacroLevel level, {
      List<EnhanceResult>? results,
    }) async {
      final fake = _FakeEnhance(
        results ??
            [
              EnhanceResult(
                file: out,
                backend: EnhanceBackend.server,
                creditsCharged: 2,
              ),
            ],
      );
      await t.pumpWidget(
        MaterialApp(
          home: PreviewScreen(
            imageFile: photo,
            mode: CaptureMode.pro,
            aiMode: 'macro',
            subject: 'Eye',
            macroLevel: level,
            tier: QualityTier.fullHd,
            enhanceService: fake,
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 300));
      return fake;
    }

    testWidgets('job carries subject + level; retry is paid', (t) async {
      final fake = await pump(t, MacroLevel.microscope);
      final j = fake.jobs.single;
      expect(j.aiMode, 'macro');
      expect(j.subject, 'Eye');
      expect(j.macroLevel, 'microscope');
      expect(
        find.byWidgetPredicate((w) => isCreditText(w, 'Try again · 🪙6')), // v11.33 Full HD Microscope
        findsOneWidget,
      ); // v11.27 level credits
      expect(find.byKey(const ValueKey('compare_slider')), findsWidgets);
      expect(find.textContaining('2 credits'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('macro_try_again')));
      await t.pump(const Duration(milliseconds: 300));
      expect(fake.jobs.length, 2);
      expect(fake.jobs.last.spec.tier, QualityTier.fullHd); // full price
      expect(fake.jobs.last.macroLevel, 'microscope');
      expect(fake.jobs.last.isMicroscope, isTrue); // prompt alone, no ctx
    });

    testWidgets('"AI imagined" only for Microscope', (t) async {
      await pump(t, MacroLevel.microscope);
      expect(find.text(kAiImaginedLabel), findsOneWidget);
      await pump(t, MacroLevel.close);
      expect(find.text(kAiImaginedLabel), findsNothing);
    });

    testWidgets('no refund check in Macro: result kept, no guard UI', (
      t,
    ) async {
      await pump(t, MacroLevel.close);
      expect(find.byKey(const ValueKey('guard_actions')), findsNothing);
      expect(find.byKey(const ValueKey('guard_retry')), findsNothing);
      expect(find.textContaining('No credits used'), findsNothing);
    });

    testWidgets('technical failure → free, no paid retry button', (t) async {
      await pump(
        t,
        MacroLevel.macro,
        results: [
          const EnhanceResult(
            backend: EnhanceBackend.local,
            fellBackFromAi: true,
            aiError: 'timeout',
          ),
        ],
      );
      expect(find.textContaining('no credits used'), findsWidgets);
      expect(find.byKey(const ValueKey('macro_try_again')), findsNothing);
    });
  });
}
