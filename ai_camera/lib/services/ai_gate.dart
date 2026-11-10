import 'package:shared_preferences/shared_preferences.dart';

import 'zoom_range.dart' show formatZoom;

/// v11.52 "cancel before AI" window: after capture (and after any Night /
/// multi-frame hold), the photo is shown for [kAiGateSeconds] with a
/// Cancel button before the AI request is sent. With "Ask before
/// enhancing" ON, a Cross / Tick choice replaces the auto countdown.
const int kAiGateSeconds = 3;

/// Settings key (default OFF → 3-second auto countdown).
const String kAskBeforeEnhanceKey = 'ask_before_enhance_v1152';

enum AiGateChoice { start, cancel }

class AiGate {
  /// Test hooks.
  static Duration duration = const Duration(seconds: kAiGateSeconds);
  static bool enabled = true;

  static Future<bool> askBeforeEnhancing() async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getBool(kAskBeforeEnhanceKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setAskBeforeEnhancing(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kAskBeforeEnhanceKey, v);
  }
}

/// "Zoom 40x · AI enhance", "Macro · AI", "Night · AI", "Portrait · AI".
String aiGateLabel({
  required double zoom,
  required bool night,
  String? aiMode,
  String? macroLabel,
  String? filterLabel,
}) {
  if (night) return 'Night · AI';
  if (aiMode == 'macro') return '${macroLabel ?? 'Macro'} · AI';
  final what = filterLabel != null ? 'AI · $filterLabel' : 'AI enhance';
  if (aiMode == 'portrait') return 'Portrait · $what';
  if (zoom > 1.01) return 'Zoom ${formatZoom(zoom)}x · $what';
  return 'Photo · $what';
}
