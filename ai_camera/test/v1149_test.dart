import 'dart:io';

import 'package:ai_camera/config/ai_config.dart';
import 'package:ai_camera/models/shoot_mode.dart';
import 'package:ai_camera/services/macro.dart';
import 'package:ai_camera/services/mode_prompts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final home = File('lib/screens/home_camera_screen.dart').readAsStringSync();

  test('v11.49 version', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('version: 1.11.'));
  });

  test('1: HDR removed everywhere; saved HDR → Photo', () {
    expect(ShootMode.strip, isNot(contains(ShootMode.hdr)));
    expect(ShootMode.stripFor(aiMode: false), isNot(contains(ShootMode.hdr)));
    expect(ShootMode.fromName('hdr'), ShootMode.photo);
    expect(routeFor(ShootMode.hdr).capture, CaptureKind.single);
  });

  test('2: level chips never move the zoom', () {
    expect(home, isNot(contains('macroLevelStartZoom(level')));
    expect(home, isNot(contains('await _animateZoom(kMicroscopeHintMaxZoom)')));
    expect(home, contains('macroLevelPickZoom(_zoom, _range.hardwareMax)'));
  });

  test('3a: detect prompt asks for the name, mirrors JSON + device rule', () {
    expect(kDetectBoxPrompt, contains('common name of the object or material'));
    expect(kDetectBoxPrompt, contains('not its colour, texture or look'));
    expect(kDetectBoxPrompt, contains('at most 6 words'));
    expect(kDetectBoxPrompt, contains('name the device itself'));
    expect(kDetectBoxWideLine, contains('first image is a wider view'));
  });

  test('3b/3c: sharpest patch + widest step photo for all 3 deep levels', () {
    expect(home, contains('if (level != null && level.isMicroscopic) {'));
    expect(home, contains('widePath: _macroWidePath(snap.zoom)'));
  });

  test('3d: vague names rejected', () {
    expect(
      isVagueDetect('white textured surface with many small circles'),
      isTrue,
    );
    expect(isVagueDetect('gray dots'), isTrue);
    expect(isVagueDetect(''), isTrue);
    expect(isVagueDetect('sugar crystals'), isFalse);
    expect(isVagueDetect('leaf'), isFalse);
    expect(macroTextOnly('microscope', 'close-up', 'white surface'), isFalse);
    expect(macroTextOnly('extreme', null, 'pattern of dots'), isFalse);
    expect(macroTextOnly('ultra', null, 'cotton fabric'), isTrue);
  });

  test('3e: result line says Detected / Not detected', () {
    expect(
      macroDetectNote(MacroLevel.extreme, 'tree bark'),
      ' · Detected: tree bark',
    );
    expect(
      macroDetectNote(MacroLevel.microscope, null),
      ' · Not detected, used photo',
    );
    expect(macroDetectNote(MacroLevel.macro, 'x'), '');
  });

  test('3f: detect image 768 px', () {
    expect(AiConfig.detectLongSide, 768);
  });
}
