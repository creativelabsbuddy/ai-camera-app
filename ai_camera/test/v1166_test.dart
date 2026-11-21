// v11.66 (1.11.66+79) tests: one group per agreed change.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_camera/widgets/ai_working_frame.dart';

void main() {
  group('2: blur note in the waves', () {
    testWidgets('note sits centred over the waves while active', (t) async {
      await t.pumpWidget(
        const MaterialApp(
          home: SizedBox(
            width: 400,
            height: 600,
            child: AiWorkingFrame(
              active: true,
              label: 'AI',
              note: kAiBlurNote,
              child: ColoredBox(color: Colors.grey),
            ),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 500));
      expect(find.text(kAiBlurNote), findsOneWidget);
      expect(
        kAiBlurNote,
        'AI may change faces and details if the photo is too blurry. '
        'For best results, wipe the lens and add more light.',
      );
      final c = t.getCenter(find.byKey(const ValueKey('ai_blur_note')));
      final f = t.getCenter(find.byType(AiWorkingFrame));
      expect((c.dx - f.dx).abs(), lessThan(2));
      expect((c.dy - f.dy).abs(), lessThan(2));
      await t.pumpWidget(const SizedBox());
    });

    test('wired into enhance and style screens', () {
      for (final f in [
        'lib/screens/preview_screen.dart',
        'lib/screens/look_screen.dart',
      ]) {
        expect(File(f).readAsStringSync(), contains('note: kAiBlurNote'));
      }
    });
  });
}
