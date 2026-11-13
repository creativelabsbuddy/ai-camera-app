import 'dart:async';

import 'package:ai_camera/services/ai_gate.dart';
import 'package:ai_camera/services/network_check.dart';

/// Older preview tests expect the AI to start right away; the v11.52
/// before-AI window is switched on only in test/v1152_test.dart.
/// v11.59: tests never touch the real network — a fake "online" probe by
/// default (offline tests inject their own [NetworkCheck]).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  AiGate.enabled = false;
  NetworkCheck.instance = NetworkCheck(probes: [(_) async => true]);
  await testMain();
}
