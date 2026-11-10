import 'dart:async';

import 'package:ai_camera/services/ai_gate.dart';

/// Older preview tests expect the AI to start right away; the v11.52
/// before-AI window is switched on only in test/v1152_test.dart.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  AiGate.enabled = false;
  await testMain();
}
