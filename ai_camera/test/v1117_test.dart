import 'dart:io';

import 'package:ai_camera/services/macro.dart';
import 'package:ai_camera/widgets/macro_chips.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<List<double>> _pump(WidgetTester t, int stage, double selected) async {
  final taps = <double>[];
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          // Same construction as HomeCameraScreen's Macro chip row.
          child: MacroChips(
            chips: visibleMacroChips(stage),
            selected: selected,
            onSelected: taps.add,
          ),
        ),
      ),
    ),
  );
  return taps;
}

List<String> _labels(WidgetTester t) => t
    .widgetList<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('macro_chips')),
        matching: find.byType(Text),
      ),
    )
    .map((w) => w.data!)
    .toList();

void main() {
  testWidgets('opens with exactly 1x and 1.5x; tapping 1.5x zooms to 1.5', (
    t,
  ) async {
    final taps = await _pump(t, 0, 1.0);
    expect(_labels(t), ['1x', '1.5x']);
    expect(find.text('2x'), findsNothing);
    await t.tap(find.text('1.5x'));
    expect(taps, [1.5]);
  });

  test(
    'home uses MacroChips; 1.5x advances only on detection success',
    () {
      final s = File('lib/screens/home_camera_screen.dart').readAsStringSync();
      expect(
        s,
        contains(
          'MacroChips(\n              chips: visibleMacroChips(_macroStage),',
        ),
      );
      expect(s, isNot(contains('.round()}x')));
      expect(s, isNot(contains('class _MacroChips')));
      expect(s, contains('chip != kMacroDetectZoom &&'));
      expect(s, contains('if (!fresh) return; // stale'));
      expect(s, contains('if (name != null && _macroActive) {'));
    },
    skip: 'v11.33: replaced by level chips + box check',
  );
}
