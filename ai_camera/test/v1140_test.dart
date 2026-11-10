import 'dart:io';

import 'package:ai_camera/services/enhance_service.dart';
import 'package:ai_camera/services/macro_box.dart';
import 'package:ai_camera/services/mode_prompts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final home = File('lib/screens/home_camera_screen.dart').readAsStringSync();

  test('v11.40 version', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('version: 1.11.'));
  });

  test('shutter never blocked by the box; no refusal after the shutter', () {
    expect(home, isNot(contains('_boxCheck.ready) {')));
    expect(home, isNot(contains('MacroBoxGuide.moveCloser')));
    expect(home, isNot(contains('_macroGuide')));
  });

  test('manual zoom 1x–5x; no auto start zoom', () {
    expect(macroLevelMaxZoom(30), 10);
    expect(macroZoomChips(30), [1, 2, 3, 5, 10]);
    expect(macroZoomChips(3), [1, 2, 3]);
    expect(home, contains('macro_zoom_chips'));
  });

  test('context zoom steps below the shot zoom', () {
    expect(macroContextZooms(1), isEmpty);
    expect(home, contains('_takeMacroContext('));
  });

  test('context line general', () {
    expect(kMacroContextLine, contains('wider context'));
    expect(kMacroContextLine, isNot(contains('{subject}')));
  });

  test('Extreme without a spot sends the photo', () {
    final j = EnhanceJob(
      image: File('x.jpg'),
      mode: 'macro',
      macroLevel: 'extreme',
    );
    expect(j.deepTextOnly, isFalse);
  });
}
