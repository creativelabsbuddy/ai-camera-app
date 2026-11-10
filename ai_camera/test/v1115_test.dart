import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_camera/services/capture_crop.dart';
import 'package:ai_camera/services/macro.dart';
import 'package:ai_camera/services/mode_prompts.dart';
import 'package:ai_camera/services/openrouter_client.dart';
import 'package:ai_camera/services/server_api_client.dart';
import 'package:ai_camera/services/subject_detector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

http.Response _chat(String content) => http.Response(
  jsonEncode({
    'choices': [
      {
        'message': {'content': content},
      },
    ],
  }),
  200,
);

void main() {
  late Directory tmp;
  late File one, step;

  setUpAll(() {
    UploadPrep.nativeDecode = false;
    tmp = Directory.systemTemp.createTempSync('v1115');
    // Synthetic grey frames (no camera / test photos).
    final im = img.Image(width: 64, height: 48);
    img.fill(im, color: img.ColorRgb8(120, 110, 100));
    one = File('${tmp.path}/one.jpg')..writeAsBytesSync(img.encodeJpg(im));
    step = File('${tmp.path}/step.jpg')..writeAsBytesSync(img.encodeJpg(im));
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  SubjectDetector direct(MockClient mock) => SubjectDetector(
    openRouter: OpenRouterClient(httpClient: mock, apiKey: 'test'),
    server: ServerApiClient(httpClient: mock),
    serverUrl: () async => '',
    deviceId: () async => 'dev',
  );

  test('1x: direct OpenRouter call with flash-lite, 512 px, prompt', () async {
    final seen = <Map<String, dynamic>>[];
    final d = direct(
      MockClient((r) async {
        expect(
          r.url.toString(),
          'https://openrouter.ai/api/v1/chat/completions',
        );
        seen.add(jsonDecode(r.body) as Map<String, dynamic>);
        return _chat('Mobile phone back side with camera.');
      }),
    );
    expect(await d.detectSubject(one), 'mobile phone back side with camera');
    final p = seen.single;
    expect(p['model'], 'google/gemini-2.5-flash-lite');
    expect(p['max_tokens'], lessThanOrEqualTo(kDetectJsonMaxTokens));
    final content = (p['messages'] as List).first['content'] as List;
    expect(content.first['text'], kDetectSubjectPrompt);
    expect(content.length, 2);
  });

  test('step: 1x + boxed step, JSON reply parsed', () async {
    String? prompt;
    var images = 0;
    final d = direct(
      MockClient((r) async {
        final c =
            (jsonDecode(r.body)['messages'] as List).first['content'] as List;
        prompt = c.first['text'] as String;
        images = c.length - 1;
        return _chat(
          '```json\n{"same_subject": false, "part": "Camera lens ring"}\n```',
        );
      }),
    );
    final r = await d.detectPart(one, step, 'mobile phone');
    expect(images, 2);
    expect(
      prompt,
      startsWith('Photo 1 is a wider view; main object: mobile phone;'),
    );
    expect(r!.sameSubject, isFalse);
    expect(r.part, 'camera lens ring');
  });

  test('server path uses /v1/macro endpoints', () async {
    final urls = <String>[];
    final d = SubjectDetector(
      openRouter: OpenRouterClient(apiKey: ''),
      server: ServerApiClient(
        httpClient: MockClient((r) async {
          urls.add(r.url.path);
          return http.Response(
            r.url.path.endsWith('subject')
                ? '{"name": "wooden table top"}'
                : '{"same_subject": true, "part": "wood grain"}',
            200,
          );
        }),
      ),
      serverUrl: () async => 'http://srv',
      deviceId: () async => 'dev',
    );
    expect(await d.detectSubject(one), 'wooden table top');
    expect(
      (await d.detectPart(one, step, 'wooden table top'))!.part,
      'wood grain',
    );
    expect(urls, ['/v1/macro/subject', '/v1/macro/part']);
  });

  test('failure / timeout → null; never two calls in flight', () async {
    var calls = 0;
    final gate = Completer<http.Response>();
    final d = direct(
      MockClient((r) {
        calls++;
        return gate.future;
      }),
    );
    final first = d.detectSubject(one);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(d.busy, isTrue);
    expect(await d.detectSubject(one), isNull); // refused while busy
    gate.complete(http.Response('err', 500));
    expect(await first, isNull);
    expect(calls, 1);
  });

  test('chip: Detecting… → parent · part; failure keeps label', () {
    final l = SubjectLock();
    final g = l.beginDetect();
    expect(l.display(1), kDetectingLabel);
    l.completeDetect(g, 'mobile phone back side with camera');
    expect(l.display(1), 'Mobile phone back side with camera');
    l.setCloudPart('camera lens ring');
    expect(
      l.display(3),
      'camera lens ring', // v11.27 short label: part only
    );
    expect(l.hint, 'Mobile phone back side with camera');
    expect(l.partHint, 'camera lens ring');
    // Re-check failure keeps the label.
    l.completeDetect(l.beginDetect(), null);
    expect(l.hint, 'Mobile phone back side with camera');
    expect(l.cloudFailed, isFalse);
    // Stale result ignored.
    final old = l.beginDetect();
    l.beginDetect();
    expect(l.completeDetect(old, 'jeans'), isFalse);
  });

  test('first failure → "Subject", no hint; face fallback', () {
    final l = SubjectLock();
    l.completeDetect(l.beginDetect(), null);
    expect(l.display(1), isNull);
    expect(l.hint, isNull);
    expect(l.cloudFailed, isTrue);
    expect(
      macroPrompt(l.hint, level: 'macro', zoom: 5),
      kMacroPrompt.replaceAll('{subject}', fallbackDescription(null)),
    ); // v11.33
    l.lockParent(cameraZoom: 1, face: true);
    l.setFacePart('Eye');
    expect(l.display(8), 'eye');
    expect(l.partHint, 'eye');
  });

  test('cloud face name keeps landmark sub-part as fallback', () {
    final l = SubjectLock()..completeDetect(1, null);
    final g = l.beginDetect();
    l.completeDetect(g, 'human face');
    expect(l.parentIsFace, isTrue);
    l.setFacePart('Lips');
    expect(l.partHint, 'lips');
    l.setCloudPart('upper lip with fine lines');
    expect(l.partHint, 'upper lip with fine lines');
  });

  test('hint line: Detected: main subject …; zoomed spot …', () {
    expect(
      macroPrompt('Mobile phone', level: 'macro', zoom: 5, part: 'camera lens'),
      // v11.33: {subject} takes the description; no hint line then.
      kMacroPrompt.replaceAll('{subject}', 'mobile phone'),
    );
    expect(
      macroPrompt('Wooden table top', level: 'macro'),
      kMacroPrompt.replaceAll('{subject}', 'wooden table top'),
    );
  });

  test('re-check debounce and centre box', () {
    final d = RecheckDebounce();
    final t = DateTime(2026);
    expect(d.allow(t), isTrue);
    expect(d.allow(t.add(const Duration(seconds: 3))), isFalse);
    expect(d.allow(t.add(const Duration(seconds: 9))), isTrue);
    final r = centreBoxRect(200, 100);
    expect([r.x, r.y, r.width, r.height], [50, 25, 100, 50]);
  });

  test(
    'Macro label path no longer uses the ML Kit labeler',
    () {
      final s = File('lib/screens/home_camera_screen.dart').readAsStringSync();
      final a = s.indexOf('bool _updateMacroLabel(');
      final body = s.substring(a, s.indexOf('\n  }\n', a));
      expect(body, isNot(contains('macroSubjectFrom')));
      expect(body, isNot(contains('sceneLabel')));
      expect(s, contains('_detectParent('));
      expect(s, contains('_detectPart('));
    },
    skip: 'v11.33: replaced by level chips + box check',
  );
}
