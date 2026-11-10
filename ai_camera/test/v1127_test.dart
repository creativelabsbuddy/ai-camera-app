import 'dart:convert';
import 'dart:io';

import 'package:ai_camera/models/quality_tier.dart';
import 'package:ai_camera/services/macro.dart';
import 'package:ai_camera/services/mode_prompts.dart';
import 'package:ai_camera/services/openrouter_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

void main() {
  group('X on the result → fresh Macro start', () {
    test(
      'preview X returns kPreviewClosed; home resets everything',
      () {
        final p = File('lib/screens/preview_screen.dart').readAsStringSync();
        expect(p, contains('Navigator.pop(context, kPreviewClosed)'));
        final h = File(
          'lib/screens/home_camera_screen.dart',
        ).readAsStringSync();
        expect(
          h,
          contains(
            'if (result == kPreviewClosed && _macroActive) '
            'unawaited(_freshMacroStart());',
          ),
        );
        final a = h.indexOf('Future<void> _freshMacroStart()');
        final body = h.substring(a, h.indexOf('void _resetMacroFlow()', a));
        for (final s in [
          '_resetMacroFlow();',
          '_drift.clear();',
          '_drifted = false;',
          '_detectFailed = false;',
          '_driftDbg = null;',
          '_last1xThumb = null;',
          'await _applyMacroChip(1.0);',
        ]) {
          expect(body, contains(s));
        }
        expect(kPreviewClosed, 'closed');
      },
      skip: 'v11.33: replaced by level chips + box check',
    );

    test('lock + drift state really clear; only 1x / 1.5x chips', () {
      final l = SubjectLock()
        ..completeDetect(SubjectLock().beginDetect(), null);
      final lock = SubjectLock();
      lock.completeDetect(lock.beginDetect(), 'brown human eye');
      lock.applyObjectPart('brown human eye', 'brown iris');
      expect(lock.stepPart, 'brown iris');
      lock.reset();
      expect(lock.parent, isNull);
      expect(lock.stepPart, isNull);
      expect(lock.display(1), isNull);
      expect(l.parent, isNull);
      final m = MacroDriftMonitor();
      m.lastEnd = 'reset';
      m.clear();
      expect(m.lastEnd, '');
      expect(m.metric, isNull);
      expect(m.waiting, isFalse);
      expect(visibleMacroChips(0), [1.0, kMacroDetectZoom]);
    });
  });

  test('AI-imagined warning names the current level', () {
    expect(macroDisclaimerFor(12), startsWith('Microscope level'));
    expect(macroDisclaimerFor(12), isNot(contains('Ultra')));
    expect(macroDisclaimerFor(21), startsWith('Extreme Microscope level'));
    expect(macroDisclaimerFor(30), startsWith('Ultra Electron Microscope'));
    expect(macroDisclaimerFor(4), isNull);
  });

  test('Try again shows the level credits (not the tier)', () {
    final tier = QualityTier.fullHd.credits;
    // v11.33: by quality + level (Full HD here).
    const q = 'full_hd';
    expect(macroRetryCredits(MacroLevel.macro, tier, quality: q), 5);
    expect(macroRetryCredits(MacroLevel.close, tier, quality: q), 5);
    expect(macroRetryCredits(MacroLevel.microscope, tier, quality: q), 6);
    expect(macroRetryCredits(MacroLevel.extreme, tier, quality: q), 3);
    expect(macroRetryCredits(MacroLevel.ultra, tier, quality: q), 3);
    expect(
      macroRetryLabel(macroRetryCredits(MacroLevel.ultra, tier, quality: q)),
      'Try again · 🪙3',
    );
    final p = File('lib/screens/preview_screen.dart').readAsStringSync();
    expect(p, contains('quality: widget.tier.id'));
  });

  test('Ultra prompt keeps the spot (v11.28 text, see v1128)', () {
    expect(kMacroUltraPrompt, contains('{spot}'));
  });

  group('spot: always object + part', () {
    test('spot without part falls back to the last 2x–5x part', () {
      expect(
        finalSpotText(
          object: 'brown human eye',
          part: '',
          fallbackPart: 'brown iris',
        ),
        'brown human eye brown iris',
      );
      expect(
        finalSpotText(object: 'brown human eye', part: 'black pupil edge'),
        'brown human eye black pupil edge',
      );
      // no object → locked main subject
      expect(
        finalSpotText(part: 'brown iris', parent: 'Brown human eye'),
        'brown human eye brown iris',
      );
      // nothing found anywhere → never the object alone
      final s = finalSpotText(object: 'brown human eye');
      expect(s, isNot('brown human eye'));
      expect(s, startsWith('brown human eye '));
    });

    test('step checks record the part for the fallback', () {
      final l = SubjectLock();
      l.completeDetect(l.beginDetect(), 'brown human eye');
      expect(l.stepPart, isNull);
      l.applyObjectPart('brown human eye', 'brown iris');
      expect(l.stepPart, 'brown iris');
      l.applyObjectPart('brown human eye', '');
      expect(l.stepPart, 'brown iris'); // kept
      expect(l.display(3), 'brown iris'); // short live label
    });

    test(
      'home: shutter spot uses finalSpotText with the step part',
      () {
        final h = File(
          'lib/screens/home_camera_screen.dart',
        ).readAsStringSync();
        expect(h, contains('_subjectLock.stepPart ??'));
        expect(
          h,
          contains('part: spot == null ? null : _detector.lastSpotPart'),
        );
      },
      skip: 'v11.33: replaced by level chips + box check',
    );
  });

  group('spot model', () {
    late Directory dir;
    late File a, b;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('v1127');
      final jpg = img.encodeJpg(img.Image(width: 32, height: 32));
      a = File('${dir.path}/a.jpg')..writeAsBytesSync(jpg);
      b = File('${dir.path}/b.jpg')..writeAsBytesSync(jpg);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('spot = flash; part + subject stay flash-lite', () async {
      final models = <String>[];
      final c = OpenRouterClient(
        apiKey: 'test',
        httpClient: MockClient((r) async {
          models.add((jsonDecode(r.body) as Map)['model'] as String);
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '{}'},
                },
              ],
            }),
            200,
          );
        }),
      );
      await c.detectSpot(a, b, 'eye');
      await c.detectPart(a, b, 'eye');
      expect(models, [
        'google/gemini-2.5-flash',
        'google/gemini-2.5-flash-lite',
      ]);
      expect(kDetectSpotModel, 'google/gemini-2.5-flash');
      expect(kDetectModel, 'google/gemini-2.5-flash-lite');
      expect(detectPayload('x', const [])['model'], kDetectModel);
    });

    test('box prompts name the centre of the red box', () {
      for (final p in [kDetectPartPrompt, kDetectSpotPrompt]) {
        expect(p, contains('Describe what is in the red box'));
        expect(p, contains('Include its colour'));
      }
    });
  });
}
