import 'package:ai_camera/models/products.dart';
import 'package:ai_camera/models/quality_tier.dart';
import 'package:ai_camera/services/entitlements.dart';
import 'package:ai_camera/services/optical_profile.dart';
import 'package:ai_camera/services/zoom_badge.dart';
import 'package:flutter_test/flutter_test.dart';

const s24 = OpticalProfile(
  usableFactors: [0.6, 1, 3, 5],
  allFactors: [0.6, 1, 3, 5],
  bestOptical: 5,
  sensorCropFactor: 2,
  opticalLimit: 5,
  appMaxZoom: 10,
  fromCamera2: true,
);

void main() {
  final now = DateTime.utc(2026, 10, 7, 10);
  final free = CreditState.initial(now);
  final pro = applyPurchase(free, kProMonthly, now);
  final freeNoTrial = free.copyWith(
    trialsUsed: {StarterTrial.highZoom, StarterTrial.premiumQuality},
  );

  ZoomBadgeInfo badge(double zoom, QualityTier tier, CreditState s) =>
      computeZoomBadge(
        aiMode: true,
        zoom: zoom,
        optical: s24,
        tier: tier,
        state: s,
        now: now,
      );

  test('Normal mode: no badge', () {
    final b = computeZoomBadge(
      aiMode: false,
      zoom: 30,
      optical: s24,
      tier: QualityTier.hd,
      state: free,
      now: now,
    );
    expect(b.main, isNull);
  });

  test('Pro user 30x Ultra HD: "AI 30x · Ultra HD · 4 credits"', () {
    final b = badge(30, QualityTier.ultraHd, pro);
    expect(b.main, 'AI 30x · Ultra HD · 4 credits');
    expect(b.locked, isFalse);
    expect(b.warning, isNull); // 30 < 35 (7 × 5)
    expect(b.hint, isNull);
  });

  test('free above optical, trial used → AI is Pro only', () {
    final b = badge(10, QualityTier.hd, freeNoTrial);
    expect(b.main, kAiProOnly);
    expect(b.locked, isTrue);
  });

  test('free above optical with trial → free trial', () {
    final b = badge(10, QualityTier.hd, free);
    expect(b.main, 'AI 10x · HD · free trial');
    expect(b.trial, isTrue);
  });

  test('free within optical: credits shown', () {
    expect(badge(3, QualityTier.hd, free).main, 'AI 3x · HD · 1 credit');
  });

  test('beyond ~7x optical → warning; HD at high zoom → soft hint', () {
    final b = badge(50, QualityTier.hd, pro);
    expect(b.warning, kHighZoomWarning);
    expect(b.hint, kTryFullHdHint);
    final fhd = badge(50, QualityTier.fullHd, pro);
    expect(fhd.hint, isNull);
    expect(fhd.main, 'AI 50x · Full HD · 2 credits'); // zoom never adds cost
  });

  test('HD hint threshold: > 2× optical', () {
    expect(badge(10, QualityTier.hd, pro).hint, isNull);
    expect(badge(11, QualityTier.hd, pro).hint, kTryFullHdHint);
  });

  test('transient notice: lock > warning > hint > trial; none in Normal', () {
    expect(zoomNotice(ZoomBadgeInfo.none), isNull);
    expect(zoomNotice(badge(30, QualityTier.hd, freeNoTrial)), kAiProOnly);
    expect(zoomNotice(badge(50, QualityTier.fullHd, pro)), kHighZoomWarning);
    expect(zoomNotice(badge(20, QualityTier.hd, pro)), kTryFullHdHint);
    expect(zoomNotice(badge(10, QualityTier.hd, free)), kTrialNotice);
    expect(zoomNotice(badge(3, QualityTier.hd, free)), isNull);
  });

  test('UI strings are English', () {
    for (final s in [
      kAiProOnly,
      kHighZoomWarning,
      kTryFullHdHint,
      kTrialNotice,
    ]) {
      expect(RegExp(r'[\u0900-\u097F]').hasMatch(s), isFalse, reason: s);
    }
    expect(kHighZoomWarning, 'Extreme zoom — AI will estimate details');
    expect(kAiProOnly, 'AI is Pro only');
    expect(kTryFullHdHint, 'Try Full HD for better detail');
  });
}
