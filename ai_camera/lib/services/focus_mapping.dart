import 'dart:math' as math;
import 'dart:ui';

/// Geometry of the live viewfinder (see HomeCameraScreen._buildLiveFrame):
/// the portrait camera preview ([previewSize], aspect = 1 / sensor aspect)
/// is cover-fitted and centred in the output-ratio frame ([frameSize]: 4:3,
/// 9:16 or 1:1), then scaled by [digitalZoom] about the frame centre (the
/// digital crop past the camera's own max zoom).
class PreviewGeometry {
  const PreviewGeometry({
    required this.frameSize,
    required this.previewSize,
    this.digitalZoom = 1.0,
  });

  /// Cover-fit a portrait preview of aspect [previewPortraitAspect] (w/h,
  /// e.g. 3/4) into [frame] — identical to the widget layout.
  factory PreviewGeometry.cover(
    Size frame,
    double previewPortraitAspect, {
    double digitalZoom = 1.0,
  }) {
    final a = (previewPortraitAspect.isFinite && previewPortraitAspect > 0)
        ? previewPortraitAspect
        : 3 / 4;
    final fw = frame.width;
    final fh = frame.height;
    final Size preview = fw / fh > a ? Size(fw, fw / a) : Size(fh * a, fh);
    return PreviewGeometry(
      frameSize: frame,
      previewSize: preview,
      digitalZoom: digitalZoom,
    );
  }

  final Size frameSize;
  final Size previewSize;
  final double digitalZoom;

  double get _dz => digitalZoom.isFinite && digitalZoom >= 1 ? digitalZoom : 1;
}

/// Maps a tap at [local] (frame coordinates) to the normalised (0..1) point
/// on the WHOLE un-altered portrait preview surface — what the CameraX
/// plugin's setFocusPoint / setExposurePoint expect (it uses a
/// DisplayOrientedMeteringPointFactory, which handles display rotation,
/// sensor orientation and front-lens mirroring). Returns null for taps
/// outside the frame. [mirror] is only for previews that are mirrored by
/// the app itself (not needed with CameraPreview).
Offset? tapToPreviewPoint(
  Offset local,
  PreviewGeometry g, {
  bool mirror = false,
}) {
  final fw = g.frameSize.width;
  final fh = g.frameSize.height;
  if (fw <= 0 || fh <= 0) return null;
  if (local.dx < 0 || local.dy < 0 || local.dx > fw || local.dy > fh) {
    return null;
  }
  final cx = fw / 2;
  final cy = fh / 2;
  // 1. Undo the digital crop zoom (Transform.scale about the centre).
  final ux = cx + (local.dx - cx) / g._dz;
  final uy = cy + (local.dy - cy) / g._dz;
  // 2. Undo the cover fit (preview centred, overflowing the frame).
  final left = (fw - g.previewSize.width) / 2;
  final top = (fh - g.previewSize.height) / 2;
  var x = (ux - left) / g.previewSize.width;
  final y = (uy - top) / g.previewSize.height;
  if (mirror) x = 1 - x;
  return Offset(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));
}

/// Inverse of [tapToPreviewPoint] (e.g. to draw the focus ring for a
/// metering point after a zoom change).
Offset previewPointToFrame(Offset p, PreviewGeometry g, {bool mirror = false}) {
  final fw = g.frameSize.width;
  final fh = g.frameSize.height;
  final x = mirror ? 1 - p.dx : p.dx;
  final left = (fw - g.previewSize.width) / 2;
  final top = (fh - g.previewSize.height) / 2;
  final ux = left + x * g.previewSize.width;
  final uy = top + p.dy * g.previewSize.height;
  return Offset(fw / 2 + (ux - fw / 2) * g._dz, fh / 2 + (uy - fh / 2) * g._dz);
}

/// Focus ring size relative to the frame (Samsung-like ~72 dp).
double focusRingDiameter(Size frame) =>
    math.max(56.0, math.min(84.0, math.min(frame.width, frame.height) * 0.2));

/// Tap-to-focus lifetime: CameraX auto-cancels a metering action after ~5 s
/// and returns to continuous AF; the app mirrors that and also resets on
/// zoom / lens / ratio changes.
const Duration kTapFocusHold = Duration(seconds: 5);

/// Pre-capture focus wait (shutter): long enough for a contrast/PDAF
/// convergence, short enough not to feel laggy.
const Duration kPreCaptureFocusWait = Duration(milliseconds: 900);

/// Skip the pre-capture AF if the user focused this recently.
const Duration kRecentFocusWindow = Duration(seconds: 3);
