import 'dart:io';
import 'dart:typed_data';

import 'package:ai_camera/services/ai_call.dart';
import 'package:ai_camera/services/color_match.dart';
import 'package:ai_camera/services/enhance_service.dart';
import 'package:ai_camera/services/macro_box.dart';
import 'package:ai_camera/services/mode_prompts.dart';
import 'package:ai_camera/services/steady.dart';
import 'package:ai_camera/services/vision.dart';
import 'package:ai_camera/screens/preview_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Uint8List _solid(int r, int g, int b) => Uint8List.fromList(
  img.encodeJpg(
    img.Image(width: 32, height: 32)..clear(img.ColorRgb8(r, g, b)),
  ),
);

void main() {
  final home = File('lib/screens/home_camera_screen.dart').readAsStringSync();

  test('v11.42 version', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('version: 1.11.'));
  });

  test('A: macro / close keep the framing; microscope keeps its zoom', () {
    for (final t in [kMacroPrompt, kMacroClosePrompt]) {
      expect(t, contains('same framing'));
      expect(t, isNot(contains('strongly zoomed')));
      expect(t, isNot(contains('filling the frame')));
    }
    expect(kMacroClosePrompt, contains('remove blur and noise'));
    expect(kMacroMicroscopePhotoPrompt, contains('strongly zoomed in'));
    expect(kMacroContextLine, isNot(contains('zoomed centre')));
  });

  test('B: colour match skipped when far, overall shift capped', () {
    expect(colorMatchSkip([128, 100, 160], [128, 128, 128]), isTrue);
    expect(colorMatchSkip([128, 126, 130], [128, 128, 128]), isFalse);
    expect(kGlobalMaxShift, 10);
    final src = _solid(120, 120, 130);
    final ai = _solid(120, 124, 120);
    final out = matchColorsSync(ai, src);
    expect(
      chromaDistance(out, src),
      lessThanOrEqualTo(chromaDistance(ai, src) + 1),
    );
  });

  test('C: context photos really wider', () {
    expect(kMacroCtxMargin, 2.5);
    expect(macroCtxCropZoom(10), 4);
    expect(macroCtxCropZoom(2), 1);
    expect(home, contains('kMacroCtxMinWider'));
  });

  test('D: framing check only with reference photos; rejected viewable', () {
    expect(framingCheckApplies(ladder: false, contextUsed: false), isFalse);
    expect(framingCheckApplies(ladder: false, contextUsed: true), isFalse);
    expect(framingCheckApplies(ladder: true, contextUsed: false), isFalse);
    expect(framingCheckApplies(ladder: true, contextUsed: true), isTrue);
    expect(
      rejectedViewLabel(AiFailureKind.framingChanged, 0.26),
      'Rejected: framing 0.26 — tap to view',
    );
  });

  test('E: steadiness, throttle, zoom ramp, stabilisation, overlay', () {
    expect(steadyActive(zoom: 12, back: true), isTrue);
    expect(steadyActive(zoom: 8, back: true), isFalse);
    expect(steadyActive(zoom: 12, back: false), isFalse);
    final m = SteadyMeter();
    final t0 = DateTime(2026);
    m.add(1, t0);
    expect(m.moving, isTrue);
    for (var i = 1; i <= 20; i++) {
      m.add(0, t0.add(Duration(milliseconds: 20 * i)));
    }
    expect(m.moving, isFalse);
    expect(m.steadyAt(t0.add(const Duration(seconds: 2))), isTrue);
    expect(
      shutterMayFire(steady: false, waited: const Duration(seconds: 2)),
      isTrue,
    );
    expect(
      shutterMayFire(steady: false, waited: const Duration(milliseconds: 200)),
      isFalse,
    );
    final now = DateTime(2026);
    expect(
      throttleFrame(
        zoom: 8,
        last: now.subtract(const Duration(milliseconds: 50)),
        now: now,
      ),
      isTrue,
    );
    expect(
      throttleFrame(
        zoom: 3,
        last: now.subtract(const Duration(milliseconds: 50)),
        now: now,
      ),
      isFalse,
    );
    expect(kChipZoomRamp.inMilliseconds, 200);
    expect(home, contains('CameraExtras.setStabilization(true)'));
    expect(home, contains('_waitSteady()'));
    expect(
      home,
      contains('onSelected: _processingCapture ? null : _onZoomChip'),
    );
    final j = File(
      'packages/camera_android_camerax/android/src/main/java/io/flutter/plugins/camerax/CameraXExtras.java',
    ).readAsStringSync();
    expect(j, contains('LENS_OPTICAL_STABILIZATION_MODE_ON'));
    expect(
      j,
      contains('CONTROL_VIDEO_STABILIZATION_MODE_PREVIEW_STABILIZATION'),
    );
    final x = File(
      'packages/camera_android_camerax/lib/src/android_camera_camerax.dart',
    ).readAsStringSync();
    expect(x, contains('_analysisResolutionSelector()'));
    expect(
      debugOverlayText(
        uiFps: 60,
        analysedFps: 6.5,
        frameW: 640,
        frameH: 480,
        gyro: 0.05,
        stabilization: 'OIS',
      ),
      contains('analysis 640x480'),
    );
  });
}
