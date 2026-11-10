import 'dart:io';

import 'package:ai_camera/services/ai_call.dart';
import 'package:ai_camera/models/capture_mode.dart';
import 'package:ai_camera/screens/preview_screen.dart';
import 'package:ai_camera/services/account_service.dart';
import 'package:ai_camera/services/enhance_service.dart';
import 'package:ai_camera/services/entitlements.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 1x1 transparent PNG so Image.file has something valid to decode.
const _png = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

class FakeEnhance extends EnhanceService {
  FakeEnhance(this.result);
  final EnhanceResult result;
  final jobs = <EnhanceJob>[];

  @override
  Future<EnhanceResult> enhance(EnhanceJob job, {AiCancelToken? cancel}) async {
    jobs.add(job);
    return result;
  }
}

void main() {
  late Directory dir;
  late File photo;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AccountService.resetForTest();
    dir = Directory.systemTemp.createTempSync('ai_cam_test');
    photo = File('${dir.path}/shot.png')..writeAsBytesSync(_png);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets('Normal mode: no AI call, photo as captured, free filters', (
    tester,
  ) async {
    final fake = FakeEnhance(const EnhanceResult());
    await tester.pumpWidget(
      MaterialApp(
        home: PreviewScreen(
          imageFile: photo,
          captureZoom: 30,
          enhanceService: fake,
        ),
      ),
    );
    await tester.pump();
    expect(fake.jobs, isEmpty);
    expect(find.textContaining('Normal'), findsOneWidget);
    await tester.tap(find.text('Filters'));
    await tester.pump();
    expect(find.textContaining('Free filters'), findsOneWidget);
  });

  testWidgets('Pro mode, free user above optical (trial used): Pro-only', (
    tester,
  ) async {
    final fake = FakeEnhance(
      const EnhanceResult(denied: DenyReason.zoomNeedsPro),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PreviewScreen(
          imageFile: photo,
          captureZoom: 30,
          opticalLimit: 5,
          mode: CaptureMode.pro,
          enhanceService: fake,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(fake.jobs.single.zoom, 30);
    expect(fake.jobs.single.opticalLimit, 5);
    expect(find.text('Preview · 30x'), findsOneWidget);
    expect(find.textContaining('Pro only'), findsWidgets);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('starter trial success shows "Liked it? Get Pro ₹99/month"', (
    tester,
  ) async {
    final fake = FakeEnhance(
      EnhanceResult(
        file: photo,
        backend: EnhanceBackend.openRouter,
        trialsUsed: const [StarterTrial.highZoom],
        contextUsed: true,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PreviewScreen(
          imageFile: photo,
          contextFile: photo,
          captureZoom: 20,
          opticalLimit: 5,
          mode: CaptureMode.pro,
          enhanceService: fake,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(fake.jobs.single.context, isNotNull);
    expect(find.textContaining('Starter trial · free'), findsOneWidget);
    expect(find.byKey(const ValueKey('trial_upsell')), findsOneWidget);
  });
}
