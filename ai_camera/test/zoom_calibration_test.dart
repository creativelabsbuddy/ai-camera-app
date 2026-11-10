import 'package:ai_camera/services/capture_crop.dart';
import 'package:ai_camera/services/zoom_range.dart';
import 'package:flutter_test/flutter_test.dart';

/// Displayed N× must equal the true field of view relative to the main
/// lens' 1x full 4:3 frame: CameraX zoomRatio × digital crop.
void main() {
  // Upright 12MP 4:3 still as delivered at ANY camera zoom ratio (the camera
  // already narrowed the FOV by cameraZoom).
  const iw = 3000, ih = 4000;

  /// Fraction of the 1x frame's width / height that the saved photo spans.
  (double, double) fovFraction(double requested, ZoomRange r, double ratio) {
    final plan = planZoom(requested: requested, range: r);
    final crop = computeCaptureCrop(
      iw: iw,
      ih: ih,
      portraitRatio: ratio,
      digitalZoom: plan.digitalZoom,
    );
    return (
      crop.width / iw / plan.cameraZoom,
      crop.height / ih / plan.cameraZoom,
    );
  }

  for (final hwMax in [10.0, 8.0]) {
    final r = computeZoomRange(controllerMin: 0.6, controllerMax: hwMax);
    group('camera max ${hwMax}x', () {
      for (final z in [1.0, 2.0, 5.0, 10.0, 30.0, 100.0]) {
        test('${z}x: camera × digital == ${z}x and 4:3 crop = 1/$z', () {
          final plan = planZoom(requested: z, range: r);
          expect(plan.cameraZoom, lessThanOrEqualTo(hwMax));
          expect(plan.effectiveZoom, closeTo(z, 1e-9));
          final (fw, fh) = fovFraction(z, r, 3 / 4);
          expect(fw, closeTo(1 / z, 0.002 / z));
          expect(fh, closeTo(1 / z, 0.002 / z));
        });
      }
    });
  }

  test('S24-like 100x = camera 10x × digital 10x; 30x = 10 × 3', () {
    final r = computeZoomRange(controllerMin: 0.6, controllerMax: 10);
    final p100 = planZoom(requested: 100, range: r);
    expect((p100.cameraZoom, p100.digitalZoom), (10.0, 10.0));
    final p30 = planZoom(requested: 30, range: r);
    expect((p30.cameraZoom, p30.digitalZoom), (10.0, 3.0));
    final p10 = planZoom(requested: 10, range: r);
    expect((p10.cameraZoom, p10.digitalZoom), (10.0, 1.0));
    // 100x on a 3000×4000 still at camera 10x → 300×400 px crop.
    final crop = computeCaptureCrop(
      iw: iw,
      ih: ih,
      portraitRatio: 3 / 4,
      digitalZoom: p100.digitalZoom,
    );
    expect((crop.width, crop.height), (300, 400));
  });

  test('9:16 keeps full height (like stock 9:16); zoom unaffected', () {
    final r = computeZoomRange(controllerMin: 0.6, controllerMax: 10);
    final (fw, fh) = fovFraction(100, r, 9 / 16);
    expect(fh, closeTo(1 / 100, 0.00002)); // vertical FOV = exactly 1/100
    // Width is cropped to 9:16 of the height → 0.75 of the 4:3 width.
    expect(fw, closeTo(0.75 / 100, 0.00002));
  });

  test('ultra-wide range: 0.6x needs no digital crop', () {
    final r = computeZoomRange(controllerMin: 0.6, controllerMax: 10);
    final p = planZoom(requested: 0.6, range: r);
    expect((p.cameraZoom, p.digitalZoom), (0.6, 1.0));
  });
}
