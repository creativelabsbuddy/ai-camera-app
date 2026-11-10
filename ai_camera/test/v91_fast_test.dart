import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_camera/models/ai_style.dart';
import 'package:ai_camera/models/quality_tier.dart';
import 'package:ai_camera/screens/look_screen.dart';
import 'package:ai_camera/services/account_service.dart';
import 'package:ai_camera/services/ai_call.dart';
import 'package:ai_camera/services/custom_prompt_policy.dart';
import 'package:ai_camera/services/local_ledger.dart';
import 'package:ai_camera/services/look_service.dart';
import 'package:ai_camera/services/openrouter_client.dart';
import 'package:ai_camera/services/person_check.dart';
import 'package:ai_camera/services/server_api_client.dart';
import 'package:ai_camera/services/style_catalog.dart';
import 'package:ai_camera/services/upload_prep.dart' show kLookInputLongSide;
import 'package:ai_camera/widgets/look_sheet.dart';
import 'package:ai_camera/widgets/credit_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

String jpgB64(int w, int h) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(10, 120, 200));
  return base64Encode(img.encodeJpg(im));
}

http.Response okImage({double cost = 0.02, int count = 1}) => http.Response(
  jsonEncode({
    'data': [
      for (var i = 0; i < count; i++) {'b64_json': jpgB64(48, 64)},
    ],
    'usage': {'cost': cost},
  }),
  200,
);

img.Image decodeDataUrl(String url) =>
    img.decodeJpg(base64Decode(url.substring(url.indexOf(',') + 1)))!;

