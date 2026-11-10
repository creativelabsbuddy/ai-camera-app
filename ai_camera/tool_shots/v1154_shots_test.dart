// ignore_for_file: invalid_use_of_visible_for_testing_member
// Renders v11.54 screens to PNG (not part of the test suite):
// flutter test tool_shots/v1154_shots_test.dart --update-goldens
import 'dart:io';

import 'package:ai_camera/main.dart';
import 'package:ai_camera/services/account_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _fonts = '/home/box/devtools/flutter/bin/cache/artifacts/material_fonts';

Future<void> _load(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    l.addFont(Future.value(ByteData.view(File('$_fonts/$f').readAsBytesSync().buffer)));
  }
  await l.load();
}

Future<void> _settle(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _precache(WidgetTester t) async {
  await t.runAsync(() async {
    for (final e in find.byType(Image).evaluate()) {
      final w = e.widget as Image;
      await precacheImage(w.image, e);
    }
  });
  await t.pump();
}

void main() {
  setUpAll(() async {
    await _load('Roboto', ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf', 'Roboto-Black.ttf']);
    await _load('MaterialIcons', ['MaterialIcons-Regular.otf']);
  });

  testWidgets('shots', (t) async {
    SharedPreferences.setMockInitialValues({});
    AccountService.resetForTest();
    t.view.physicalSize = const Size(1080, 2340);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(const AiCameraApp());
    await _settle(t, 5);
    await _precache(t);
    await expectLater(find.byType(AiCameraApp), matchesGoldenFile('out/1_camera_tooltip.png'));
    await t.tap(find.byKey(const ValueKey('quick_menu_open')));
    await _settle(t, 5);
    await _precache(t);
    await _settle(t, 2);
    await expectLater(find.byType(AiCameraApp), matchesGoldenFile('out/2_quick_panel.png'));
    // v11.56: the quick row scrolls; More is the last card.
    await t.ensureVisible(find.byKey(const ValueKey('quick_more')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('quick_more')));
    await _settle(t, 8);
    await _precache(t);
    await _settle(t, 2);
    await expectLater(find.byType(AiCameraApp), matchesGoldenFile('out/3_styles_photo.png'));
    await t.tap(find.byKey(const ValueKey('styles_tab_video')));
    await _settle(t, 4);
    await _precache(t);
    await _settle(t, 2);
    await expectLater(find.byType(AiCameraApp), matchesGoldenFile('out/4_styles_video.png'));
    await t.tap(find.byKey(const ValueKey('video_card_video_slow_zoom')));
    await _settle(t, 6);
    await expectLater(find.byType(AiCameraApp), matchesGoldenFile('out/5_video_photo_source.png'));
    await t.pump(const Duration(seconds: 3));
  });
}
