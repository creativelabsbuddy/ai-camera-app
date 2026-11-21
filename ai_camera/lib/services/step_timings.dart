/// v11.66 test builds only: how long each step of one AI enhance took.
/// Shown as one debug line under the result ("Net 0.2s · Upload 1.1s ·
/// Flare 17.4s · Upscale 2.9s · Resize 0.3s"). Never shown in a release
/// (no embedded key) build.
class StepTimings {
  StepTimings({
    this.netMs,
    this.uploadMs,
    this.flareMs,
    this.upscaleMs,
    this.resizeMs,
    this.serverMs,
  });

  /// Last real internet probe (the shutter / precheck), not a cached answer.
  int? netMs;

  /// Image prep (resize + encode) and sending the request body.
  int? uploadMs;

  /// From the body sent until the Flare image is decoded.
  int? flareMs;

  /// Real-ESRGAN on Runware (Full HD / Ultra HD only).
  int? upscaleMs;

  /// Resize to the tier's long side (Full HD / Ultra HD only).
  int? resizeMs;

  /// Server path: the whole server round trip (upload + Flare + upscale run
  /// on the server, not separable on the phone).
  int? serverMs;

  static String fmt(int? ms) {
    if (ms == null) return '—';
    if (ms < 1000) return '${ms}ms';
    return '${(ms / 1000).toStringAsFixed(1)}s';
  }

  String line() {
    final parts = <String>['Net ${fmt(netMs)}'];
    if (serverMs != null) {
      parts.add('Server ${fmt(serverMs)} (upload+Flare+upscale)');
    } else {
      parts
        ..add('Upload ${fmt(uploadMs)}')
        ..add('Flare ${fmt(flareMs)}');
    }
    parts
      ..add('Upscale ${fmt(upscaleMs)}')
      ..add('Resize ${fmt(resizeMs)}');
    return parts.join(' · ');
  }
}
