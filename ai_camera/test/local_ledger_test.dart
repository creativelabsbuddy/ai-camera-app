import 'dart:convert';
import 'dart:io';

import 'package:ai_camera/models/quality_tier.dart';
import 'package:ai_camera/services/account_service.dart';
import 'package:ai_camera/services/enhance_service.dart';
import 'package:ai_camera/services/entitlements.dart';
import 'package:ai_camera/services/local_ledger.dart';
import 'package:ai_camera/services/openrouter_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

String pngB64(int w, int h) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(10, 120, 200));
  return base64Encode(img.encodePng(im));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DateTime now;
  late Directory dir;
  late File photo;
  late File context;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    now = DateTime.utc(2026, 10, 7, 10);
    AccountService.resetForTest(ledger: LocalLedger(clock: () => now));
    dir = Directory.systemTemp.createTempSync('ledger');
    final im = img.Image(width: 300, height: 400);
    img.fill(im, color: img.ColorRgb8(200, 100, 50));
    photo = File('${dir.path}/crop.jpg')..writeAsBytesSync(img.encodeJpg(im));
    context = File('${dir.path}/ctx.jpg')..writeAsBytesSync(img.encodeJpg(im));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  EnhanceService service(http.Client client) => EnhanceService(
    openRouter: OpenRouterClient(httpClient: client, apiKey: 'test-key'),
    tempDir: () async => dir,
  );

  test('ledger persists + resets daily (IST)', () async {
    final ledger = AccountService.instance.ledger;
    var s = await ledger.load();
    expect(s.freeDaily, 2);
    s = await ledger.commit(const EnhanceSpec(tier: QualityTier.hd));
    s = await ledger.commit(const EnhanceSpec(tier: QualityTier.hd));
    expect((await ledger.load()).freeDaily, 0);
    now = DateTime.utc(2026, 10, 7, 18, 31); // 00:01 IST 8 Oct
    expect((await ledger.load()).freeDaily, 2);
  });

  test('successful AI call charges 1 HD credit; 2 images sent', () async {
    final bodies = <Map<String, dynamic>>[];
    final client = MockClient((req) async {
      bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
      return http.Response(
        jsonEncode({
          'data': [
            {'b64_json': pngB64(96, 128)},
          ],
          'usage': {'cost': 0.02},
        }),
        200,
      );
    });
    await AccountService.instance.refresh();
    final r = await service(client).enhance(
      EnhanceJob(image: photo, context: context, zoom: 3, opticalLimit: 5),
    );
    expect(r.usedAi, isTrue);
    expect(r.creditsCharged, 1);
    expect(r.contextUsed, isTrue);
    expect(bodies.single['input_references'], hasLength(2));
    expect(bodies.single['quality'], 'low');
    expect(bodies.single['resolution'], '1K');
    expect(
      (bodies.single['prompt'] as String),
      contains('Use the second image only to understand the scene'),
    );
    // Output resampled to the HD target (≥1024 long side).
    final out = img.decodeImage(r.file!.readAsBytesSync())!;
    expect(out.height, greaterThanOrEqualTo(1000));
    expect((await AccountService.instance.ledger.load()).freeDaily, 1);
  });

  test(
    '2-image rejection falls back to crop only (still charged once)',
    () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        final refs = (jsonDecode(req.body) as Map)['input_references'] as List;
        if (refs.length == 2) {
          return http.Response('{"error":"only one image supported"}', 400);
        }
        return http.Response(
          jsonEncode({
            'data': [
              {'b64_json': pngB64(1024, 1365)},
            ],
          }),
          200,
        );
      });
      final r = await service(client).enhance(
        EnhanceJob(image: photo, context: context, zoom: 20, opticalLimit: 5),
      );
      expect(calls, 2);
      expect(r.usedAi, isTrue);
      expect(r.contextUsed, isFalse);
      // 20x > optical 5 for a free user → covered by the high-zoom trial.
      expect(r.trialsUsed, [StarterTrial.highZoom]);
      expect(r.creditsCharged, 0);
      final s = await AccountService.instance.ledger.load();
      expect(s.freeDaily, 2);
      expect(s.trialsUsed, {StarterTrial.highZoom});
    },
  );

  test('failed AI call deducts nothing and burns no trial', () async {
    final client = MockClient(
      (req) async => http.Response('{"error":"upstream down"}', 500),
    );
    final r = await service(client).enhance(
      EnhanceJob(
        image: photo,
        tier: QualityTier.ultraHd,
        zoom: 20,
        opticalLimit: 5,
      ),
    );
    expect(r.usedAi, isFalse);
    expect(r.fellBackFromAi, isTrue);
    final s = await AccountService.instance.ledger.load();
    expect(s.freeDaily, 2);
    expect(s.trialsUsed, isEmpty);
  });

  test('denied request never calls the API', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return http.Response('{}', 200);
    });
    // Burn the high-zoom trial first.
    await AccountService.instance.ledger.commit(
      const EnhanceSpec(tier: QualityTier.hd, zoom: 20, opticalLimit: 5),
    );
    await AccountService.instance.refresh();
    final r = await service(
      client,
    ).enhance(EnhanceJob(image: photo, zoom: 30, opticalLimit: 5));
    expect(r.denied, DenyReason.zoomNeedsPro);
    expect(calls, 0);
  });
}
