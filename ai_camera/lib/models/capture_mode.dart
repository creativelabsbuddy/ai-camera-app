/// Camera screen mode (persisted, default [normal]).
/// * [normal] – plain camera: photo shown / saved exactly as captured, no
///   AI (free local filters still available on the preview).
/// * [pro]    – AI on: auto AI enhance right after capture. Whether a given
///   shot may use AI (optical limit, Pro subscription, credits, starter
///   trials) is decided by entitlements.dart — never by the mode alone.
/// Zoom range (up to 100x) is identical in both modes.
enum CaptureMode {
  normal('Normal'),
  pro('Pro');

  const CaptureMode(this.label);

  final String label;

  /// shared_preferences key.
  static const prefsKey = 'capture_mode';

  static CaptureMode fromName(String? name) => CaptureMode.values.firstWhere(
    (m) => m.name == name,
    orElse: () => CaptureMode.normal,
  );
}

/// True when PreviewScreen should try AI enhance right after capture.
bool shouldAutoEnhance({required CaptureMode mode}) => mode == CaptureMode.pro;
