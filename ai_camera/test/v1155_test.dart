import 'dart:io';

import 'package:ai_camera/models/ai_style.dart';
import 'package:ai_camera/services/account_service.dart';
import 'package:ai_camera/services/local_ledger.dart';
import 'package:ai_camera/widgets/look_sheet.dart';
import 'package:ai_camera/widgets/style_card_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

const germany = AiStyle(
  id: 'germany_street',
  name: 'Germany street',
  category: 'Travel',
  creditCost: 2,
);

void main() {
  late File photo;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final now = DateTime(2026, 11, 4, 12);
    AccountService.resetForTest(ledger: LocalLedger(clock: () => now));
    final dir = Directory.systemTemp.createTempSync('v1155');
    final im = img.Image(width: 1600, height: 1200); // landscape source
    img.fill(im, color: img.ColorRgb8(90, 120, 160));
    photo = File('${dir.path}/me.jpg')..writeAsBytesSync(img.encodeJpg(im));
  });

  test('pair frames are 9:16 and fit the width', () {
    final s = lookPairFrameSize(376, 10000);
    expect(s.width / s.height, closeTo(9 / 16, 1e-9));
    expect(s.width * 2 + 28, closeTo(376, 1e-9));
    final c = lookPairFrameSize(376, 200);
    expect(c.height, 200);
    expect(c.width / c.height, closeTo(9 / 16, 1e-9));
  });

  test('single frame is 9:16 and capped', () {
    final s = lookSingleFrameSize(376, 380);
    expect(s.height, 380);
    expect(s.width / s.height, closeTo(9 / 16, 1e-9));
    final n = lookSingleFrameSize(100, 380);
    expect(n.width, 100);
    expect(n.width / n.height, closeTo(9 / 16, 1e-9));
  });

  test('style card strip cards are 9:16', () {
    final c = StyleCard(style: germany, isPro: false, trialAvailable: true, onTap: null);
    expect(c.width / c.height, closeTo(9 / 16, 0.01));
  });

  Future<void> open(WidgetTester t, {File? p}) async {
    t.view.physicalSize = const Size(412 * 2.625, 915 * 2.625);
    t.view.devicePixelRatio = 2.625;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => showLookSheet(context, style: germany, photo: p),
            child: const Text('go'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('go'));
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> shot(WidgetTester t, String name) async {
    if (Platform.environment['SHOT_DIR'] == null) return;
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('shots/v1155_$name.png'));
  }

  testWidgets('apply sheet: Look and Your photo side by side, 9:16, Apply visible',
      (t) async {
    await open(t, p: photo);
    final a = t.getSize(find.byKey(const ValueKey('look_frame_look')));
    final b = t.getSize(find.byKey(const ValueKey('look_frame_photo')));
    expect(a.width / a.height, closeTo(9 / 16, 1e-6));
    expect(b, a);
    final la = t.getTopLeft(find.byKey(const ValueKey('look_frame_look')));
    final lb = t.getTopLeft(find.byKey(const ValueKey('look_frame_photo')));
    expect(la.dy, lb.dy);
    expect(lb.dx, greaterThan(la.dx));
    final apply = t.getRect(find.byKey(const ValueKey('look_apply')));
    expect(apply.bottom, lessThanOrEqualTo(915));
    expect(find.byKey(const ValueKey('variations_toggle')), findsNothing); // v11.56
    await shot(t, 'apply_sheet');
  });

  testWidgets('photo-source sheet: one 9:16 Look ≤45% height, buttons visible',
      (t) async {
    await open(t);
    final a = t.getSize(find.byKey(const ValueKey('look_frame_look')));
    expect(a.width / a.height, closeTo(9 / 16, 1e-6));
    expect(a.height, lessThanOrEqualTo(915 * 0.45));
    expect(t.getRect(find.byKey(const ValueKey('look_take_photo'))).bottom,
        lessThanOrEqualTo(915));
    expect(t.getRect(find.byKey(const ValueKey('look_pick_gallery'))).bottom,
        lessThanOrEqualTo(915));
    await shot(t, 'photo_source_sheet');
  });
  test('version 1.11.5x', () { expect(File('pubspec.yaml').readAsStringSync(), matches(RegExp(r'version: 1\.11\.(5[5-9]|6\d)\+'))); });
}
