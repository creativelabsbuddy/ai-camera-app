import 'package:ai_camera/services/macro.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('preview uses hardware zoom, scaling only beyond hardware max', () {
    final a = macroPreviewZoom(chip: 8, minZoom: 1, hardwareMax: 10);
    expect(a.camera, 8);
    expect(a.digital, 1);
    final b = macroPreviewZoom(chip: 30, minZoom: 1, hardwareMax: 10);
    expect(b.camera, 10);
    expect(b.digital, closeTo(3, 1e-9));
  });

  test('shutter drops to optical limit and crops the rest', () {
    final c = macroCaptureZoom(chip: 20, previewCamera: 10, opticalCap: 2);
    expect(c.camera, 2);
    expect(c.crop, 10);
    final d = macroCaptureZoom(chip: 2, previewCamera: 2, opticalCap: 3);
    expect(d.camera, 2);
    expect(d.crop, 1);
  });

  test('burst size, fixed focus, analysis stop, tip', () {
    expect(macroBurstCount(lowEnd: true), 4); // v11.29
    expect(macroBurstCount(lowEnd: false), 4);
    expect(isFixedFocus(0), isTrue);
    expect(isFixedFocus(8), isFalse);
    expect(isFixedFocus(null), isFalse);
    expect(macroNeedsAnalysis(subjectLocked: true, chip: 10), isFalse);
    expect(macroNeedsAnalysis(subjectLocked: true, chip: 2), isTrue);
    expect(macroNeedsAnalysis(subjectLocked: false, chip: 10), isTrue);
    expect(kMacroTip, 'Keep ~10 cm away, zoom with chips; tap to focus.');
    expect(kFixedFocusTip, 'Hold ~10 cm away');
    for (final s in [
      'Coin',
      'Fabric',
      'Leaf',
      'Skin',
      'Eye',
      'Paper',
      'Wood',
      'Metal',
    ]) {
      expect(kMacroSubjectChoices, contains(s));
    }
  });

  test('region sharpness looks at the centre region', () {
    const w = 40, h = 40;
    final px = List<double>.generate(w * h, (i) {
      final x = i % w, y = i ~/ w;
      final centre = (x - 20).abs() < 5 && (y - 20).abs() < 5;
      return centre ? 0 : ((x + y).isEven ? 255.0 : 0.0);
    });
    expect(regionSharpness(px, w, h, 8), lessThan(1));
  });
}
