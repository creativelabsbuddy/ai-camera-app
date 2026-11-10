import 'dart:io';

import 'package:ai_camera/models/shoot_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final home = File('lib/screens/home_camera_screen.dart').readAsStringSync();

  test('v11.50 version', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('version: 1.11.'));
  });

  test('menu visible in Pro Photo/Night/Portrait, hidden in Pro Macro, '
      'visible in Normal', () {
    for (final m in [ShootMode.photo, ShootMode.night, ShootMode.portrait]) {
      expect(quickMenuVisible(aiMode: true, mode: m), isTrue, reason: '$m');
      expect(quickMenuVisible(aiMode: false, mode: m), isTrue, reason: '$m');
    }
    expect(quickMenuVisible(aiMode: true, mode: ShootMode.macro), isFalse);
  });

  test('Pro non-Macro: timer, filters, AI filters and Styles used again', () {
    expect(
      home,
      contains(
        'aiFilter: _mode == CaptureMode.pro && !_macroActive ? _aiFilter : null',
      ),
    );
    expect(home, contains('pending: _macroActive ? null : _pendingLook'));
    expect(home, contains('_macroActive || // v11.50: no timer in Macro'));
    expect(home, isNot(contains("'qm_flash'")));
  });
}
