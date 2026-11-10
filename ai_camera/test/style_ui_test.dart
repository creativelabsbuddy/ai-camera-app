import 'dart:convert';
import 'dart:io';

import 'package:ai_camera/services/ai_call.dart';
import 'package:ai_camera/models/ai_style.dart';
import 'package:ai_camera/screens/look_screen.dart';
import 'package:ai_camera/services/account_service.dart';
import 'package:ai_camera/services/look_service.dart';
import 'package:ai_camera/services/style_catalog.dart';
import 'package:ai_camera/widgets/look_sheet.dart';
import 'package:ai_camera/widgets/credit_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _png = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

final _seedJson = File('assets/styles/seed_styles.json').readAsStringSync();

class FakeLookService extends LookService {
  FakeLookService(this.result);
  LookResult result;
  final jobs = <LookJob>[];

  @override
  Future<LookResult> apply(LookJob job, {AiCancelToken? cancel}) async {
    jobs.add(job);
    return result;
  }
}

void main() {
  late Directory dir;
  late File photo;
  late File out;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AccountService.resetForTest();
    dir = Directory.systemTemp.createTempSync('style_ui');
    photo = File('${dir.path}/me.png')..writeAsBytesSync(_png);
    out = File('${dir.path}/out.png')..writeAsBytesSync(_png);
    StyleCatalog.resetForTest(
      StyleCatalog(
        serverUrl: () async => '',
        loadAsset: (_) async => _seedJson,
        cacheDir: () async => dir,
      ),
    );
  });
  tearDown(() {
    LookFlowDeps.reset();
    dir.deleteSync(recursive: true);
  });

  group('StyleCatalog', () {
    test('bundled seed list (no prompts) when no server', () async {
      final c = StyleCatalog.instance;
      await c.ensureLoaded();
      expect(c.source, 'seed');
      expect(c.styles.value, hasLength(12));
      expect(c.styles.value.first.id, 'germany_street');
      expect(
        c.styles.value.first.imageAsset,
        'assets/styles/samples/germany_street.jpg',
      );
      expect(_seedJson.contains('"prompt"'), isFalse);
      expect(c.byId('royal_sherwani')!.proOnly, isTrue);
    });

    test(
      'server list: absolute image URLs, cached, seed sample as placeholder',
      () async {
        final mock = MockClient((req) async {
          expect(req.url.toString(), 'https://cam.example.com/v1/styles');
          return http.Response(
            jsonEncode({
              'version': 'abc',
              'styles': [
                {
                  'id': 'goa_beach',
                  'name': 'Goa beach',
                  'category': 'Travel',
                  'credit_cost': 3,
                  'pro_only': false,
                  'sort_order': 1,
                  'image_url': '/media/styles/x.jpg',
                  'has_reference': true,
                },
                {
                  'id': 'paris_eiffel',
                  'name': 'Paris',
                  'category': 'Travel',
                  'credit_cost': 2,
                  'sort_order': 0,
                  'image_url': '/media/styles/p.jpg',
                },
              ],
            }),
            200,
          );
        });
        final c = StyleCatalog(
          httpClient: mock,
          serverUrl: () async => 'https://cam.example.com/',
          loadAsset: (_) async => _seedJson,
          cacheDir: () async => dir,
        );
        await c.ensureLoaded();
        expect(c.source, 'server');
        expect(c.styles.value.map((s) => s.id), ['paris_eiffel', 'goa_beach']);
        expect(
          c.styles.value.last.imageUrl,
          'https://cam.example.com/media/styles/x.jpg',
        );
        expect(c.styles.value.last.creditCost, 3);
        expect(
          c.styles.value.first.imageAsset,
          'assets/styles/samples/paris_eiffel.jpg',
        );

        // Offline next launch → cached server list.
        final offline = StyleCatalog(
          httpClient: MockClient((_) async => http.Response('down', 503)),
          serverUrl: () async => 'https://cam.example.com',
          loadAsset: (_) async => _seedJson,
          cacheDir: () async => dir,
        );
        await offline.ensureLoaded();
        expect(offline.source, 'cache');
        expect(offline.styles.value.map((s) => s.id), [
          'paris_eiffel',
          'goa_beach',
        ]);
        expect(offline.lastError, isNotNull);
      },
    );
  });

  testWidgets('style without photo → Choose from gallery → apply → result', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await AccountService.instance.refresh();
    final paris = (await _seed()).firstWhere((s) => s.id == 'paris_eiffel');

    var picked = 0;
    LookFlowDeps.galleryPicker = () async {
      picked++;
      return photo;
    };
    final fake = FakeLookService(
      LookResult(
        files: [out],
        backend: LookBackend.server,
        creditsCharged: 2,
      ),
    );
    LookFlowDeps.service = () => fake;
    final saved = <String>[];
    LookFlowDeps.saver = (f) async {
      saved.add(f.path);
      return 'Saved';
    };
    LookSheetResult? took;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const ValueKey('open'),
                onPressed: () => startLookWithoutPhoto(
                  context,
                  style: paris,
                  onTakePhoto: (r) => took = r,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    expect(find.text('Paris Eiffel'), findsOneWidget);
    expect(find.byKey(const ValueKey('look_take_photo')), findsOneWidget);
    expect(find.byKey(const ValueKey('look_pick_gallery')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('look_apply')),
      findsNothing,
    ); // no photo yet

    await tester.tap(find.byKey(const ValueKey('look_pick_gallery')));
    await tester.pumpAndSettle();
    expect(picked, 1);
    // Second sheet: sample on top, the picked photo below, always paid.
    expect(find.text('Your photo'), findsOneWidget);
    expect(find.text('Apply · Free'), findsNothing);
    expect(find.text('Free'), findsNothing);
    expect(
      find.byWidgetPredicate((w) => w is CreditText && w.text == 'Apply · 🪙2'),
      findsOneWidget,
    );
    expect(fake.jobs, isEmpty); // no deduction / AI on tap

    // v11.56: no "4 variations" option.
    expect(find.byKey(const ValueKey('variations_toggle')), findsNothing);
    expect(find.text('4 variations'), findsNothing);

    await tester.ensureVisible(find.byKey(const ValueKey('look_apply')));
    await tester.tap(find.byKey(const ValueKey('look_apply')));
    await tester.pumpAndSettle();
    expect(fake.jobs, hasLength(1));
    expect(fake.jobs.single.image.path, photo.path);
    expect(fake.jobs.single.style!.id, 'paris_eiffel');
    expect(find.byKey(const ValueKey('compare_slider')), findsOneWidget);
    expect(find.textContaining('Starter trial · free'), findsNothing);
    expect(
      find.byWidgetPredicate((w) => w is CreditText && w.text.contains('🪙2 used')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('look_save')));
    await tester.pumpAndSettle();
    expect(saved, [out.path]); // the AI result, original untouched
    expect(photo.existsSync(), isTrue);
    expect(took, isNull);
  });

  testWidgets('Take photo → pending look returned to the camera', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    LookSheetResult? took;
    final s = (await _seed()).first;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              key: const ValueKey('open'),
              onPressed: () => startLookWithoutPhoto(
                context,
                style: s,
                onTakePhoto: (r) => took = r,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('look_take_photo')));
    await tester.pumpAndSettle();
    expect(took?.action, LookSheetAction.takePhoto);
  });

  testWidgets('look screen: failure shows no-charge message; Retry re-runs', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final fake = FakeLookService(const LookResult(error: 'upstream 500'));
    LookFlowDeps.service = () => fake;
    final s = (await _seed()).first;
    await tester.pumpWidget(
      MaterialApp(
        home: LookScreen(
          original: photo,
          job: LookJob(image: photo, style: s),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Could not apply — no credits used. Tap Retry.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('compare_slider')), findsNothing);
    fake.result = LookResult(files: [out, out, out, out], creditsCharged: 8);
    await tester.tap(find.byKey(const ValueKey('look_retry')));
    await tester.pumpAndSettle();
    expect(fake.jobs, hasLength(2));
    expect(find.byKey(const ValueKey('compare_slider')), findsOneWidget);
    expect(find.byKey(const ValueKey('variation_3')), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is CreditText && w.text.contains('🪙8 used')), findsOneWidget);
    // Try another style → the strip appears.
    await tester.tap(find.byKey(const ValueKey('look_try_another')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('style_card_strip')), findsOneWidget);
    expect(find.byKey(const ValueKey('style_card_custom')), findsOneWidget);
  });
}

Future<List<AiStyle>> _seed() async {
  await StyleCatalog.instance.ensureLoaded();
  return StyleCatalog.instance.styles.value;
}
