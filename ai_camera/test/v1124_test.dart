import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  late File one;

  setUpAll(() {
    UploadPrep.nativeDecode = false;
    tmp = Directory.systemTemp.createTempSync('v1124');
    final im = img.Image(width: 40, height: 30);
    img.fill(im, color: img.ColorRgb8(70, 90, 110)); // synthetic, no photo
    one = File('${tmp.path}/one.jpg')..writeAsBytesSync(img.encodeJpg(im));
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  http.Response chat(String content) => http.Response(
    jsonEncode({
      'choices': [
        {
          'message': {'content': content},
          'finish_reason': 'stop',
        },
      ],
    }),
    200,
  );

  SubjectDetector det(Future<http.Response> Function(http.Request) h) =>
      SubjectDetector(
        openRouter: OpenRouterClient(apiKey: 'k', httpClient: MockClient(h)),
        server: ServerApiClient(),
        serverUrl: () async => '',
        deviceId: () async => 'dev',
      );

  test('overall limit is 8 s, single attempt', () {
    expect(kDetectSubjectTimeout, const Duration(seconds: 8));
  });

  test(
    'never-returning request → times out at 8 s and clears busy',
    () async {
      var calls = 0;
      final d = det((r) {
        calls++;
        return Completer<http.Response>().future; // never returns
      });
      final sw = Stopwatch()..start();
      final f = d.detectSubjectTimed(one);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(d.busy, isTrue);
      expect(await f, isNull);
      sw.stop();
      expect(sw.elapsed, greaterThanOrEqualTo(const Duration(seconds: 8)));
      expect(sw.elapsed, lessThan(const Duration(seconds: 12)));
      expect(d.busy, isFalse);
      expect(d.lastReason, 'timeout 8s');
      expect(detectDebugText(d.lastReason), 'detect: timeout 8s');
      expect(calls, 1); // no automatic retry
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('re-tap cancels the old call and starts fresh at once', () async {
    final first = Completer<http.Response>();
    var n = 0;
    final d = det((r) {
      n++;
      return n == 1 ? first.future : Future.value(chat('red mug'));
    });
    final old = d.detectSubjectTimed(one);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(d.busy, isTrue);
    // user taps 1.5x again → new photo → new call, no 6 s wait
    final sw = Stopwatch()..start();
    final fresh = await d.detectSubjectTimed(one);
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    expect(fresh, 'red mug');
    expect(n, 2);
    expect(await old, isNull); // cancelled one gives nothing
    expect(d.busy, isFalse);
  });

  test(
    'late stale result is ignored and never keeps the detector busy',
    () async {
      final first = Completer<http.Response>();
      var n = 0;
      final d = det((r) {
        n++;
        return n == 1 ? first.future : Completer<http.Response>().future;
      });
      final old = d.detectSubjectTimed(one);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      d.cancelInFlight(); // 1x tap
      expect(d.busy, isFalse); // free immediately
      expect(d.lastReason, 'cancelled');
      first.complete(chat('blue pen')); // arrives late
      expect(await old, isNull);
      expect(d.busy, isFalse);
      expect(d.lastReason, 'cancelled'); // not overwritten by the stale call

      // The UI side: a stale generation never completes the lock.
      final lock = SubjectLock();
      final g1 = lock.beginDetect();
      lock.cancelDetect(); // re-tap / 1x
      expect(lock.detecting, isFalse); // "Detecting…" cleared at once
      final g2 = lock.beginDetect();
      expect(lock.completeDetect(g1, 'blue pen'), isFalse);
      expect(lock.parent, isNull);
      expect(lock.completeDetect(g2, null), isTrue);
      expect(lock.detecting, isFalse);
      expect(n, 1);
    },
  );

  test('guide: Detecting… before a result, failure text only after', () {
    expect(
      macroFlowGuide(chip: 1.5, stage: 0, detecting: false),
      kGuideDetecting,
    );
    expect(
      macroFlowGuide(chip: 1.5, stage: 0, detecting: false, failed: true),
      kGuideDetectFailed,
    );
    expect(kDetectRetryLabel, 'Try again');
  });

  test(
    'home screen: 8 s timed call, no silent busy wait, retry + cancel',
    () {
      final s = File('lib/screens/home_camera_screen.dart').readAsStringSync();
      final a = s.indexOf('Future<void> _detectParent(');
      final body = s.substring(a, s.indexOf('void _cancelSubjectDetect()', a));
      expect(body, contains('_detector.detectSubjectTimed(File(path))'));
      expect(body, isNot(contains('_detector.busy')));
      expect(body, isNot(contains('Future<void>.delayed')));
      expect(s, contains("ValueKey('macro_detect_retry')"));
      expect(s, contains("'no photo (torch)'"));
      expect(s, contains('_cancelSubjectDetect(); // v11.24: 1x'));
      expect(s, contains('failed: _detectFailed'));
    },
    skip: 'v11.33: replaced by level chips + box check',
  );
}
