import 'package:ai_camera/main.dart';
import 'package:ai_camera/services/account_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AccountService.resetForTest();
  });

  testWidgets('minimal top bar: PRO, coin balance, quality chip', (
    tester,
  ) async {
    await tester.pumpWidget(const AiCameraApp());
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('AI Camera'), findsNothing); // no title
    expect(find.text('PRO'), findsOneWidget);
    expect(find.byKey(const ValueKey('credits_pill')), findsOneWidget);
    expect(find.text('2'), findsOneWidget); // coin + number only
    expect(find.byKey(const ValueKey('quality_chip')), findsOneWidget);
    expect(find.text('HD'), findsOneWidget);
    expect(find.byKey(const ValueKey('mode_normal')), findsOneWidget);
    expect(find.byKey(const ValueKey('mode_pro')), findsOneWidget);
    // Single gallery entry (bottom-left), no top gallery / settings icons.
    expect(find.byKey(const ValueKey('gallery_button')), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsNothing);
    // Clean view: no filter / style strip until opened from the quick menu.
    expect(find.byKey(const ValueKey('active_style_badge')), findsNothing);
    expect(find.byKey(const ValueKey('styles_quick_panel')), findsNothing);
  });

  testWidgets('v11.51: Styles opens the filter row; Vivid selects', (
    tester,
  ) async {
    await tester.pumpWidget(const AiCameraApp());
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const ValueKey('quick_menu_open')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('quick_menu')), findsOneWidget);
    expect(find.byKey(const ValueKey('qm_filters')), findsNothing);
    // v11.54: the four-dot opens the Styles quick row directly.
    expect(find.byKey(const ValueKey('styles_quick_panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('quick_more')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('quick_photo_vivid')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('active_style_badge')), findsOneWidget);
    // Tap again → deselect.
    await tester.tap(find.byKey(const ValueKey('quick_photo_vivid')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('active_style_badge')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('quick_photo_vivid')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('quick_menu_close')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('styles_quick_panel')), findsNothing);
    expect(find.byKey(const ValueKey('active_style_badge')), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets(
    'quick menu Styles → View more works in Normal: library → Take photo',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const AiCameraApp());
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const ValueKey('quick_menu_open')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 100));
      // v11.51: Styles → filter row → View more → full library.
      // v11.56: the quick row scrolls; More is the last card.
      await tester.ensureVisible(find.byKey(const ValueKey('quick_more')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('quick_more')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(const ValueKey('style_library_sheet')), findsOneWidget);
      expect(find.byKey(const ValueKey('styles_tab_photo')), findsOneWidget);
      expect(find.byKey(const ValueKey('style_card_custom')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('photo_card_paris_eiffel')));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const ValueKey('photo_card_paris_eiffel')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // No photo yet → ask for one; nothing is charged by tapping.
      expect(find.text('Take photo'), findsOneWidget);
      expect(find.text('Choose from gallery'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('look_take_photo')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('active_style_badge')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('active_style_badge')),
          matching: find.text('Paris Eiffel'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('quick_menu')), findsNothing);
      expect(find.byKey(const ValueKey('quick_menu_dot')), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    },
  );

  testWidgets('night toggle in the quick menu shows a Night badge', (
    tester,
  ) async {
    await tester.pumpWidget(const AiCameraApp());
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const ValueKey('quick_menu_open')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('qm_night')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('night_badge')), findsOneWidget);
    expect(find.text('Night'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('night_badge')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('night_badge')), findsNothing);
    await tester.pump(const Duration(seconds: 2));
  });
}
