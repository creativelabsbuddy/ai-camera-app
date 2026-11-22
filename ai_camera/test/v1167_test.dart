// v11.67 (1.11.67+80) tests: one group per agreed change.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_camera/services/macro.dart';
import 'package:ai_camera/services/macro_gates.dart';
import 'package:ai_camera/services/zoom_range.dart';

void main() {
  final home = File('lib/screens/home_camera_screen.dart').readAsStringSync();

  group('1: Microscope / Extreme / Ultra 15x via digital crop', () {
    const micro = [MacroLevel.microscope, MacroLevel.extreme, MacroLevel.ultra];
    // S24 Ultra: camera reports 10x, display range 100x.
    final s24 = computeZoomRange(
      controllerMin: 0.6,
      controllerMax: 10,
      nativeReportedMax: 10,
      teleMultiplier: 5,
    );

    test('limit: micro levels past the camera max, Macro / Close not', () {
      for (final l in micro) {
        final lim = macroZoomLimit(
          l,
          hardwareMax: s24.hardwareMax,
          displayMax: s24.displayMax,
        );
        expect(macroLevelZoomMax(l, lim), 15);
        expect(macroGateZooms(l, lim), [1.5, 5.0]);
        expect(macroGateCap(l, lim, {1.5, 5.0}), 15);
        expect(macroLevelZoomChips(l, lim), [1, 2, 3, 5, 10, 15]);
      }
      for (final l in [MacroLevel.macro, MacroLevel.close, null]) {
        final lim = macroZoomLimit(
          l,
          hardwareMax: s24.hardwareMax,
          displayMax: s24.displayMax,
        );
        expect(lim, 10);
        expect(macroLevelZoomMax(l, lim), 10);
        expect(macroLevelZoomChips(l, lim), [1, 2, 3, 5, 10]);
      }
    });

    test('front-like range (display = camera max) stays capped', () {
      final lim = macroZoomLimit(
        MacroLevel.microscope,
        hardwareMax: 8,
        displayMax: 8,
      );
      expect(macroLevelZoomMax(MacroLevel.microscope, lim), 8);
    });

    test('15x = camera 10x × centre crop 1.5x (preview + still)', () {
      final p = planZoom(requested: 15, range: s24);
      expect(p.selected, 15);
      expect(p.cameraZoom, 10);
      expect(p.digitalZoom, closeTo(1.5, 1e-9));
      final cap = macroCaptureZoom(
        chip: 15,
        previewCamera: p.cameraZoom,
        opticalCap: macroCameraCap(hardwareMax: 10, opticalLimit: 10),
      );
      expect(cap.camera, 10);
      expect(cap.crop, closeTo(1.5, 1e-9));
    });

    test('home screen feeds the crop-aware limit everywhere', () {
      expect(home, contains('macroLevelZoomMax(_macroLevel, _macroLimit)'));
      expect(home, contains('macroGateCap(_macroLevel, _macroLimit, _gatesDone)'));
      expect(home, contains('macroGateDue(level, _macroLimitFor(level), _gatesDone, _zoom)'));
      expect(home, contains('macroLevelZoomChips(level, _macroLimit)'));
      expect(home, isNot(contains('macroLevelZoomMax(_macroLevel, _range.hardwareMax)')));
      expect(home, contains("crop \${_digitalZoom.toStringAsFixed(2)}x"));
    });
  });
}
