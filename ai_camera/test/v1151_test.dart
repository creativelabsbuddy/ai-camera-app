import 'dart:io';

import 'package:ai_camera/models/ai_style.dart';
import 'package:ai_camera/services/filter_catalog.dart';
import 'package:ai_camera/widgets/filter_carousel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final home = File('lib/screens/home_camera_screen.dart').readAsStringSync();
  final menu = File('lib/widgets/quick_menu_bar.dart').readAsStringSync();

  test('v11.51 version', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('version: 1.11.'));
  });

  test('built-in Vivid filter: general prompt, 2 credits, bundled preview', () {
    expect(kVividFilter.isFilter, isTrue);
    expect(kVividFilter.creditCost, 2);
    expect(kVividFilterPrompt, contains('vivid'));
    expect(kVividFilterPrompt, contains('do not add or remove anything'));
    expect(File(kVividFilter.imageAsset!).existsSync(), isTrue);
    expect(FilterCatalog().promptFor('vivid'), kVividFilterPrompt);
    expect(FilterCatalog().promptFor('nope'), isNull);
  });

  test('DB rows → filters (kind, prompt, image URL, sort order)', () {
    final c = FilterCatalog(mediaBase: 'https://m.example/');
    final l = FilterCatalog.withBuiltins(
      c.parseRows([
        {
          'id': 'warm',
          'name': 'Warm',
          'prompt': 'p2',
          'credit_cost': 3,
          'sort_order': 101,
          'display_image': 'a.jpg',
        },
        {
          'id': 'vivid',
          'name': 'Vivid',
          'prompt': 'p1',
          'credit_cost': 2,
          'sort_order': 100,
        },
      ]),
    );
    expect(l.map((s) => s.id), ['vivid', 'warm']); // next shows after Vivid
    expect(l.every((s) => s.isFilter), isTrue);
    expect(l[1].imageUrl, 'https://m.example/a.jpg');
    expect(l[0].imageAsset, kVividFilter.imageAsset);
    expect(l[1].creditCost, 3);
    expect(l[1].prompt, 'p2');
  });

  test('AiStyle kind defaults to style; round-trips', () {
    expect(AiStyle.fromJson({'id': 'x'}).isFilter, isFalse);
    final f = AiStyle.fromJson({'id': 'y', 'kind': 'filter', 'prompt': 'q'});
    expect(AiStyle.fromJson(f.toJson()).isFilter, isTrue);
    expect(AiStyle.fromJson(f.toJson()).prompt, 'q');
  });

  test('Filters item removed from the four-dot menu; Styles opens the row', () {
    expect(menu, isNot(contains("ValueKey('qm_filters')")));
    expect(home, contains('onStyles: () => _togglePanel(_Panel.filters)'));
    expect(home, isNot(contains('FilterStrip(')));
    expect(File('lib/widgets/filter_strip.dart').existsSync(), isFalse);
    // Filter = pending look → same Styles apply path, credit on success.
    expect(home, contains('PendingLook(style: f, tier: _effTier)'));
    expect(
      File('lib/services/look_service.dart').readAsStringSync(),
      contains('FilterCatalog.instance.promptFor(id)'),
    );
    expect(
      File('lib/services/style_catalog.dart').readAsStringSync(),
      contains('!s.isFilter'),
    );
  });

  testWidgets('carousel: select, highlight, tap again deselects, View more', (
    t,
  ) async {
    AiStyle? got = kVividFilter;
    var more = 0;
    Future<void> pumpWith(String? sel) => t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FilterCarousel(
            filters: const [kVividFilter],
            selectedId: sel,
            onSelect: (f) => got = f,
            onViewMore: () => more++,
          ),
        ),
      ),
    );
    await pumpWith(null);
    expect(find.text('Vivid'), findsOneWidget);
    expect(find.text('2'), findsOneWidget); // credit badge
    await t.tap(find.byKey(const ValueKey('filter_box_vivid')));
    expect(got?.id, 'vivid');
    await pumpWith('vivid');
    await t.tap(find.byKey(const ValueKey('filter_box_vivid')));
    expect(got, isNull);
    await t.tap(find.byKey(const ValueKey('filter_view_more')));
    expect(more, 1);
  });
}
