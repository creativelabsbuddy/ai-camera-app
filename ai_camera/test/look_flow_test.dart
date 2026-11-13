import 'dart:convert';
import 'dart:io';

import 'package:ai_camera/models/ai_style.dart';
import 'package:ai_camera/models/products.dart';
import 'package:ai_camera/models/quality_tier.dart';
import 'package:ai_camera/services/account_service.dart';
import 'package:ai_camera/services/entitlements.dart';
import 'package:ai_camera/services/local_ledger.dart';
import 'package:ai_camera/services/look_service.dart';
import 'package:ai_camera/services/openrouter_client.dart';
import 'package:ai_camera/services/prompt_builder.dart';
import 'package:ai_camera/services/server_api_client.dart';
import 'package:ai_camera/widgets/look_sheet.dart';
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

const paris = AiStyle(
  id: 'paris_eiffel',
  name: 'Paris Eiffel',
  category: 'Travel',
  creditCost: 2,
);
const sherwani = AiStyle(
  id: 'royal_sherwani',
  name: 'Royal sherwani',
  category: 'Outfit',
  creditCost: 3,
  proOnly: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final t0 = DateTime.utc(2026, 10, 7, 10);

  group('decideLook (mirror of server ledger.decide_look)', () {
    final s = CreditState.initial(t0);
    test('v11.57: first style apply charges credit cost (no free trial)', () {
      final d = decideLook(s, const LookSpec(creditCost: 2), t0);
      expect(d.allowed, isTrue);
      expect(d.trials, isEmpty);
      expect(d.fromFree, 2);
      expect(d.credits, 2);
      expect(
        decideLook(s, const LookSpec(creditCost: 3), t0).reason,
        DenyReason.noCredits,
      );
    });
    test('library_style trial leftover does not make styles free', () {
      final used = s.copyWith(trialsUsed: {});
      final d = decideLook(used, const LookSpec(creditCost: 2), t0);
      expect(d.trials, isEmpty);
      expect(d.fromFree, 2);
    });
    test('4 variations = 4× credits, never the trial', () {
      final d = decideLook(
        s.copyWith(packCredits: 10),
        const LookSpec(creditCost: 2, variations: 4),
        t0,
      );
      expect(d.trials, isEmpty);
      expect(d.credits, 8);
      expect(d.fromFree, 2);
      expect(d.fromPack, 6);
    });
    test('custom change: tier credits, available to free users', () {
      final d = decideLook(
        s,
        const LookSpec(creditCost: 1, isStyle: false),
        t0,
      );
      expect(d.allowed, isTrue);
      expect(d.trials, isEmpty);
      expect(d.fromFree, 1);
    });
    test('Pro-only style needs Pro; Pro pays from sub credits', () {
      expect(
        decideLook(s, const LookSpec(creditCost: 3, proOnly: true), t0).reason,
        DenyReason.styleNeedsPro,
      );
      final pro = s.copyWith(
        proUntil: t0.add(const Duration(days: 5)),
        subCredits: 100,
      );
      final d = decideLook(
        pro,
        const LookSpec(creditCost: 3, proOnly: true),
        t0,
      );
      expect(d.trials, isEmpty);
      expect(d.fromFree, 2);
      expect(d.fromSub, 1);
    });
    test('variations out of range', () {
      expect(
        decideLook(s, const LookSpec(creditCost: 2, variations: 5), t0).reason,
        DenyReason.badRequest,
      );
    });
  });

  group('apply button label', () {
    test('v11.57: always cost, never Free', () {
      expect(lookApplyLabel(cost: 2, free: true), 'Apply · 🪙2');
      expect(lookApplyLabel(cost: 2, free: false), 'Apply · 🪙2');
      expect(lookIsFree(style: paris, isPro: false, trialAvailable: true), isFalse);
      expect(lookIsFree(style: sherwani, isPro: false, trialAvailable: true), isFalse);
      expect(lookIsFree(style: null, isPro: false, trialAvailable: true), isFalse);
      expect(lookIsFree(style: paris, isPro: true, trialAvailable: true), isFalse);
    });
  });

  group('LookService', () {
    late Directory dir;
    late File photo;
    late DateTime now;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      now = t0;
      AccountService.resetForTest(ledger: LocalLedger(clock: () => now));
      dir = Directory.systemTemp.createTempSync('look');
      final im = img.Image(width: 300, height: 400);
      img.fill(im, color: img.ColorRgb8(200, 100, 50));
      photo = File('${dir.path}/me.jpg')..writeAsBytesSync(img.encodeJpg(im));
    });
    tearDown(() => dir.deleteSync(recursive: true));

    LookService local(MockClient mock) => LookService(
      openRouter: OpenRouterClient(httpClient: mock, apiKey: 'test-key'),
      tempDir: () async => dir,
      localPromptFor: (id) =>
          id == 'paris_eiffel' ? 'Place the person in Paris.' : null,
    );

    test('test-key build: style cost → no charge on failure', () async {
      final payloads = <Map<String, dynamic>>[];
      var fail = false;
      final mock = MockClient((req) async {
        payloads.add(jsonDecode(req.body) as Map<String, dynamic>);
        if (fail) return http.Response('{"error":"down"}', 500);
        return http.Response(
          jsonEncode({
            'data': [
              {'b64_json': pngB64(600, 800)},
            ],
            'usage': {'cost': 0.02},
          }),
          200,
        );
      });
      final svc = local(mock);
      final acct = AccountService.instance;

      var r = await svc.apply(LookJob(image: photo, style: paris));
      expect(r.ok, isTrue);
      expect(r.backend, LookBackend.openRouter);
      expect(r.trialsUsed, isEmpty);
      expect(r.creditsCharged, 2);
      final p = payloads.last;
      // v11.58: styles render on FLUX Klein (photo only, no quality/res).
      expect(p['model'], 'black-forest-labs/flux-3-image-klein');
      expect(p.containsKey('quality'), isFalse);
      expect(p.containsKey('resolution'), isFalse);
      expect(p['input_references'], hasLength(1));
      expect(p['n'], 1);
      expect((p['prompt'] as String).startsWith(kLookIdentityPrompt), isTrue);
      expect(
        p['prompt'],
        contains('Requested look: Place the person in Paris.'),
      );
      expect(p['prompt'], isNot(contains(kLockedEnhancePrompt)));
      expect((await acct.refresh()).freeDaily, 0); // 2 from free daily

      // Out of credits → denied, no AI call.
      final n = payloads.length;
      r = await svc.apply(LookJob(image: photo, style: paris));
      expect(r.denied, DenyReason.noCredits);
      expect(payloads.length, n);

      // Pack credits → charged on success; failure charges nothing.
      await acct.grantPurchase(productById('pack_25')!);
      fail = true;
      r = await svc.apply(LookJob(image: photo, style: paris));
      expect(r.ok, isFalse);
      expect(r.error, isNotNull);
      expect((await acct.refresh()).packCredits, 25);

      fail = false;
      r = await svc.apply(LookJob(image: photo, style: paris));
      expect(r.creditsCharged, 2);
      expect((await acct.refresh()).packCredits, 23);
    });

    test(
      'v11.56: one image only — n=1, a single call, no top-ups',
      () async {
        await AccountService.instance.grantPurchase(productById('pack_25')!);
        final ns = <int>[];
        var calls = 0;
        final mock = MockClient((req) async {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          ns.add(body['n'] as int);
          calls++;
          if (calls > 2) return http.Response('{"error":"down"}', 500);
          return http.Response(
            jsonEncode({
              'data': [
                {'b64_json': pngB64(64, 80)},
              ],
              'usage': {'cost': 0.02},
            }),
            200,
          );
        });
        final r = await local(
          mock,
        ).apply(LookJob(image: photo, style: paris));
        expect(ns, [1]);
        expect(calls, 1);
        expect(r.files.length, 1);
      },
    );

    test(
      'custom change: identity wrapper + tier credits for free users',
      () async {
        final prompts = <String>[];
        final mock = MockClient((req) async {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          prompts.add(body['prompt'] as String);
          expect(body['quality'], 'low'); // HD tier chosen
          return http.Response(
            jsonEncode({
              'data': [
                {'b64_json': pngB64(64, 80)},
              ],
            }),
            200,
          );
        });
        final r = await local(mock).apply(
          LookJob(
            image: photo,
            customPrompt: 'wear a red kurta',
            tier: QualityTier.hd,
          ),
        );
        expect(r.ok, isTrue);
        expect(r.creditsCharged, 1);
        expect(r.trialsUsed, isEmpty);
        expect(prompts.single, contains('Requested change: wear a red kurta'));
        expect(prompts.single.startsWith(kLookIdentityPrompt), isTrue);
      },
    );

    test(
      'server: sends style_id only (no prompt), uses server charge',
      () async {
        SharedPreferences.setMockInitialValues({
          'enhance_server_url': 'http://srv:8787/',
        });
        AccountService.resetForTest(ledger: LocalLedger(clock: () => now));
        final acctBlob = base64Url
            .encode(
              utf8.encode(
                jsonEncode(
                  CreditState.initial(now).copyWith(freeDaily: 0).toJson(),
                ),
              ),
            )
            .replaceAll('=', '');
        String? body;
        final mock = MockClient((req) async {
          if (req.url.path == '/v1/account') {
            return http.Response(
              jsonEncode({'state': CreditState.initial(now).toJson()}),
              200,
            );
          }
          expect(req.url.toString(), 'http://srv:8787/v1/looks/apply');
          body = utf8.decode(req.bodyBytes, allowMalformed: true);
          return http.Response(
            jsonEncode({
              'images': [pngB64(32, 40)],
              'credits_charged': 2,
              'trials_used': <String>[],
              'account': acctBlob,
              'cost': 0.03,
            }),
            200,
          );
        });
        final svc = LookService(
          server: ServerApiClient(httpClient: mock),
          openRouter: OpenRouterClient(httpClient: mock, apiKey: ''),
          tempDir: () async => dir,
        );
        final r = await svc.apply(LookJob(image: photo, style: paris));
        expect(r.backend, LookBackend.server);
        expect(r.creditsCharged, 2);
        expect(r.files, hasLength(1));
        expect(body, contains('name="style_id"'));
        expect(body, contains('paris_eiffel'));
        expect(body, isNot(contains('prompt')));
        expect(AccountService.instance.state.value?.freeDaily, 0);
      },
    );

    test('no server and no key → unavailable, nothing charged', () async {
      final svc = LookService(
        openRouter: OpenRouterClient(apiKey: ''),
        tempDir: () async => dir,
      );
      final r = await svc.apply(LookJob(image: photo, style: paris));
      expect(r.unavailable, isTrue);
      expect(
        (await AccountService.instance.refresh()).trialAvailable(
          StarterTrial.libraryStyle,
        ),
        isTrue,
      );
    });

    test(
      'release-safe: seed prompts not reachable without an embedded key',
      () {
        expect(localSeedStylePrompt('paris_eiffel'), isNull);
      },
    );
  });
}