const paris = AiStyle(
  id: 'paris_eiffel',
  name: 'Paris Eiffel',
  category: 'Travel',
  creditCost: 2,
);
const mountains = AiStyle(
  id: 'snowy_mood',
  name: 'Snowy mood',
  category: 'Scene',
  creditCost: 2,
  needsPerson: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final t0 = DateTime.utc(2026, 10, 8, 6);
  late Directory dir;
  late File big; // 12 MP-like capture
  late File rotated; // EXIF orientation 6 (portrait shot stored landscape)

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('v91');
    final im = img.Image(width: 4000, height: 3000);
    img.fill(im, color: img.ColorRgb8(90, 140, 60));
    big = File('${dir.path}/big.jpg')
      ..writeAsBytesSync(img.encodeJpg(im, quality: 92));
    final r = img.Image(width: 2400, height: 1800);
    img.fill(r, color: img.ColorRgb8(200, 30, 30)); // left half red
    img.fillRect(
      r,
      x1: 1200,
      y1: 0,
      x2: 2399,
      y2: 1799,
      color: img.ColorRgb8(30, 30, 200),
    );
    r.exif.imageIfd.orientation = 6;
    rotated = File('${dir.path}/rot.jpg')..writeAsBytesSync(img.encodeJpg(r));
  });
  tearDownAll(() => dir.deleteSync(recursive: true));

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AccountService.resetForTest(ledger: LocalLedger(clock: () => t0));
    PersonCheck.reset();
    UploadPrep.nativeDecode = true;
  });

  LookService service(http.Client mock, {Duration? timeout}) => LookService(
    openRouter: OpenRouterClient(
      httpClient: mock,
      apiKey: 'test-key',
      timeout: timeout ?? kAiRequestTimeout,
    ),
    tempDir: () async => dir,
    localPromptFor: (id) => 'Place the person in Paris.',
  );

  Future<int> balance() async =>
      (await AccountService.instance.refresh()).total(t0);

  group('input downscale + payload', () {
    for (final native in [true, false]) {
      test('12 MP capture → 1536 px JPEG for looks (native=$native)', () async {
        UploadPrep.nativeDecode = native;
        final bodies = <Map<String, dynamic>>[];
        final mock = MockClient((req) async {
          bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
          return okImage();
        });
        final r = await service(mock).apply(
          LookJob(
            image: big,
            customPrompt: 'black suit',
            tier: QualityTier.ultraHd,
          ),
        );
        expect(r.ok, isTrue, reason: r.error);
        expect(bodies, hasLength(1)); // 4 variations OFF → exactly one call
        final refs = bodies.single['input_references'] as List;
        final sent = decodeDataUrl(refs.first['image_url']['url'] as String);
        expect([sent.width, sent.height], [kLookInputLongSide, 1152]);
        expect(UploadPrep.lastPath, native ? isIn(['native', 'dart']) : 'dart');
        // UHD custom change is clamped to Full HD → Flare medium, JPEG out.
        expect(bodies.single['quality'], 'medium');
        expect(bodies.single['output_format'], 'jpeg');
        expect(bodies.single['n'], 1);
        // Request is a fraction of the original upload.
        expect(
          utf8.encode(jsonEncode(bodies.single)).length,
          lessThan(big.lengthSync()),
        );
        // Look output is NOT upscaled (model native size).
        expect(img.decodeJpg(r.files.first.readAsBytesSync())!.width, 48);
      });
    }

    for (final native in [true, false]) {
      test('EXIF-rotated photo is uploaded upright (native=$native)', () async {
        UploadPrep.nativeDecode = native;
        final p = await prepareUpload(rotated.readAsBytesSync(), maxLong: 1536);
        expect([p.width, p.height], [1152, 1536]);
        final d = img.decodeJpg(p.bytes)!;
        expect([d.width, d.height], [1152, 1536]);
        // Orientation 6 = rotate 90° CW: raw left (red) ends up on top.
        expect(d.getPixel(576, 100).r, greaterThan(150));
        expect(d.getPixel(576, 1436).b, greaterThan(150));
      });
    }

    test('small upright JPEG passes through untouched', () async {
      final im = img.Image(width: 800, height: 600);
      final bytes = img.encodeJpg(im);
      final p = await prepareUpload(bytes, maxLong: 1536);
      expect(p.bytes, same(bytes));
    });

    test(
      'server path uploads the downscaled JPEG, not the 12 MP file',
      () async {
        int? uploaded;
        final mock = MockClient((req) async {
          uploaded = req.bodyBytes.length;
          return http.Response(
            jsonEncode({
              'images': [jpgB64(32, 32)],
              'credits_charged': 2,
              'trials_used': [],
            }),
            200,
          );
        });
        await ServerApiClient(httpClient: mock).applyLook(
          baseUrl: 'https://x',
          deviceId: 'd',
          image: big,
          styleId: 'paris_eiffel',
        );
        expect(uploaded, isNotNull);
        expect(uploaded!, lessThan(big.lengthSync() ~/ 2));
      },
    );

    test('look quality: HD → low, everything else → medium; tiers clamp', () {
      expect(lookQualityFor(QualityTier.hd), 'low');
      expect(lookQualityFor(QualityTier.fullHd), 'medium');
      expect(lookQualityFor(QualityTier.k4), 'medium');
      expect(lookTierFor(QualityTier.k4), QualityTier.fullHd);
      final j = LookJob(image: big, customPrompt: 'x', tier: QualityTier.k4);
      expect(j.creditCostPerImage, 2); // charged as Full HD, not 8
    });
  });

  group('failures never charge', () {
    test('timeout → timeout failure, nothing charged', () async {
      final mock = MockClient((_) => Completer<http.Response>().future);
      final before = await balance();
      final r = await service(
        mock,
        timeout: const Duration(milliseconds: 200),
      ).apply(LookJob(image: big, customPrompt: 'black suit'));
      expect(r.ok, isFalse);
      expect(r.failure, AiFailureKind.timeout);
      expect(await balance(), before);
      expect(aiFailureMessage(r.failure!), contains('took too long'));
    });

    test('text-only answer (no image) → noImage, nothing charged', () async {
      final mock = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'data': [],
            'output_text': 'There is no person to dress.',
          }),
          200,
        ),
      );
      final before = await balance();
      final r = await service(
        mock,
      ).apply(LookJob(image: big, customPrompt: 'black suit'));
      expect(r.failure, AiFailureKind.noImage);
      expect(await balance(), before);
      expect(
        aiFailureMessage(r.failure!, isStyle: true),
        "Couldn't apply this style. Try a photo with a person. No credits used.",
      );
    });

    test('moderation refusal (HTTP 400) → refused, nothing charged', () async {
      final mock = MockClient(
        (_) async => http.Response(
          '{"error":{"code":"moderation_blocked","message":"Request blocked by safety system"}}',
          400,
        ),
      );
      final before = await balance();
      final r = await service(
        mock,
      ).apply(LookJob(image: big, customPrompt: 'a hat'));
      expect(r.failure, AiFailureKind.refused);
      expect(await balance(), before);
    });

    test('blocked custom prompt → no AI call at all', () async {
      var calls = 0;
      final mock = MockClient((_) async {
        calls++;
        return okImage();
      });
      final r = await service(
        mock,
      ).apply(LookJob(image: big, customPrompt: 'make her naked'));
      expect(r.failure, AiFailureKind.blocked);
      expect(calls, 0);
    });

    test(
      'cancel → cancelled, nothing charged even if the AI answers later',
      () async {
        final gate = Completer<http.Response>();
        final mock = MockClient((_) => gate.future);
        final token = AiCancelToken();
        final before = await balance();
        final f = service(mock).apply(
          LookJob(image: big, customPrompt: 'black suit'),
          cancel: token,
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        token.cancel();
        gate.complete(okImage());
        final r = await f;
        expect(r.cancelled, isTrue);
        expect(await balance(), before);
      },
    );

    test('server 502 {reason:no_image} / 504 map to failure kinds', () async {
      for (final (code, body, kind) in [
        (502, '{"detail":{"reason":"no_image"}}', AiFailureKind.noImage),
        (504, '{"detail":{"reason":"timeout"}}', AiFailureKind.timeout),
        (400, '{"detail":{"reason":"blocked"}}', AiFailureKind.blocked),
      ]) {
        final mock = MockClient((_) async => http.Response(body, code));
        try {
          await ServerApiClient(httpClient: mock).applyLook(
            baseUrl: 'https://x',
            deviceId: 'd',
            image: big,
            styleId: 's',
          );
          fail('should throw');
        } on ServerApiException catch (e) {
          expect(e.failureKind, kind);
        }
      }
    });

    test(
      'server body stall → timeout (whole response is time-limited)',
      () async {
        final mock = MockClient.streaming((req, body) async {
          await body.drain<void>();
          return http.StreamedResponse(
            Stream<List<int>>.fromFuture(Completer<List<int>>().future),
            200,
          );
        });
        final c = ServerApiClient(
          httpClient: mock,
          aiTimeout: const Duration(milliseconds: 300),
        );
        await expectLater(
          c.applyLook(
            baseUrl: 'https://x',
            deviceId: 'd',
            image: big,
            styleId: 's',
          ),
          throwsA(isA<TimeoutException>()),
        );
      },
    );
  });

  group('variations', () {
    test('n=4, provider returns 1 → 3 parallel single top-ups', () async {
      final ns = <int>[];
      var inFlight = 0;
      var maxInFlight = 0;
      final mock = MockClient((req) async {
        ns.add((jsonDecode(req.body) as Map)['n'] as int);
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        inFlight--;
        return okImage();
      });
      final client = OpenRouterClient(httpClient: mock, apiKey: 'k');
      final r = await client.generateLook(
        image: big,
        prompt: 'p',
        tier: QualityTier.fullHd,
        n: 4,
      );
      expect(r.images, hasLength(4));
      expect(ns, [4, 1, 1, 1]);
      expect(maxInFlight, 3); // top-ups ran in parallel
    });
  });

  group('safety list (tiny, no relevance check)', () {
    test('blocks only the basic categories', () {
      for (final bad in [
        'make her naked',
        'remove his clothes',
        'sexy lingerie',
        'face swap me with Shah Rukh Khan',
        'replace my face with my friend',
        'add gore and a corpse',
      ]) {
        expect(blockedCustomPromptReason(bad), isNotNull, reason: bad);
      }
      for (final ok in [
        'black suit',
        'make the sky purple',
        'turn my cat into a tiger',
        'add a pizza on the table',
        'Swiss Alps background',
        'remove the person in the back',
      ]) {
        expect(blockedCustomPromptReason(ok), isNull, reason: ok);
      }
      expect(normalizeCustomPrompt('a' * 300).length, kCustomPromptMaxChars);
      expect(kCustomPromptMaxChars, 200);
    });
  });

  group('UI', () {
    setUp(() {
      StyleCatalog.resetForTest(
        StyleCatalog(
          serverUrl: () async => '',
          loadAsset: (_) async => '{"styles":[]}',
          cacheDir: () async => dir,
        ),
      );
    });
    tearDown(LookFlowDeps.reset);

    testWidgets('wave overlay: elapsed seconds + Cancel → no charge message', (
      tester,
    ) async {
      final pending = Completer<LookResult>();
      LookFlowDeps.service = () => _FakeLook((_) => pending.future);
      await tester.pumpWidget(
        MaterialApp(
          home: LookScreen(
            original: big,
            job: LookJob(image: big, customPrompt: 'black suit'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(find.textContaining('· 3s'), findsOneWidget);
      expect(find.byKey(const ValueKey('ai_cancel')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ai_cancel')));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Cancelled — no credits used.'), findsOneWidget);
      expect(find.byKey(const ValueKey('ai_cancel')), findsNothing);
      pending.complete(const LookResult(error: 'late'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Cancelled — no credits used.'), findsOneWidget);
    });

    testWidgets('a hung service still exits loading (watchdog → timeout)', (
      tester,
    ) async {
      LookFlowDeps.service = () =>
          _FakeLook((_) => Completer<LookResult>().future);
      await tester.pumpWidget(
        MaterialApp(
          home: LookScreen(
            original: big,
            job: LookJob(image: big, style: paris),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(LookScreen.watchdog + const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.textContaining('took too long'), findsOneWidget);
      expect(find.byKey(const ValueKey('ai_cancel')), findsNothing);
    });

    testWidgets('failure kinds show clear messages; Retry available', (
      tester,
    ) async {
      LookFlowDeps.service = () => _FakeLook(
        (_) async =>
            const LookResult(error: 'x', failure: AiFailureKind.noImage),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: LookScreen(
            original: big,
            job: LookJob(image: big, customPrompt: 'black suit'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        find.text(
          "Couldn't apply this change. Try a photo with a person or different "
          'words. No credits used.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('look_retry')), findsOneWidget);
    });

    Future<void> openSheetAndApply(
      WidgetTester tester, {
      AiStyle? style,
      String? prompt,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => startLook(
                  context,
                  photo: big,
                  style: style,
                  initialPrompt: prompt,
                ),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.ensureVisible(find.byKey(const ValueKey('look_apply')));
      await tester.tap(find.byKey(const ValueKey('look_apply')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('person style + no face → warning; cancel spends nothing', (
      tester,
    ) async {
      var applied = 0;
      PersonCheck.detector = (_) async => false;
      LookFlowDeps.service = () => _FakeLook((_) async {
        applied++;
        return const LookResult(error: 'x', failure: AiFailureKind.other);
      });
      await openSheetAndApply(tester, style: paris);
      expect(find.byKey(const ValueKey('person_warning')), findsOneWidget);
      expect(find.text('No person found in this photo'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('person_warning_cancel')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(LookScreen), findsNothing);
      expect(applied, 0);
    });

    testWidgets('person style + no face → Apply anyway runs the look', (
      tester,
    ) async {
      var applied = 0;
      PersonCheck.detector = (_) async => false;
      LookFlowDeps.service = () => _FakeLook((_) async {
        applied++;
        return const LookResult(error: 'x', failure: AiFailureKind.other);
      });
      await openSheetAndApply(tester, style: paris);
      await tester.tap(find.byKey(const ValueKey('person_warning_apply')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(LookScreen), findsOneWidget);
      expect(applied, 1);
    });

    testWidgets('custom change and non-person styles are never pre-checked', (
      tester,
    ) async {
      var checks = 0;
      PersonCheck.detector = (_) async {
        checks++;
        return false;
      };
      LookFlowDeps.service = () => _FakeLook(
        (_) async => const LookResult(error: 'x', failure: AiFailureKind.other),
      );
      await openSheetAndApply(tester, prompt: 'black suit');
      expect(find.byKey(const ValueKey('person_warning')), findsNothing);
      expect(find.byType(LookScreen), findsOneWidget);
      expect(checks, 0);
    });

    testWidgets(
      'custom box: 200 chars, examples, safety error, HD/FHD tiers only',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () =>
                      showLookSheet(context, photo: big, tier: QualityTier.k4),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('go'));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        final field = find.byKey(const ValueKey('custom_prompt_field'));
        expect(tester.widget<TextField>(field).maxLength, 200);
        expect(find.byKey(const ValueKey('custom_tier_hd')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('custom_tier_full_hd')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('custom_tier_ultra_hd')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('custom_tier_4k')), findsNothing);
        // 4K capture tier → defaults to Full HD (🪙2).
        expect(find.byWidgetPredicate((w) => isCreditText(w, 'Apply · 🪙2')), findsOneWidget);
        // v11.56: "Prompt" title + field, no example chips.
        expect(find.byKey(const ValueKey('custom_example_Black suit')), findsNothing);
        expect(find.text('Black suit'), findsNothing);
        expect(find.text('Write your prompt…'), findsOneWidget);
        expect(find.text('Describe a change'), findsNothing);
        await tester.enterText(field, 'make her naked');
        await tester.pump();
        expect(
          find.textContaining("This change isn't allowed"),
          findsOneWidget,
        );
        final apply = tester.widget<FilledButton>(
          find.byKey(const ValueKey('look_apply')),
        );
        expect(apply.onPressed, isNull);
        await tester.enterText(field, 'x' * 260);
        await tester.pump();
        expect(tester.widget<TextField>(field).controller!.text.length, 200);
      },
    );
  });
}

class _FakeLook extends LookService {
  _FakeLook(this.run) : super(tempDir: () async => Directory.systemTemp);
  final Future<LookResult> Function(LookJob job) run;
  @override
  Future<LookResult> apply(LookJob job, {AiCancelToken? cancel}) => run(job);
}
