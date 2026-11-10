import 'dart:typed_data';

import 'package:ai_camera/services/capture_crop.dart';
import 'package:ai_camera/services/color_match.dart';
import 'package:ai_camera/services/macro.dart';
import 'package:ai_camera/services/upload_prep.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Uint8List _solid(int r, int g, int b, {int w = 120, int h = 90}) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(r, g, b));
  // A little texture so the spread is non-zero.
  for (var x = 0; x < w; x += 6) {
    img.drawLine(
      im,
      x1: x,
      y1: 0,
      x2: x,
      y2: h - 1,
      color: img.ColorRgb8((r * 0.8).round(), (g * 0.8).round(), b),
    );
  }
  return Uint8List.fromList(img.encodeJpg(im, quality: 95));
}

void main() {
  test('camera zoom never passes the optical limit', () {
    expect(macroCameraCap(hardwareMax: 8, opticalLimit: 2), 2);
    expect(macroCameraCap(hardwareMax: 1.5, opticalLimit: 3), 1.5);
    expect(macroCameraCap(hardwareMax: 8, opticalLimit: double.nan), 1);
    // 10x chip on a 2x-optical phone: camera 2x × 5x region for the AI.
    final z = planMacroZoom(
      10,
      MacroLenses(
        maxCameraZoom: macroCameraCap(hardwareMax: 8, opticalLimit: 2),
      ),
    );
    expect(z.cameraZoom, 2);
    expect(z.digitalZoom, 5);
    // 20x: camera stays at the optical limit, region = 1/10 of the frame.
    final z20 = planMacroZoom(
      20,
      MacroLenses(
        maxCameraZoom: macroCameraCap(hardwareMax: 8, opticalLimit: 2),
      ),
    );
    expect(z20.cameraZoom, 2);
    expect(z20.digitalZoom, 10);
  });

  test('boxed context: red outline around the crop, frame downscaled', () {
    final full = img.Image(width: 4000, height: 3000);
    img.fill(full, color: img.ColorRgb8(30, 120, 40));
    final rect = computeCaptureCrop(
      iw: 4000,
      ih: 3000,
      portraitRatio: 3 / 4,
      digitalZoom: 5,
    );
    final b = boxedContext(full, rect);
    expect(b.width, kMacroBoxedLongSide);
    expect(b.height, 960);
    final s = kMacroBoxedLongSide / 4000;
    final edge = b.getPixel(
      (rect.x * s).round(),
      ((rect.y + rect.height / 2) * s).round(),
    );
    expect(edge.r, greaterThan(200));
    expect(edge.g, lessThan(80));
    final centre = b.getPixel(b.width ~/ 2, b.height ~/ 2);
    expect(centre.g, greaterThan(centre.r)); // inside the box untouched
    final outside = b.getPixel(10, 10);
    expect(outside.r, lessThan(80));
  });

  test('boxed context uploads at 1024, normal context at 768', () {
    expect(contextLongSideFor('/x/shot_3x4_z50_boxed.jpg'), 1024);
    expect(contextLongSideFor('/x/shot_3x4_z50_context.jpg'), 768);
  });

  test('colour match pulls a greener AI result back to the source hue', () {
    final src = _solid(190, 200, 60); // yellow-green leaf
    final ai = _solid(60, 170, 60); // AI drifted greener
    expect(chromaDistance(ai, src), greaterThan(15));
    // v11.42: colours far from the source → the match is skipped (the AI
    // changed what is in the frame); the result is kept as it came back.
    final fixed = matchColorsSync(ai, src);
    expect(fixed, same(ai));
  });

  test('regional colour match: golden top on uniform silver goes silver', () {
    final silver = img.Image(width: 200, height: 200);
    img.fill(silver, color: img.ColorRgb8(170, 172, 175));
    for (var x = 0; x < 200; x += 9) {
      img.drawLine(
        silver,
        x1: x,
        y1: 0,
        x2: x + 20,
        y2: 199,
        color: img.ColorRgb8(120, 122, 125),
      );
    }
    final src = Uint8List.fromList(img.encodeJpg(silver, quality: 95));
    final golden = img.Image.from(silver);
    for (var y = 0; y < 80; y++) {
      for (var x = 0; x < 200; x++) {
        final p = golden.getPixel(x, y);
        golden.setPixelRgb(
          x,
          y,
          (p.r * 0.4 + 205 * 0.6).round(),
          (p.g * 0.4 + 175 * 0.6).round(),
          (p.b * 0.4 + 95 * 0.6).round(),
        );
      }
    }
    final out = Uint8List.fromList(img.encodeJpg(golden, quality: 95));
    expect(regionalChromaSpread(out), greaterThan(12));
    final fixed = matchColorsSync(out, src);
    expect(regionalChromaSpread(fixed), lessThan(4));
    expect(chromaDistance(fixed, src), lessThan(2));
  });

  test('levels: 21–30x Extreme Microscope, chips to 30x', () {
    expect(macroLevelFor(15), MacroLevel.microscope);
    expect(macroLevelFor(21), MacroLevel.extreme);
    expect(macroLevelFor(30), MacroLevel.ultra);
    expect(MacroLevel.extreme.label, 'Extreme Microscope 🔬');
    expect(MacroLevel.extreme.isMicroscopic, isTrue);
    expect(MacroLevel.close.isMicroscopic, isFalse);
    expect(kMacroChips, containsAll([21.0, 30.0]));
    expect(kMacroMaxZoom, 30);
    expect(macroFirstTipFor(MacroLevel.extreme), kExtremeFirstTip);
    expect(macroFirstTipFor(MacroLevel.close), isNull);
    expect(macroDisclaimerFor(30), kUltraDisclaimer);
    expect(macroDisclaimerFor(21), kExtremeDisclaimer);
    expect(macroDisclaimerFor(12), kMicroscopeDisclaimer);
    expect(macroDisclaimerFor(8), isNull);
    expect(showMicroscopeDisclaimer(25), isTrue);
    // Crop shrinks with zoom: 30x on a 2x-optical phone = 1/15 of the frame.
    final z = planMacroZoom(
      30,
      MacroLenses(
        maxCameraZoom: macroCameraCap(hardwareMax: 8, opticalLimit: 2),
      ),
    );
    expect(z.digitalZoom, 15);
  });
}
