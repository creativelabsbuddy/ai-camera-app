import 'dart:io';

import 'package:ai_camera/services/macro.dart';
import 'package:ai_camera/services/mode_prompts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('step photos sent: 1.5x 2x 3x 4x (no 1x photo)', () {
    expect(kMacroContextZooms, [1.5, 2.0, 3.0, 4.0]);
    expect(isMacroContextZoom(1.0), isFalse);
    expect(isMacroContextZoom(1.5), isTrue);
    expect(kMacroDetectZoom, 1.5);
  });

  // 'drift needs a sustained strong change' superseded by v1123_test (new drift metric).
  test('prompts reference the 1.5x photo', () {
    expect(kMacroPrompt, isNot(contains('{subject}'))); // v11.39
    expect(
      kDetectPartPrompt,
      startsWith('Photo 1 is a wider view; main object: {parent};'),
    );
  });

  test(
    'home: no 1x photo/call, drift resets to 1x, no auto re-check',
    () {
      final s = File('lib/screens/home_camera_screen.dart').readAsStringSync();
      expect(s, isNot(contains('_recheckSubject')));
      expect(s, contains('void _onDrift()'));
      expect(s, contains('_applyMacroChip(1.0, drift: true)'));
      expect(s, contains('_resetMacroFlow();'));
      expect(s, contains('chip == kMacroDetectZoom'));
      expect(s, contains('macroFlowGuide('));
      final d = s.substring(
        s.indexOf('void _onDrift()'),
        s.indexOf('Future<void> _takeClearPhoto('),
      );
      expect(d, isNot(contains('_detect'))); // no cloud call from drift
    },
    skip: 'v11.33: replaced by level chips + box check',
  );
}
