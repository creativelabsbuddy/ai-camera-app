import 'dart:math' as math;

// v11.42 stability helpers: gyro steadiness above 10x, smooth chip zoom,
// debug overlay line. All pure → unit tested.

/// Gyro steadiness runs above this zoom (back camera).
const double kSteadyZoom = 10;

/// Smoothed rotation rate (rad/s) above this → "Hold steady".
const double kGyroMoving = 0.10;

/// The phone must be still this long before a high-zoom shot…
const Duration kSteadyHold = Duration(milliseconds: 300);

/// …but the shutter never waits longer than this.
const Duration kSteadyMaxWait = Duration(milliseconds: 1500);

/// Chip-tap zoom ramp.
const Duration kChipZoomRamp = Duration(milliseconds: 200);

/// Settings switch (test builds): camera debug overlay, off by default.
const String kDebugOverlayKey = 'camera_debug_overlay_v1';

const String kSteadyHint = 'Hold steady';

/// Gyro steadiness only on the back camera above [kSteadyZoom].
bool steadyActive({required double zoom, required bool back}) =>
    back && zoom > kSteadyZoom;

/// Rotation rate magnitude (rad/s) of one gyro sample.
double gyroMagnitude(double x, double y, double z) =>
    math.sqrt(x * x + y * y + z * z);

/// Exponential smoothing of the rotation rate.
double smoothGyro(double prev, double sample, {double k = 0.3}) =>
    prev + (sample - prev) * k;

/// Tracks how long the phone has been still.
class SteadyMeter {
  double rate = 0;
  DateTime? stillSince;

  bool get moving => rate > kGyroMoving;

  void add(double magnitude, DateTime now) {
    rate = smoothGyro(rate, magnitude);
    if (moving) {
      stillSince = null;
    } else {
      stillSince ??= now;
    }
  }

  void reset() {
    rate = 0;
    stillSince = null;
  }

  /// Still for at least [kSteadyHold]?
  bool steadyAt(DateTime now) {
    final s = stillSince;
    return s != null && now.difference(s) >= kSteadyHold;
  }
}

/// Shutter wait decision: capture now when steady or the max wait passed.
bool shutterMayFire({required bool steady, required Duration waited}) =>
    steady || waited >= kSteadyMaxWait;

/// Finer ruler steps above 10x: 0.5x from 10x to 30x, 1x above. Pure.
double highZoomStep(double z) => z < 30 - 0.01 ? 0.5 : 1.0;

/// Debug overlay line.
String debugOverlayText({
  required double uiFps,
  required double analysedFps,
  required int frameW,
  required int frameH,
  required double gyro,
  required String stabilization,
}) =>
    'ui ${uiFps.toStringAsFixed(0)} fps · analysis ${frameW}x$frameH @ '
    '${analysedFps.toStringAsFixed(1)}/s · gyro ${gyro.toStringAsFixed(2)} '
    'rad/s · stab ${stabilization.isEmpty ? '—' : stabilization}';
