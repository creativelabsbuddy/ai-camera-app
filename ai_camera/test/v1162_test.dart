// v11.62 tests: a tracked + matched root / reference is USED when the final
// is a digital crop of no better optics (no sharpness comparison: the
// digital final's noise only looks like edges), and that source crop is
// sent ALONE (no blurry final). Synthetic data; no network, no paid calls.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:ai_camera/services/account_service.dart';
import 'package:ai_camera/services/enhance_service.dart';
import 'package:ai_camera/services/local_ledger.dart';
import 'package:ai_camera/services/network_check.dart';
import 'package:ai_camera/services/openrouter_client.dart';
import 'package:ai_camera/services/server_api_client.dart';
import 'package:ai_camera/services/tracked_source.dart';
import 'package:ai_camera/services/zoom_root.dart';
import 'package:ai_camera/services/zoom_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

img.Image scene(int w, int h, int seed) {
  final r = math.Random(seed);
  final im = img.Image(width: w, height: h);
  const b = 16;
  final cols = List.generate(
    (w ~/ b + 1) * (h ~/ b + 1),
    (_) => [r.nextInt(256), r.nextInt(256), r.nextInt(256)],
  );
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final c = cols[(y ~/ b) * (w ~/ b + 1) + x ~/ b];
      final s = ((x + y) ~/ 3).isEven ? 30 : -30;
      im.setPixelRgb(
        x,
        y,
        (c[0] + s).clamp(0, 255),
        (c[1] + s).clamp(0, 255),
        (c[2] + s).clamp(0, 255),
      );
    }
  }
  return im;
}

