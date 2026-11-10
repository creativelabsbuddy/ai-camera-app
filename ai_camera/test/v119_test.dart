import 'package:ai_camera/services/premium_filters.dart';
import 'package:ai_camera/models/quality_tier.dart';
import 'package:ai_camera/services/context_snapshot.dart';
import 'package:ai_camera/services/enhance_service.dart';
import 'package:ai_camera/services/prompt_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:io';

void main() {
  final now = DateTime(2026, 10, 14, 6);
  ContextSnapshot snap(double cam, {Duration age = Duration.zero}) =>
      ContextSnapshot(path: 'x.jpg', cameraZoom: cam, at: now.subtract(age));

  test('snapshot taken only at <=3x; refreshed when old or scene changed', () {
    expect(shouldTakeSnapshot(zoom: 1.3, existing: null, now: now), isTrue);
    expect(shouldTakeSnapshot(zoom: 5, existing: null, now: now), isFalse);
    expect(shouldTakeSnapshot(zoom: 2, existing: snap(1), now: now), isFalse);
    expect(
      shouldTakeSnapshot(
        zoom: 2,
        existing: snap(1, age: const Duration(seconds: 30)),
        now: now,
      ),
      isTrue,
    );
    expect(
      shouldTakeSnapshot(
        zoom: 2,
        existing: snap(1),
        now: now,
        sceneChange: 0.3,
      ),
      isTrue,
    );
  });

  test('zoom region maps into the snapshot; used for macro and 100x zoom', () {
    expect(snapshotRegionZoom(25, 1.3), closeTo(19.23, 0.01));
    expect(snapshotRegionZoom(100, 2), 50);
    expect(useSnapshot(snap(1.3), 25), isTrue);
    expect(useSnapshot(snap(2), 2.5), isFalse);
    expect(useSnapshot(null, 25), isFalse);
  });

  test('colour filter off at Microscope/Extreme', () {
    final f = PremiumFilter.values.firstWhere((f) => !f.isOriginal);
    EnhanceJob job(String level) => EnhanceJob(
      image: File('x'),
      mode: 'macro',
      macroLevel: level,
      colorFilter: f,
    );
    expect(job('extreme').colorFilterId, isNull);
    expect(job('microscope').colorFilterId, isNull);
    expect(job('close').colorFilterId, f.id);
  });

  test('high-zoom clarity + boxed context in the photo prompt', () {
    final p = buildEnhancePrompt(
      hasContextImage: true,
      zoom: 30,
      opticalLimit: 3,
      contextBoxed: true,
    );
    expect(p.startsWith(kLockedEnhancePrompt), isTrue);
    expect(p, contains(kContextBoxedSentence));
    expect(p, contains(kHighZoomClarity));
    expect(kHighZoomClarity, contains('exactly as it is')); // v11.39
    expect(
      buildEnhancePrompt(zoom: 2, opticalLimit: 2),
      isNot(contains(kHighZoomClarity)),
    );
  });

  test('FHD default from 30x; cheap-phone merge plan', () {
    expect(tierForZoom(QualityTier.hd, 30), QualityTier.fullHd);
    expect(tierForZoom(QualityTier.hd, 30, picked: true), QualityTier.hd);
    expect(tierForZoom(QualityTier.hd, 10), QualityTier.hd);
    expect(tierForZoom(QualityTier.ultraHd, 50), QualityTier.ultraHd);
    expect(shouldMergeZoom(lowEnd: true, zoom: 20, opticalLimit: 2), isTrue);
    expect(shouldMergeZoom(lowEnd: false, zoom: 20, opticalLimit: 2), isFalse);
    expect(
      shouldMergeZoom(lowEnd: true, zoom: 3, opticalLimit: 2),
      isTrue,
    ); // v11.39
    expect(shouldMergeZoom(lowEnd: true, zoom: 1.5, opticalLimit: 1), isFalse);
    expect(kZoomMergeFrames, 4); // v11.30
    expect(sharpestFirst([1, 9, 3, 7, 5, 2], keep: 3), [1, 3, 4]);
    expect(holdSteadyCountdown(3), 'Hold steady · 3');
  });
}
