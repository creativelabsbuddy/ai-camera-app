import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// Output frame ratios. [portrait] is width / height on an upright phone.
/// 4:3 is the default (full sensor frame, no crop).
enum FrameRatio {
  r4x3('4:3', 3 / 4),
  r16x9('9:16', 9 / 16),
  r1x1('1:1', 1.0);

  const FrameRatio(this.label, this.portrait);

  /// Shown in the quick menu (portrait notation like Samsung: 9:16).
  final String label;
  final double portrait;

  FrameRatio get next => values[(index + 1) % values.length];
}

/// Flash setting from the quick menu. Default off (stock-camera default).
enum FlashChoice {
  off(FlashMode.off, Icons.flash_off_rounded, 'Flash off'),
  auto(FlashMode.auto, Icons.flash_auto_rounded, 'Flash auto'),
  on(FlashMode.always, Icons.flash_on_rounded, 'Flash on');

  const FlashChoice(this.mode, this.icon, this.label);

  final FlashMode mode;
  final IconData icon;
  final String label;

  FlashChoice get next => values[(index + 1) % values.length];

  static const prefsKey = 'flash_choice_v1';

  static FlashChoice fromName(String? n) =>
      values.firstWhere((v) => v.name == n, orElse: () => FlashChoice.off);
}

/// Self-timer from the quick menu: off / 3 s / 10 s.
enum TimerChoice {
  off(0, Icons.timer_off_outlined, 'Timer off'),
  s3(3, Icons.timer_3_rounded, 'Timer 3s'),
  s10(10, Icons.timer_10_rounded, 'Timer 10s');

  const TimerChoice(this.seconds, this.icon, this.label);

  final int seconds;
  final IconData icon;
  final String label;

  TimerChoice get next => values[(index + 1) % values.length];

  static const prefsKey = 'timer_choice_v1';

  static TimerChoice fromName(String? n) =>
      values.firstWhere((v) => v.name == n, orElse: () => TimerChoice.off);
}
