import 'dart:io';

import 'package:ai_camera/services/zoom_range.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('v11.45 version', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('version: 1.11.'));
  });

  test('v11.44 macro main-lens lock removed: macro uses the normal lenses', () {
    final home = File('lib/screens/home_camera_screen.dart').readAsStringSync();
    expect(home, isNot(contains('mainLensOnly')));
    expect(home, isNot(contains('_macroMainLens')));
    final range = computeZoomRange(controllerMin: 0.6, controllerMax: 10);
    final p = planZoom(requested: 5, range: range);
    expect(p.cameraZoom, 5); // real-lens zoomRatio, as in v11.43
    expect(p.digitalZoom, 1);
  });

  test('v11.43 centre-box crop removed: full visible view (as v11.42)', () {
    final home = File('lib/screens/home_camera_screen.dart').readAsStringSync();
    expect(home, isNot(contains('boxCrop')));
    expect(home, isNot(contains('kMacroBoxSavedNote')));
    expect(home, contains("ValueKey('macro_box')")); // guide box still drawn
  });
}
