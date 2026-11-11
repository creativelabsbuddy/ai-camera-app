import 'dart:io';
import 'dart:typed_data';

import 'package:ai_camera/models/ai_style.dart';
import 'package:ai_camera/services/account_service.dart';
import 'package:ai_camera/services/entitlements.dart';
import 'package:ai_camera/services/video_service.dart';
import 'package:ai_camera/widgets/credit_icon.dart';
import 'package:ai_camera/widgets/look_sheet.dart';
import 'package:ai_camera/widgets/style_card_strip.dart';
import 'package:ai_camera/widgets/style_library_sheet.dart';
import 'package:ai_camera/widgets/video_style_flow.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal 1x1 PNG.
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

const paris = AiStyle(
  id: 'paris_eiffel',
  name: 'Paris Eiffel',
  category: 'Travel',
  creditCost: 2,
);

const slowZoom = AiStyle(
  id: 'video_slow_zoom',
  name: 'Slow zoom',
  category: 'Zoom',
  creditCost: 0,
);

Future<void> _settle(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AccountService.resetForTest();
  });

  test('version (v11.60: 1.11.60+73)', () {
    expect(File('pubspec.yaml').readAsStringSync(),
        contains('version: 1.11.60+73'));
  });

  group('no Free labels / no free-first style', () {
    test('lookIsFree always false; Apply label always shows cost', () {
      expect(lookIsFree(style: paris, isPro: false, trialAvailable: true),
          isFalse);
      expect(lookApplyLabel(cost: 2, free: true), 'Apply · ${kCreditGlyph}2');
      expect(lookApplyLabel(cost: 3, free: false), 'Apply · ${kCreditGlyph}3');
    });

    test('decideLook never grants library_style trial', () {
      final t0 = DateTime.utc(2026, 11, 6, 10);
      final s = CreditState.initial(t0);
      final d = decideLook(s, const LookSpec(creditCost: 2), t0);
      expect(d.allowed, isTrue);
      expect(d.trials, isEmpty);
      expect(d.fromFree, 2);
      expect(d.credits, 2);
    });

    testWidgets('CoinBadge never shows Free even when trial available',
        (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CoinBadge(cost: 2, free: true),
        ),
      ));
      expect(find.text('Free'), findsNothing);
      expect(find.text('2'), findsOneWidget);
      expect(find.byKey(const ValueKey('credit_icon')), findsOneWidget);
    });

    testWidgets('look sheet Apply shows credit cost, never Free', (t) async {
      t.view.physicalSize = const Size(1080, 2340);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final dir = Directory.systemTemp.createTempSync('v1157');
      addTearDown(() => dir.deleteSync(recursive: true));
      final photo = File('${dir.path}/me.png')..writeAsBytesSync(_png);
      await AccountService.instance.refresh();
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  showLookSheet(context, style: paris, photo: photo),
              child: const Text('go'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('go'));
      await _settle(t);
      expect(find.text('Free'), findsNothing);
      expect(find.text('Apply · Free'), findsNothing);
      expect(
        find.byWidgetPredicate(
            (w) => w is CreditText && w.text == 'Apply · ${kCreditGlyph}2'),
        findsOneWidget,
      );
      expect(find.textContaining('first style is free'), findsNothing);
      expect(find.textContaining('first one free'), findsNothing);
    });

    testWidgets('Styles library never says first style is free', (t) async {
      t.view.physicalSize = const Size(1080, 2340);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await AccountService.instance.refresh();
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showStyleLibrarySheet(context),
              child: const Text('go'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('go'));
      await _settle(t);
      expect(find.textContaining('first style is free'), findsNothing);
      expect(find.text('Free'), findsNothing);
      expect(
        find.text('Pick a look · credits are used only when it is ready'),
        findsOneWidget,
      );
    });
  });

  group('video cards: image-to-video confirm, no source sheet', () {
    test('Generate label uses bolt glyph', () {
      expect(makeVideoLabel(4), 'Generate · ${kCreditGlyph}4');
      expect(makeVideoLabel(4), isNot(contains('Make video')));
    });

    testWidgets(
        'confirm sheet: 9:16 preview, 480/580/720 chips, Generate button',
        (t) async {
      t.view.physicalSize = const Size(1080, 2340);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final dir = Directory.systemTemp.createTempSync('v1157v');
      addTearDown(() => dir.deleteSync(recursive: true));
      final photo = File('${dir.path}/shot.png')..writeAsBytesSync(_png);
      String? chosen;
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                chosen = await showVideoConfirmSheet(
                  context,
                  style: slowZoom,
                  photo: photo,
                  svc: VideoService(),
                );
              },
              child: const Text('go'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('go'));
      await _settle(t);
      expect(find.byKey(const ValueKey('video_confirm_sheet')), findsOneWidget);
      expect(find.byKey(const ValueKey('video_confirm_preview')), findsOneWidget);
      expect(find.byKey(const ValueKey('video_source_sheet')), findsNothing);
      expect(find.text('Take photo'), findsNothing);
      expect(find.text('Choose from gallery'), findsNothing);
      expect(find.text('Take video'), findsNothing);
      expect(find.byKey(const ValueKey('preset_res_480p')), findsOneWidget);
      expect(find.byKey(const ValueKey('preset_res_580p')), findsOneWidget);
      expect(find.byKey(const ValueKey('preset_res_720p')), findsOneWidget);
      // Default 480p selected.
      final chip480 =
          t.widget<ChoiceChip>(find.byKey(const ValueKey('preset_res_480p')));
      expect(chip480.selected, isTrue);
      expect(
        find.byWidgetPredicate(
            (w) => w is CreditText && w.text.startsWith('Generate · ')),
        findsOneWidget,
      );
      await t.tap(find.byKey(const ValueKey('preset_go')));
      await _settle(t);
      expect(chosen, '480p');
    });
  });
}
