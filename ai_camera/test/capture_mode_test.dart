import 'package:ai_camera/models/capture_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default / unknown persisted value -> Normal', () {
    expect(CaptureMode.fromName(null), CaptureMode.normal);
    expect(CaptureMode.fromName('weird'), CaptureMode.normal);
    expect(CaptureMode.fromName('pro'), CaptureMode.pro);
  });

  test('Normal never auto-enhances; Pro (AI on) always tries', () {
    expect(shouldAutoEnhance(mode: CaptureMode.normal), isFalse);
    expect(shouldAutoEnhance(mode: CaptureMode.pro), isTrue);
  });
}