/// Digital deep-zoom final: the area upscaled, plus strong sensor noise
/// (looks like "edges" to a sharpness measure).
img.Image noisyDigitalFinal(img.Image area, int seed) {
  final r = math.Random(seed);
  final big = img.copyResize(
    area,
    width: area.width * 3,
    height: area.height * 3,
  );
  for (final p in big) {
    int n() => (r.nextDouble() * 70 - 35).round();
    p
      ..r = (p.r + n()).clamp(0, 255)
      ..g = (p.g + n()).clamp(0, 255)
      ..b = (p.b + n()).clamp(0, 255);
  }
  return big;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('version 1.11.64+77', () {
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains('version: 1.11.64+77'),
    );
  });

  group('matched root is used on a digital-crop final', () {
    final wide = scene(480, 360, 7);
    // The tracked root region, softer than the noisy final looks.
    final rootBlurred = img.gaussianBlur(img.Image.from(wide), radius: 2);
    final area = img.copyCrop(wide, x: 90, y: 67, width: 300, height: 225);
    final fin = noisyDigitalFinal(area, 3);
    String write(img.Image im) => '/tmp/v1162_src.jpg';

    test('skipSharpnessFor: single lens / same optics → skip', () {
      expect(skipSharpnessFor(finalOptical: 1, refOptical: 1), isTrue);
      expect(skipSharpnessFor(finalOptical: 2, refOptical: 2), isTrue);
      expect(skipSharpnessFor(finalOptical: 1, refOptical: 2), isTrue);
      // a real 3x telephoto final vs a 1x root: optical vs optical → compare
      expect(skipSharpnessFor(finalOptical: 3, refOptical: 1), isFalse);
      expect(skipSharpnessFor(finalOptical: null, refOptical: 1), isFalse);
      expect(
        skipSharpnessFor(finalOptical: double.nan, refOptical: 1),
        isFalse,
      );
    });

    test('digital crop: match passes → used, sharpness skipped', () {
      final d = pickZoomSourceImages(
        finalArea: fin,
        refs: [(rootBlurred, 2, 1.6)],
        skipSharpness: const [true],
        labels: const ['root 2x'],
        realPxs: const [94],
        writeSource: write,
      );
      expect(d.ok, isTrue, reason: d.debugText);
      expect(d.sharpnessSkipped, isTrue);
      expect(d.sharpRatio, isNull);
      expect(
        d.debugText,
        allOf(
          startsWith('src root 2x roi 94px match '),
          endsWith('(sharpness skipped: digital crop)'),
        ),
      );
    });

    test('optical-vs-optical keeps the fair sharpness comparison', () {
      final sharpFinal = img.copyCrop(
        wide,
        x: 90,
        y: 67,
        width: 300,
        height: 225,
      );
      final d = pickZoomSourceImages(
        finalArea: sharpFinal,
        refs: [(img.gaussianBlur(img.Image.from(wide), radius: 6), 2, 1.6)],
        skipSharpness: const [false],
        writeSource: write,
      );
      expect(d.reason, ZoomSourceReason.sourceBlurrier, reason: d.debugText);
    });

    test('skip never bypasses the content match or the 32 px gate', () {
      final other = pickZoomSourceImages(
        finalArea: fin,
        refs: [(scene(480, 360, 99), 2, 1.6)],
        skipSharpness: const [true],
        writeSource: write,
      );
      expect(other.reason, ZoomSourceReason.noMatch);
      final tiny = pickZoomSourceImages(
        finalArea: fin,
        refs: [(img.copyResize(wide, width: 40, height: 30), 2, 1.6)],
        skipSharpness: const [true],
        writeSource: write,
      );
      expect(tiny.reason, ZoomSourceReason.tooSmall);
      expect(roiTooTiny(31), isTrue);
    });

    test('file path (isolate) carries the skip flag + label', () async {
      final dir = Directory.systemTemp.createTempSync('v1162');
      final fp = '${dir.path}/final.jpg';
      File(fp).writeAsBytesSync(img.encodeJpg(fin, quality: 95));
      final rp = '${dir.path}/ref.jpg';
      File(rp).writeAsBytesSync(img.encodeJpg(rootBlurred, quality: 95));
      final d = await pickZoomSource(
        finalAreaPath: fp,
        candidates: [
          ZoomSourceCandidate(
            rp,
            2,
            skipSharpness: true,
            label: 'root 2x',
            realPx: 94,
          ),
        ],
      );
      expect(d.ok, isTrue, reason: d.debugText);
      expect(d.debugText, contains('src root 2x roi 94px'));
      expect(d.debugText, contains('(sharpness skipped: digital crop)'));
      dir.deleteSync(recursive: true);
    });
  });

  group('root crop sent alone', () {
    late Directory dir;
    late File fin;
    late File src;
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AccountService.resetForTest(
        ledger: LocalLedger(clock: () => DateTime.utc(2026, 11, 12, 6)),
      );
      dir = Directory.systemTemp.createTempSync('v1162p');
      final wide = scene(480, 360, 3);
      final area = img.copyCrop(wide, x: 90, y: 67, width: 300, height: 225);
      fin = File('${dir.path}/final.jpg')
        ..writeAsBytesSync(img.encodeJpg(noisyDigitalFinal(area, 5)));
      src = File('${dir.path}/source.jpg')
        ..writeAsBytesSync(img.encodeJpg(area, quality: 100));
    });
    tearDown(() => dir.deleteSync(recursive: true));

    EnhanceJob job() => EnhanceJob(
      image: fin,
      zoomSource: src,
      zoomSourceOnly: true,
      zoom: 33,
      opticalLimit: 1,
      zoomClean: true,
    );

    test('job: source is the only image', () {
      final j = job();
      expect(j.isZoomSourceOnly, isTrue);
      expect(j.isZoomJob, isTrue);
      expect(j.primaryImage.path, src.path);
      expect(j.sentSteps, isEmpty);
      // the old two-image job is unchanged
      final two = EnhanceJob(
        image: fin,
        zoomSource: src,
        zoom: 33,
        opticalLimit: 1,
        zoomClean: true,
      );
      expect(two.sentSteps.single.path, fin.path);
    });

    test('key path: exactly ONE image uploaded (the source)', () async {
      final bodies = <Map<String, dynamic>>[];
      final out = img.decodeImage(src.readAsBytesSync())!;
      final c = MockClient((req) async {
        bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({
            'data': [
              {'b64_json': base64Encode(img.encodePng(out))},
            ],
          }),
          200,
        );
      });
      final r = await EnhanceService(
        openRouter: OpenRouterClient(httpClient: c, apiKey: 'test-key'),
        tempDir: () async => dir,
        net: NetworkCheck(probes: [(_) async => true]),
      ).enhance(job());
      expect(r.usedAi, isTrue, reason: '${r.aiError} ${r.guard}');
      final refs = bodies.single['input_references'] as List;
      expect(refs, hasLength(1));
      final u = (refs.single as Map)['image_url']['url'] as String;
      final sent = img.decodeImage(
        base64Decode(u.substring(u.indexOf(',') + 1)),
      )!;
      expect(sent.width, 300); // the source crop, not the 900-px final
    });

    test(
      'server path: zoom_clean single image, no zoom_source / steps',
      () async {
        SharedPreferences.setMockInitialValues({
          'enhance_server_url': 'http://srv:8787/',
        });
        AccountService.resetForTest(
          ledger: LocalLedger(clock: () => DateTime.utc(2026, 11, 12, 6)),
        );
        String? body;
        final mock = MockClient((req) async {
          if (req.url.path == '/v1/enhance') {
            body = utf8.decode(req.bodyBytes, allowMalformed: true);
          }
          return http.Response('{"detail":"test"}', 500);
        });
        await EnhanceService(
          server: ServerApiClient(httpClient: mock),
          openRouter: OpenRouterClient(httpClient: mock, apiKey: ''),
          tempDir: () async => dir,
          net: NetworkCheck(probes: [(_) async => true]),
        ).enhance(job());
        expect(body, isNotNull);
        expect(body, contains('name="zoom_clean"'));
        expect(body, isNot(contains('name="zoom_source"')));
        expect(body, isNot(contains('name="steps"')));
      },
    );
  });

  test('home wiring: last photo always sent, beyond-range label kept', () {
    final h = File('lib/screens/home_camera_screen.dart').readAsStringSync();
    expect(h, contains('finalOptical: refZoomLabel('));
    expect(h, contains("sent = 'sent final only';"));
    expect(h, isNot(contains('zoomSourceOnly = d.sharpnessSkipped;')));
    expect(h, isNot(contains("'sent source crop only (framing from tracking)'")));
    expect(h, contains('zoomFailClosed(ok: d.ok, need: need, tiny: tiny)'));
    expect(h, contains('if (beyond) zoomLabel = kBeyondClearLabel;'));
  });
}
