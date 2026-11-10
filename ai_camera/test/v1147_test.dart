import 'dart:io';
import 'dart:typed_data';

import 'package:ai_camera/models/quality_tier.dart';
import 'package:ai_camera/services/enhance_service.dart';
import 'package:ai_camera/services/macro_box.dart';
import 'package:ai_camera/services/mode_prompts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final home = File('lib/screens/home_camera_screen.dart').readAsStringSync();

  test('v11.47 version', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('version: 1.11.'));
  });

  test('sharpest photo: Laplacian variance, highest index wins', () {
    const w = 32, h = 32;
    final flat = Uint8List(w * h)..fillRange(0, w * h, 128);
    final edges = Uint8List(w * h);
    for (var i = 0; i < w * h; i++) {
      edges[i] = ((i % w) + (i ~/ w)).isEven ? 0 : 255;
    }
    expect(laplacianVariance(flat, w, h), 0);
    expect(laplacianVariance(edges, w, h), greaterThan(1000));
    expect(sharpestPhotoIndex([3, 9, 5]), 1);
    expect(sharpestPhotoIndex([7, 7]), 0); // tie → the final photo
    expect(sharpestPhotoIndex([]), -1);
    expect(home, contains('_sharpestMicroSource(path, crop, snap.zoom)'));
  });

  test('Microscope text-only only with a detected spot', () {
    expect(macroTextOnly('microscope', 'close-up', 'tiny hairs'), isTrue);
    expect(macroTextOnly('microscope', 'close-up', null), isFalse);
    expect(macroTextOnly('microscope', 'close-up', ''), isFalse);
    expect(macroTextOnly('extreme', 'leaf', null), isTrue);
    expect(macroTextOnly('macro', 'leaf', 'vein'), isFalse);
  });

  EnhanceJob job(String? part) => EnhanceJob(
    image: File('x.jpg'),
    tier: QualityTier.hd,
    zoom: 4,
    mode: 'macro',
    subject: part ?? kMacroGeneralSubject,
    part: part,
    macroLevel: 'microscope',
  );

  test('job: spot → no photo; none → photo flow', () {
    expect(job('tiny hairs').deepTextOnly, isTrue);
    expect(job(null).deepTextOnly, isFalse);
  });

  test('prompt: {spot} filled, 100x; fallback = photo prompt', () {
    final t = macroPrompt('close-up', level: 'microscope', part: 'tiny hairs');
    expect(t, contains('A tiny area of tiny hairs'));
    expect(t, contains('100x'));
    expect(t, isNot(contains('{spot}')));
    expect(kMacroMicroscopePrompt, contains('{spot}'));
    expect(
      macroPrompt('close-up', level: 'microscope', part: null),
      kMacroMicroscopePhotoPrompt,
    );
    expect(kMacroExtremePrompt, contains('1000x')); // Extreme unchanged
  });
}
