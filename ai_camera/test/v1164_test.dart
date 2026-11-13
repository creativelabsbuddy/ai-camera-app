// v11.64: Microscope / Extreme / Ultra common-name detection on flash-lite.
import 'dart:convert';
import 'dart:io';

import 'package:ai_camera/services/capture_crop.dart' show writeZoomCrop;
import 'package:ai_camera/services/micro_lock.dart';
import 'package:ai_camera/services/mode_prompts.dart';
import 'package:ai_camera/services/openrouter_client.dart';
import 'package:ai_camera/services/subject_detector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

http.Response _reply(String text) => http.Response(
  jsonEncode({
    'choices': [
      {
        'message': {'content': text},
        'finish_reason': 'stop',
      },
    ],
  }),
  200,
);

void main() {
  test('version 1.11.64+77', () {
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains('version: 1.11.64+77'),
    );
  });

  group('look words', () {
    test('shape / look words are vague on their own', () {
      for (final w in ['oval', 'round', 'square', 'rectangular', 'shape', 'textured', 'embossed', 'pattern']) {
        expect(kVagueDetectWords, contains(w), reason: w);
        expect(isVagueDetect('white $w'), isTrue, reason: w);
      }
      expect(isVagueDetect('white paper napkin'), isFalse);
    });

    test('stripped from the spot, the name is kept', () {
      expect(stripLookWords('white paper, with texture, oval shape'), 'white paper');
      expect(stripLookWords('embossed white paper napkin'), 'white paper napkin');
      expect(stripLookWords('round red soda can'), 'red soda can');
      expect(stripLookWords('surface'), 'surface');
      expect(stripLookWords('oval shape'), '');
    });
  });

  group('name step reply', () {
    test('napkin: "white paper napkin, surface" → napkin spot', () {
      final (n, p) = parseMicroNameReply('white paper napkin, surface');
      expect((n, p), ('white paper napkin', 'surface'));
      expect(microSpotText(n, p), 'surface of a white paper napkin');
    });

    test('the old napkin reply never becomes the spot as is', () {
      final (n, p) = parseMicroNameReply('white paper, with texture, oval shape');
      final spot = microSpotText(n, p);
      expect(spot, 'white paper');
      for (final w in ['oval', 'shape', 'texture']) {
        expect(spot, isNot(contains(w)));
      }
    });

    test('hand, can, fabric, vague, JSON', () {
      final (hn, hp) = parseMicroNameReply('human hand, back of hand');
      expect(microSpotText(hn, hp), 'skin on the back of a human hand');
      final (cn, cp) = parseMicroNameReply('Answer: red soda can, side');
      expect(microSpotText(cn, cp), 'side of a red soda can');
      expect(parseMicroNameReply('striped cotton fabric'), ('striped cotton fabric', ''));
      expect(parseMicroNameReply('white, oval shape').$1, '');
      expect(parseMicroNameReply('{"name": "human hand", "part": "palm"}'), ('human hand', 'palm'));
    });
  });

  group('part never overwrites the name', () {
    test('spot always contains the locked name', () {
      expect(microPartText('white paper, with texture, oval shape', 'white paper napkin'), contains('white paper napkin'));
      expect(microPartText('oval shape', 'white paper napkin'), 'white paper napkin');
      expect(microPartText('', 'white paper napkin'), 'white paper napkin');
      expect(microPartText('palm', 'human hand'), 'skin on the palm of a human hand');
      expect(microPartOnly('textured oval surface'), 'surface');
    });

    test('text-only only with a clear name; vague → photo prompt', () {
      final spot = microPartText('surface', 'white paper napkin');
      expect(macroTextOnly('microscope', 'white paper napkin', spot), isTrue);
      expect(macroPrompt('white paper napkin', level: 'microscope', part: spot), startsWith('A tiny area of surface of a white paper napkin under a light microscope'));
      // Vague name → general subject + no spot → the photo prompt.
      expect(macroTextOnly('microscope', kMacroGeneralSubject, ''), isFalse);
      expect(macroPrompt(kMacroGeneralSubject, level: 'microscope', part: ''), kMacroMicroscopePhotoPrompt);
      expect(macroTextOnly('extreme', kMacroGeneralSubject, ''), isFalse);
      expect(macroPrompt(kMacroGeneralSubject, level: 'extreme', part: ''), startsWith('A tiny area of this under'));
    });
  });

  test('shape-ban line in all three deep prompts', () {
    for (final t in [kMacroMicroscopePrompt, kMacroExtremePrompt, kMacroUltraPrompt]) {
      expect(t, contains('Do not draw the whole object, its outline or its shape; fill the frame with the inner structure of its own material'));
      expect(t, contains('a paper napkin shows pressed paper fibres'));
      expect(t, contains('cotton fabric shows woven threads and fibres'));
      expect(t.toLowerCase(), isNot(contains('cells')));
    }
  });

  test('detect prompts: name + part form, part only, no look words', () {
    expect(kDetectMicroNamePrompt, contains('<colour> <common object name>, <part or side>'));
    expect(kDetectMicroNamePrompt, contains('white paper napkin, surface; human hand, back of hand; red soda can, side'));
    expect(kDetectMicroNamePrompt, contains('Do not describe texture or shape'));
    expect(kDetectMicroPartPrompt, contains('Do not rename the object'));
    expect(kDetectMicroPartPrompt, contains('"in_scene"'));
  });

  group('calls (flash-lite)', () {
    late Directory dir;
    late File a, b;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('v1164');
      final jpg = img.encodeJpg(img.Image(width: 32, height: 32));
      a = File('${dir.path}/a.jpg')..writeAsBytesSync(jpg);
      b = File('${dir.path}/b.jpg')..writeAsBytesSync(jpg);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('name step: 2 photos on flash-lite; part step: part only', () async {
      final seen = <Map>[];
      final replies = ['white paper napkin, surface', '{"part": "textured oval surface", "in_scene": true}'];
      final c = OpenRouterClient(
        apiKey: 'test',
        httpClient: MockClient((r) async {
          seen.add(jsonDecode(r.body) as Map);
          return _reply(replies[seen.length - 1]);
        }),
      );
      final d = SubjectDetector(openRouter: c, serverUrl: () async => '', deviceId: () async => 'x');
      final named = await d.detectMicroNameTimed(a, b);
      expect(named, ('white paper napkin', 'surface'));
      final pr = await d.detectMicroPart(a, b, 'white paper napkin');
      expect(pr!.part, 'surface');
      expect(pr.inScene, isTrue);
      expect(seen.map((p) => p['model']), ['google/gemini-2.5-flash-lite', 'google/gemini-2.5-flash-lite']);
      final c0 = (seen[0]['messages'] as List).first['content'] as List;
      expect(c0.first['text'], kDetectMicroNamePrompt);
      expect(c0.where((e) => e['type'] == 'image_url').length, 2);
      final c1 = (seen[1]['messages'] as List).first['content'] as List;
      expect(c1.first['text'], contains('Which part or side of the white paper napkin'));
      expect(microPartText(pr.part, named!.$1), 'surface of a white paper napkin');
    });

    test('writeZoomCrop cuts the zoomed area out', () async {
      final big = File('${dir.path}/big.jpg')
        ..writeAsBytesSync(img.encodeJpg(img.Image(width: 400, height: 300)));
      final out = await writeZoomCrop(big.path, 2.0);
      final im = img.decodeImage(File(out).readAsBytesSync())!;
      expect(out, isNot(big.path));
      expect(im.width, lessThan(400));
      expect(im.height, lessThan(300));
    });

    test('failed name call → null (fail closed, nothing charged)', () async {
      final c = OpenRouterClient(
        apiKey: 'test',
        httpClient: MockClient((r) async => http.Response('err', 500)),
      );
      final d = SubjectDetector(openRouter: c, serverUrl: () async => '', deviceId: () async => 'x');
      expect(await d.detectMicroNameTimed(a, b), isNull);
    });
  });

  test('home wiring: name once per shot, part step on retakes', () {
    final h = File('lib/screens/home_camera_screen.dart').readAsStringSync();
    final a = h.indexOf('_coordinatedMicro(\n');
    final body = h.substring(a, h.indexOf('/// v11.27: X on the result', a));
    expect(body, contains('named ??= await _lockMicroObject(half, path, crop);'));
    expect(body, contains('_detector.detectMicroPart('));
    expect(body, contains('part: lock.isEmpty ? \'\' : microPartText(pp, lock),'));
    expect(body, contains('fail: kMicroNoLock'));
    expect(body, contains('fail: kMicroNoMatch'));
    expect(h, contains('_detector.detectMicroNameTimed('));
    expect(h, contains('await writeZoomCrop(shotPath, crop)'));
    expect(kMicroRetakes, 2);
  });
}
