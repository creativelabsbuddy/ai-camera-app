import 'dart:convert';
import 'dart:io';

import 'package:ai_camera/services/capture_crop.dart';
import 'package:ai_camera/services/macro.dart';
import 'package:ai_camera/services/openrouter_client.dart';
import 'package:ai_camera/services/server_api_client.dart';
import 'package:ai_camera/services/subject_detector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

void main() {
  late Directory tmp;
  late File one, closer;

  setUpAll(() {
    UploadPrep.nativeDecode = false;
    tmp = Directory.systemTemp.createTempSync('v1119');
    // Synthetic frames only (no camera / test photos).
    final flat = img.Image(width: 80, height: 60);
    img.fill(flat, color: img.ColorRgb8(90, 90, 90));
    one = File('${tmp.path}/one.jpg')..writeAsBytesSync(img.encodeJpg(flat));
    closer = File('${tmp.path}/closer.jpg')
      ..writeAsBytesSync(img.encodeJpg(flat));
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  test('sharpness: checkerboard ≫ flat; clear rule vs the 4x photo', () {
    final flat = img.Image(width: 64, height: 64);
    img.fill(flat, color: img.ColorRgb8(128, 128, 128));
    final chk = img.Image(width: 64, height: 64);
    for (final p in chk) {
      final on = ((p.x ~/ 2) + (p.y ~/ 2)).isEven;
      p
        ..r = on ? 255 : 0
        ..g = on ? 255 : 0
        ..b = on ? 255 : 0;
    }
    expect(sharpnessOf(flat), lessThan(1));
    expect(sharpnessOf(chk), greaterThan(1000));
    expect(isClearPhoto(40, 100), isTrue);
    expect(isClearPhoto(30, 100), isFalse); // < kClearSharpnessRatio
    expect(kClearSharpnessRatio, 0.35);
  });

  test('final zoom box: centred, 1/regionZoom of the photo', () {
    final r = zoomBoxRect(1000, 800, 25 / 6);
    expect(r.width, 240);
    expect(r.x, 380);
    expect(r.y, (800 - r.height) ~/ 2);
    expect(zoomBoxRect(1000, 800, 1000).width, 30); // min 3 % visible
  });

  test('spot call: overview + boxed closer, prompt, mocked', () async {
    final seen = <Map<String, dynamic>>[];
    final d = SubjectDetector(
      openRouter: OpenRouterClient(
        apiKey: 'test',
        httpClient: MockClient((r) async {
          seen.add(jsonDecode(r.body) as Map<String, dynamic>);
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'Ant eye.'},
                },
              ],
            }),
            200,
          );
        }),
      ),
      server: ServerApiClient(),
      serverUrl: () async => '',
      deviceId: () async => 'dev',
    );
    final boxed = await writeZoomBoxed(closer.path, 4);
    expect(await d.detectSpot(one, File(boxed), 'ant on a leaf'), 'ant eye');
    final c = (seen.single['messages'] as List).first['content'] as List;
    expect(c.length, 3);
    expect(
      c.first['text'],
      startsWith(
        'Photo 1 is the overview; main object: ant on a leaf; objects in '
        'it: ant on a leaf. Photo 2 is a closer view; the small red box '
        'marks exactly where the camera is zoomed.',
      ),
    );
    expect(seen.single['model'], 'google/gemini-2.5-flash'); // v11.27
  });

  test('spot via server endpoint; failure → null', () async {
    final paths = <String>[];
    final ok = SubjectDetector(
      openRouter: OpenRouterClient(apiKey: ''),
      server: ServerApiClient(
        httpClient: MockClient((r) async {
          paths.add(r.url.path);
          return http.Response('{"spot": "leaf vein"}', 200);
        }),
      ),
      serverUrl: () async => 'http://srv',
      deviceId: () async => 'dev',
    );
    expect(await ok.detectSpot(one, closer, 'leaf'), 'leaf vein');
    expect(paths, ['/v1/macro/spot']);
    final bad = SubjectDetector(
      openRouter: OpenRouterClient(
        apiKey: 'k',
        httpClient: MockClient((r) async => http.Response('x', 500)),
      ),
      server: ServerApiClient(),
      serverUrl: () async => '',
      deviceId: () async => 'dev',
    );
    expect(await bad.detectSpot(one, closer, 'leaf'), isNull);
  });

  test(
    'wiring: Extreme sends the crop only; spot at shutter',
    () {
      final h = File('lib/screens/home_camera_screen.dart').readAsStringSync();
      expect(
        h,
        contains('part: macro ? await _detectFinalSpot(snap.zoom) : null'),
      );
      expect(h, contains('stepFiles: extreme'));
      expect(h, contains('extreme ||')); // v11.30 layout
      expect(h, isNot(contains('writeExtremeSpot(')));
      final e = File('lib/services/enhance_service.dart').readAsStringSync();
      expect(e, contains('leading: job.sentSteps')); // v11.30
      expect(macroInputPlan('extreme').maxSteps, 2); // v11.26
    },
    skip: 'v11.33: replaced by level chips + box check',
  );
}
