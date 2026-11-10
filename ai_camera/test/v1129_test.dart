import 'dart:convert';
import 'dart:io';

import 'package:ai_camera/services/macro.dart';
import 'package:ai_camera/services/mode_prompts.dart';
import 'package:ai_camera/services/openrouter_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

String _home() =>
    File('lib/screens/home_camera_screen.dart').readAsStringSync();

void main() {
  test('Extreme / Ultra prompts', () {
    // v11.58: material-aware (no hardcoded cells).
    expect(kMacroExtremePrompt, startsWith('A tiny area of {spot}{on_object} under a light microscope at 1000x'));
    expect(kMacroUltraPrompt, startsWith('Close-up of {spot}{on_object} under a scanning electron microscope at 2000x'));
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is File && f.path.endsWith('.dart')) {
        expect(f.readAsStringSync(), isNot(contains('15000x')), reason: f.path);
      }
    }
  });

  group('sent spot is shown', () {
    test('level-sent line: spot + source', () {
      expect(
        macroLevelSentLabel(
          MacroLevel.ultra,
          spot: 'brown human eye brown iris',
          source: 'check',
        ),
        'Level sent: Ultra Electron Microscope · spot: brown human eye brown '
        'iris (check)',
      );
      expect(
        macroLevelSentLabel(MacroLevel.ultra),
        'Level sent: Ultra Electron Microscope',
      );
      expect(macroSpotSuffix('brown iris'), ' · spot: brown iris');
    });

    test(
      'status line uses the spot, not "(subject)"',
      () {
        final p = File('lib/screens/preview_screen.dart').readAsStringSync();
        expect(p, contains('macroSpotSuffix(job.part)'));
        expect(p, isNot(contains("' (\${job.subject})'")));
        expect(p, contains('source: widget.spotSource'));
        expect(_home(), contains('spotSource: macro ? _spotSource : null'));
      },
      skip: 'v11.33: replaced by level chips + box check',
    );

    test('debug texts', () {
      expect(
        spotDebugText(
          reason: 'ok',
          spot: 'brown iris',
          took: const Duration(milliseconds: 2300),
        ),
        'spot: ok brown iris 2.3s',
      );
      expect(spotDebugText(reason: 'empty (length)'), 'spot: empty(length)');
      expect(
        spotDebugText(reason: 'timeout', took: const Duration(seconds: 10)),
        'spot: timeout 10.0s',
      );
      expect(
        stepDebugText({
          3.0: 'fail(timeout)',
          2.0: 'ok brown iris',
          5.0: 'skip blur',
        }),
        'steps: 2x ok brown iris · 3x fail(timeout) · 5x skip blur',
      );
      final h = _home();
      expect(h, contains("ValueKey('macro_spot_debug')"));
      expect(h, contains("ValueKey('macro_step_debug')"));
    }, skip: 'v11.33: replaced by level chips + box check');
  });

  group('spot reliability', () {
    test('flash payload: thinking off, 200 tokens; others unchanged', () {
      final p = detectPayload(
        't',
        const [],
        maxTokens: kDetectSpotMaxTokens,
        model: kDetectSpotModel,
        noThinking: true,
      );
      expect(p['reasoning'], {'max_tokens': 0});
      expect(p['max_tokens'], 200);
      expect(detectPayload('t', const []).containsKey('reasoning'), isFalse);
      expect(kSpotTimeout, const Duration(seconds: 10));
      expect(spotNeedsRetry('', 'stop'), isTrue);
      expect(spotNeedsRetry('{"object": "a', 'length'), isTrue);
      expect(spotNeedsRetry('{}', 'stop'), isFalse);
    });

    late Directory dir;
    late File a, b;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('v1129');
      final jpg = img.encodeJpg(img.Image(width: 32, height: 32));
      a = File('${dir.path}/a.jpg')..writeAsBytesSync(jpg);
      b = File('${dir.path}/b.jpg')..writeAsBytesSync(jpg);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    http.Response reply(String content, String finish) => http.Response(
      jsonEncode({
        'choices': [
          {
            'message': {'content': content},
            'finish_reason': finish,
          },
        ],
      }),
      200,
    );

    test('empty(length) on flash → one retry on flash-lite', () async {
      final seen = <Map<String, dynamic>>[];
      final c = OpenRouterClient(
        apiKey: 'test',
        httpClient: MockClient((r) async {
          final j = jsonDecode(r.body) as Map<String, dynamic>;
          seen.add(j);
          return j['model'] == kDetectSpotModel
              ? reply('', 'length')
              : reply(
                  '{"object": "brown human eye", "part": "brown iris"}',
                  'stop',
                );
        }),
      );
      final out = await c.detectSpot(a, b, 'brown human eye');
      expect(parseObjectPartReply(out).$2, 'brown iris');
      expect(
        [for (final s in seen) s['model']],
        ['google/gemini-2.5-flash', 'google/gemini-2.5-flash-lite'],
      );
      expect(seen.first['reasoning'], {'max_tokens': 0});
      expect(seen.last.containsKey('reasoning'), isFalse);
      expect(c.lastSpotModel, 'lite');
    });

    test('a good flash reply is not retried', () async {
      var n = 0;
      final c = OpenRouterClient(
        apiKey: 'test',
        httpClient: MockClient((r) async {
          n++;
          return reply('{"object": "eye", "part": "brown iris"}', 'stop');
        }),
      );
      await c.detectSpot(a, b, 'eye');
      expect(n, 1);
      expect(c.lastSpotModel, 'flash');
    });

    test(
      'shutter: 10 s limit, stale step checks cancelled (no busy wait)',
      () {
        final h = _home();
        final a0 = h.indexOf('Future<String?> _detectFinalSpot(');
        final body = h.substring(a0, h.indexOf('\n  }\n', a0));
        expect(body, contains('kSpotTimeout'));
        expect(body, contains("cancelInFlight('stale step')"));
        expect(body, contains('_partGen++'));
        expect(body, isNot(contains('_detector.busy;')));
        expect(body, isNot(contains('Future<void>.delayed')));
      },
      skip: 'v11.33: replaced by level chips + box check',
    );
  });

  group('step checks', () {
    test(
      'queued (not dropped) and retried once',
      () {
        final h = _home();
        expect(h, contains('_queuePartCheck(chip); // v11.29'));
        final a0 = h.indexOf('Future<void> _runPartCheck(');
        final body = h.substring(a0, h.indexOf('\n  }\n', a0));
        expect(body, contains('attempt < 2'));
        final d0 = h.indexOf('Future<String?> _detectPart(');
        final d = h.substring(d0, h.indexOf('\n  }\n', d0));
        expect(d, isNot(contains('if (_detector.busy) return')));
      },
      skip: 'v11.33: replaced by level chips + box check',
    );

    test('best part = closest zoom', () {
      final l = SubjectLock();
      l.completeDetect(l.beginDetect(), 'brown human eye');
      l.recordStepPart(2, 'brown iris');
      l.recordStepPart(4, 'black pupil edge');
      l.recordStepPart(3, 'eyelash');
      l.recordStepPart(5, '');
      expect(l.stepPart, 'black pupil edge');
      l.reset();
      expect(l.stepPart, isNull);
    });

    test(
      '5x: check only on a sharp frame',
      () {
        expect(fiveXCheckAllowed(90, 100), isTrue);
        expect(fiveXCheckAllowed(20, 100), isFalse);
        expect(fiveXCheckAllowed(90, 0), isFalse); // no 4x reference
        final h = _home();
        expect(h, contains('_takeFiveXCheck(chip, pz.camera)'));
        expect(h, contains("_stepDbg[chip] = 'skip blur'"));
      },
      skip: 'v11.33: replaced by level chips + box check',
    );

    test(
      'spot source order: check → step / 1.5x part → fallback',
      () {
        expect(
          pickSpot(
            object: 'brown human eye',
            part: 'brown iris',
            parent: 'Brown human eye',
            lastPart: 'eyelash',
          ),
          ('brown human eye brown iris', SpotSource.check),
        );
        expect(
          pickSpot(
            object: 'brown human eye',
            part: 'brown human eye',
            parent: 'Brown human eye',
            lastPart: 'eyelash',
          ),
          ('brown human eye eyelash', SpotSource.step),
        );
        final (s, src) = pickSpot(parent: 'Brown human eye');
        expect(src, SpotSource.fallback);
        expect(s, 'brown human eye surface detail');
        // 1.5x (face) part is tried before "surface detail"
        expect(_home(), contains('_subjectLock.facePart?.toLowerCase()'));
      },
      skip: 'v11.33: replaced by level chips + box check',
    );
  });

  group('hold time', () {
    test('4 frames; Hold steady only while capturing; then move now', () {
      expect(macroBurstCount(lowEnd: true), 4);
      expect(macroBurstCount(lowEnd: false), 4);
      expect(kProcessingMoveNow, 'Processing… you can move now');
      final h = _home();
      expect(h, isNot(contains("ValueKey('macro_hold_steady')")));
      expect(h, contains("ValueKey('processing_move_now')"));
      expect(h, contains('_afterFrames = true;'));
      final p = File('lib/screens/preview_screen.dart').readAsStringSync();
      expect(p, contains('label: _isMacro ? kProcessingMoveNow : label'));
    });
  });
}
