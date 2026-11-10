import 'dart:convert';
import 'dart:io';

import 'package:ai_camera/models/capture_mode.dart';
import 'package:ai_camera/models/quality_tier.dart';
import 'package:ai_camera/screens/preview_screen.dart';
import 'package:ai_camera/services/account_service.dart';
import 'package:ai_camera/services/ai_call.dart';
import 'package:ai_camera/services/enhance_policy.dart';
import 'package:ai_camera/services/enhance_service.dart';
import 'package:ai_camera/services/look_service.dart';
import 'package:ai_camera/services/openrouter_client.dart';
import 'package:ai_camera/services/server_api_client.dart';
import 'package:ai_camera/services/vision.dart';
import 'package:ai_camera/widgets/look_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

class FakeEnhance extends EnhanceService {
  final jobs = <EnhanceJob>[];

  @override
  Future<EnhanceResult> enhance(EnhanceJob job, {AiCancelToken? cancel}) async {
    jobs.add(job);
    return const EnhanceResult();
  }
}

void main() {
  group('previewActionsFor (enhance only at capture time)', () {
    test('PRO AI capture: auto-enhance + AI filters, no tip', () {
      final a = previewActionsFor(PhotoSource.proCapture);
      expect(a.autoEnhance, isTrue);
      expect(a.aiFilters, isTrue);
      expect(a.captureTip, isFalse);
    });
    test('Normal capture: no enhance, no AI filters, tip shown', () {
      final a = previewActionsFor(PhotoSource.normalCapture);
      expect(a.autoEnhance, isFalse);
      expect(a.aiFilters, isFalse);
      expect(a.captureTip, isTrue);
      expect(a.styles && a.customDescribe, isTrue);
    });
    test('Gallery: only creative Styles + custom describe', () {
      final a = previewActionsFor(PhotoSource.gallery);
      expect(a.autoEnhance, isFalse);
      expect(a.aiFilters, isFalse);
      expect(a.captureTip, isFalse);
      expect(a.styles, isTrue);
      expect(a.customDescribe, isTrue);
    });
    test('tip text', () {
      expect(kProCaptureTip, 'Shoot in Pro AI for sharper, clearer photos');
      expect(kEnhanceOnlyTip, contains('No credits used'));
    });
  });

  group('isEnhanceOnlyPrompt', () {
    const yes = [
      'enhance',
      'Enhance it',
      'make it HD',
      'HD please',
      'make it clear',
      'sharp',
      'Make the photo sharper and clearer',
      'full hd',
      '4K',
      'upscale to 4k',
      'high resolution',
      'improve quality',
      'remove blur, more detail',
      'fix blurry photo',
    ];
    const no = [
      '',
      '   ',
      'brighter', // no core word → a (cheap) creative change
      'make it HD with a beach background',
      'sharp black suit',
      'convert to anime',
      'add sunglasses',
      'clear sky sunset',
      'make me look like a superhero, HD',
    ];
    for (final t in yes) {
      test('"$t" → enhance-only', () => expect(isEnhanceOnlyPrompt(t), isTrue));
    }
    for (final t in no) {
      test('"$t" → real edit', () => expect(isEnhanceOnlyPrompt(t), isFalse));
    }
  });

  test('failure kind + message + wire mapping', () {
    expect(aiFailureMessage(AiFailureKind.enhanceOnly), kEnhanceOnlyTip);
    expect(failureKindFromWire('enhance_only'), AiFailureKind.enhanceOnly);
  });

  group('LookService: enhance-only custom → tip, no AI call, no charge', () {
    late Directory dir;
    late File photo;
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AccountService.resetForTest();
      dir = Directory.systemTemp.createTempSync('v10_look');
      final im = img.Image(width: 200, height: 260);
      img.fill(im, color: img.ColorRgb8(120, 90, 60));
      photo = File('${dir.path}/me.jpg')..writeAsBytesSync(img.encodeJpg(im));
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('no network, credits unchanged', () async {
      final calls = <http.Request>[];
      final mock = MockClient((req) async {
        calls.add(req);
        return http.Response(
          jsonEncode({'error': 'should not be called'}),
          500,
        );
      });
      final svc = LookService(
        server: ServerApiClient(httpClient: mock),
        openRouter: OpenRouterClient(httpClient: mock, apiKey: 'test-key'),
        tempDir: () async => dir,
      );
      final before = (await AccountService.instance.refresh()).toJson();
      final r = await svc.apply(
        LookJob(image: photo, customPrompt: 'Make it HD and sharper'),
      );
      expect(r.ok, isFalse);
      expect(r.failure, AiFailureKind.enhanceOnly);
      expect(r.creditsCharged, 0);
      expect(calls, isEmpty);
      expect((await AccountService.instance.refresh()).toJson(), before);
    });
  });

  group('UI', () {
    late Directory dir;
    late File photo;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AccountService.resetForTest();
      StillVision.reset();
      dir = Directory.systemTemp.createTempSync('v10_ui');
      final im = img.Image(width: 60, height: 80);
      img.fill(im, color: img.ColorRgb8(90, 140, 200));
      photo = File('${dir.path}/shot.png')..writeAsBytesSync(img.encodePng(im));
    });
    tearDown(() {
      StillVision.reset();
      dir.deleteSync(recursive: true);
    });

    Future<void> pumpPreview(
      WidgetTester tester, {
      required FakeEnhance fake,
      CaptureMode mode = CaptureMode.normal,
      PhotoSource? source,
      String? captureNote,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: PreviewScreen(
            imageFile: photo,
            mode: mode,
            tier: QualityTier.hd,
            source: source,
            captureNote: captureNote,
            enhanceService: fake,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('Normal capture: tip, no enhance, no AI filters', (t) async {
      final fake = FakeEnhance();
      await pumpPreview(t, fake: fake);
      expect(fake.jobs, isEmpty);
      expect(find.byKey(const ValueKey('pro_capture_tip')), findsOneWidget);
      expect(find.text(kProCaptureTip), findsOneWidget);
      await t.tap(find.text('Filters'));
      await t.pump();
      expect(find.text('Free filters (no AI)'), findsOneWidget);
      expect(find.textContaining('AI filters'), findsNothing);
    });

    testWidgets('Gallery photo in PRO mode: NO auto-enhance, no AI filters', (
      t,
    ) async {
      final fake = FakeEnhance();
      await pumpPreview(
        t,
        fake: fake,
        mode: CaptureMode.pro,
        source: PhotoSource.gallery,
      );
      expect(fake.jobs, isEmpty);
      expect(find.textContaining('Gallery photo'), findsOneWidget);
      expect(find.byKey(const ValueKey('pro_capture_tip')), findsNothing);
      await t.tap(find.text('Filters'));
      await t.pump();
      expect(find.textContaining('AI filters'), findsNothing);
      // Creative styles are still offered.
      expect(find.textContaining('Styles'), findsWidgets);
    });

    testWidgets('PRO capture still auto-enhances (unchanged)', (t) async {
      final fake = FakeEnhance();
      await pumpPreview(t, fake: fake, mode: CaptureMode.pro);
      await t.pump(const Duration(milliseconds: 100));
      expect(fake.jobs, hasLength(1));
      expect(find.byKey(const ValueKey('pro_capture_tip')), findsNothing);
    });

    testWidgets('free capture note shows in the status line', (t) async {
      await pumpPreview(
        t,
        fake: FakeEnhance(),
        captureNote: 'HDR · 3 exposures merged',
      );
      expect(find.textContaining('HDR · 3 exposures merged'), findsOneWidget);
    });

    testWidgets('Copy text: on-device OCR → sheet → clipboard', (t) async {
      String? copied;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      StillVision.textReader = (_) async => 'Chai 20\nSamosa 15';
      await pumpPreview(t, fake: FakeEnhance());
      await t.tap(find.byKey(const ValueKey('copy_text')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('recognized_text')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('copy_text_button')));
      await t.pumpAndSettle();
      expect(copied, 'Chai 20\nSamosa 15');
      expect(find.text('Text copied'), findsOneWidget);
    });

    testWidgets('Copy text: nothing found → snack', (t) async {
      StillVision.textReader = (_) async => null;
      await pumpPreview(t, fake: FakeEnhance());
      await t.tap(find.byKey(const ValueKey('copy_text')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('No text found in this photo'), findsOneWidget);
    });

    testWidgets('Edit button opens the free editor', (t) async {
      await pumpPreview(t, fake: FakeEnhance());
      await t.tap(find.byKey(const ValueKey('edit_photo')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('edit_save')), findsOneWidget);
    });

    testWidgets('look sheet: "make it HD" → tip, Apply disabled', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showLookSheet(context, photo: photo),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('go'));
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      final field = find.byKey(const ValueKey('custom_prompt_field'));
      await t.enterText(field, 'make it HD and sharp');
      await t.pump();
      expect(find.text(kEnhanceOnlyTip), findsOneWidget);
      var apply = t.widget<FilledButton>(
        find.byKey(const ValueKey('look_apply')),
      );
      expect(apply.onPressed, isNull);
      await t.enterText(field, 'add a red saree, HD');
      await t.pump();
      expect(find.text(kEnhanceOnlyTip), findsNothing);
      apply = t.widget<FilledButton>(find.byKey(const ValueKey('look_apply')));
      expect(apply.onPressed, isNotNull);
    });
  });
}
