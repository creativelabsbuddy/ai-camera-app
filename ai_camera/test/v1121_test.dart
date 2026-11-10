import 'dart:convert';
import 'dart:io';

import 'package:ai_camera/services/mode_prompts.dart';
import 'package:ai_camera/services/openrouter_client.dart';
import 'package:ai_camera/services/server_api_client.dart';
import 'package:ai_camera/services/subject_detector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

void main() {
  late Directory tmp;
  late File one;

  setUpAll(() {
    UploadPrep.nativeDecode = false;
    tmp = Directory.systemTemp.createTempSync('v1121');
    final im = img.Image(width: 40, height: 30);
    img.fill(im, color: img.ColorRgb8(100, 80, 60)); // synthetic, no photo
    one = File('${tmp.path}/one.jpg')..writeAsBytesSync(img.encodeJpg(im));
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  SubjectDetector det(Future<http.Response> Function(http.Request) h) =>
      SubjectDetector(
        openRouter: OpenRouterClient(apiKey: 'k', httpClient: MockClient(h)),
        server: ServerApiClient(),
        serverUrl: () async => '',
        deviceId: () async => 'dev',
      );

  http.Response chat(Object? content, {String finish = 'stop'}) =>
      http.Response(
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

  test(
    'max_tokens raised (v11.22: 120 for JSON) for the subject call',
    () async {
      int? mt;
      final d = det((r) async {
        mt = (jsonDecode(r.body) as Map)['max_tokens'] as int;
        return chat('Brown human eye');
      });
      expect(await d.detectSubject(one), 'brown human eye');
      expect(mt, kDetectJsonMaxTokens);
      expect(d.lastReason, 'ok');
    },
  );

  test('long / quoted / multi-line replies are trimmed, not rejected', () {
    expect(
      cleanDetected(
        '\n\n**"Brown cardboard box top side, with printed '
        'black text and tape strip"**\nmore',
      ),
      'brown cardboard box top side, with printed black text and',
    );
    expect(cleanDetected('Answer: White styrofoam.'), 'white styrofoam');
  });

  test('content as a list of parts is accepted', () async {
    final d = det(
      (r) async => chat([
        {'type': 'text', 'text': 'White styrofoam'},
      ]),
    );
    expect(await d.detectSubject(one), 'white styrofoam');
  });

  test('debug reasons: http, empty(length), timeout-free errors', () async {
    final a = det((r) async => http.Response('{"error":"bad"}', 401));
    expect(await a.detectSubject(one), isNull);
    expect(a.lastReason, 'http 401');
    expect(detectDebugText(a.lastReason), 'detect: http 401');
    final b = det((r) async => chat(null, finish: 'length'));
    expect(await b.detectSubject(one), isNull);
    expect(b.lastReason, 'empty (length)');
    final c = det((r) async => chat(''));
    expect(await c.detectSubject(one), isNull);
    expect(c.lastReason, 'empty (stop)');
  });

  test('part check: plain (non-JSON) reply becomes the part', () async {
    final d = det((r) async => chat('Brown iris near pupil'));
    final r = await d.detectPart(one, one, 'eye');
    expect(r!.part, 'brown iris near pupil');
    expect(r.sameSubject, isNull);
  });

  test('home shows the debug line in test builds', () {
    final s = File('lib/screens/home_camera_screen.dart').readAsStringSync();
    expect(s, contains("ValueKey('macro_detect_debug')"));
    expect(s, contains('AiConfig.hasEmbeddedApiKey &&'));
  });
}
