import 'package:ai_camera/main.dart';
import 'package:ai_camera/services/account_service.dart';
import 'package:ai_camera/services/document_scan.dart';
import 'package:ai_camera/services/native_camera.dart';
import 'package:ai_camera/widgets/pose_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AccountService.resetForTest();
    BokehBridge.resetForTest();
  });
  tearDown(DocumentScan.reset);

  /// v11 carousel keeps the selected mode centred, so neighbours can start
  /// off-screen — scroll them into view before tapping.
  Future<void> tapMode(WidgetTester t, String key) async {
    final f = find.byKey(ValueKey(key));
    await t.scrollUntilVisible(
      f,
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await t.pump(const Duration(milliseconds: 200));
    await t.tap(f);
    await t.pump(const Duration(milliseconds: 400));
  }

  // The camera hand-over spinner never settles → fixed pumps.
  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> open(WidgetTester t) async {
    // Phone-sized portrait surface (default 800×600 squeezes the viewfinder).
    t.view.physicalSize = const Size(1080, 2340);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(const AiCameraApp());
    await t.pump(const Duration(milliseconds: 200));
  }

  testWidgets('mode strip sits above the shutter; NORMAL/PRO AI kept', (
    t,
  ) async {
    await open(t);
    // 360 dp phone: PHOTO + neighbours visible, PHOTO centred on shutter.
    for (final k in ['shoot_photo', 'shoot_portrait', 'shoot_pose']) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    // v11.48: no Macro in Normal.
    expect(find.byKey(const ValueKey('shoot_macro')), findsNothing);
    final photoX = t.getCenter(find.byKey(const ValueKey('shoot_photo'))).dx;
    final shutterX = t.getCenter(find.byKey(const ValueKey('shutter'))).dx;
    expect((photoX - shutterX).abs(), lessThan(1.0));
    expect(find.byKey(const ValueKey('mode_normal')), findsOneWidget);
    expect(find.byKey(const ValueKey('mode_pro')), findsOneWidget);
    final strip = t.getCenter(find.byKey(const ValueKey('shoot_photo')));
    final tabs = t.getCenter(find.byKey(const ValueKey('mode_normal')));
    expect(strip.dy, lessThan(tabs.dy));
  });

  testWidgets('NIGHT mode = existing night pipeline (badge), PHOTO clears', (
    t,
  ) async {
    await open(t);
    await tapMode(t, 'shoot_night');
    expect(find.byKey(const ValueKey('night_badge')), findsOneWidget);
    await tapMode(t, 'shoot_photo');
    expect(find.byKey(const ValueKey('night_badge')), findsNothing);
    await t.pump(const Duration(seconds: 2));
  });

  testWidgets('DOCUMENT launches the scanner → result sheet', (t) async {
    var calls = 0;
    DocumentScan.scanner = () async {
      calls++;
      return const ScannedDocument(
        pages: ['/tmp/a.jpg'],
        pdfPath: '/docs/Scans/Scan_x.pdf',
        pageCount: 1,
      );
    };
    await open(t);
    await tapMode(t, 'shoot_document');
    await settle(t);
    expect(calls, 1);
    expect(find.text('Scanned 1 page'), findsOneWidget);
    expect(find.byKey(const ValueKey('doc_share_pdf')), findsOneWidget);
  });

  testWidgets('DOCUMENT: cancelled scan shows nothing', (t) async {
    DocumentScan.scanner = () async =>
        const ScannedDocument(pages: [], pdfPath: null, pageCount: 0);
    await open(t);
    await tapMode(t, 'shoot_document');
    await settle(t);
    expect(find.byKey(const ValueKey('doc_title')), findsNothing);
  });

  testWidgets('POSE: photo cards, no outline / auto-capture', (t) async {
    await open(t);
    await tapMode(t, 'shoot_pose');
    expect(find.byKey(const ValueKey('pose_cat_Standing')), findsOneWidget);
    expect(find.byKey(const ValueKey('pose_auto')), findsNothing);
    // Real bundled photo cards (30 Pexels photos).
    expect(
      find.byKey(const ValueKey('pose_local_standing_17514227')),
      findsOneWidget,
    );
    t.widget<PoseStrip>(find.byType(PoseStrip)).onCategory('Selfie');
    await t.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('pose_local_selfie_27177182')),
      findsOneWidget,
    );
    // Back to Photo hides the pose strip.
    await tapMode(t, 'shoot_photo');
    expect(find.byKey(const ValueKey('pose_cat_Standing')), findsNothing);
    await t.pump(const Duration(seconds: 2));
  });

  testWidgets('MORE toggles persist across restarts', (t) async {
    await open(t);
    // v11: all modes live in the carousel, so the MORE item is off the
    // right edge of the phone viewport — scroll it into view first.
    await t.scrollUntilVisible(
      find.byKey(const ValueKey('shoot_more')),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const ValueKey('shoot_more')));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('feat_smile')));
    await t.pump(const Duration(milliseconds: 200));
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('camera_features_v10'),
      contains('"smile_shot":true'),
    );
  });
}
