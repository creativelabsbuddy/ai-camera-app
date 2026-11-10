import 'package:ai_camera/models/products.dart';
import 'package:ai_camera/models/quality_tier.dart';
import 'package:ai_camera/services/entitlements.dart';
import 'package:flutter_test/flutter_test.dart';

final t0 = DateTime.utc(2026, 10, 7, 10); // 15:30 IST, 7 Oct
const hd = EnhanceSpec(tier: QualityTier.hd);

CreditState spend(CreditState s, EnhanceSpec spec, DateTime now) {
  final d = decideEnhance(s, spec, now);
  expect(d.allowed, isTrue, reason: 'expected allowed: ${d.reason}');
  return applyDecision(s, d);
}

void main() {
  group('IST day + daily free credits', () {
    test('istDate flips at 18:30 UTC (IST midnight)', () {
      expect(istDate(DateTime.utc(2026, 10, 7, 18, 29, 59)), '2026-10-07');
      expect(istDate(DateTime.utc(2026, 10, 7, 18, 30)), '2026-10-08');
      // Phone in another zone: still IST calendar.
      expect(istDate(DateTime.utc(2026, 12, 31, 20)), '2027-01-01');
    });

    test('new device gets 2 free HD', () {
      final s = CreditState.initial(t0);
      expect(s.freeDaily, 2);
      expect(s.total(t0), 2);
      expect(s.freeDailyDate, '2026-10-07');
    });

    test('2 HD per day, 3rd denied, reset next IST day', () {
      var s = CreditState.initial(t0);
      s = spend(s, hd, t0);
      s = spend(s, hd, t0);
      expect(s.freeDaily, 0);
      expect(decideEnhance(s, hd, t0).reason, DenyReason.noCredits);
      // 23:59 IST same day: still nothing.
      final late = DateTime.utc(2026, 10, 7, 18, 29);
      expect(refreshState(s, late).freeDaily, 0);
      // 00:00 IST next day: back to 2.
      final next = DateTime.utc(2026, 10, 7, 18, 30);
      expect(refreshState(s, next).freeDaily, 2);
    });

    test('no rollover / stacking: unused 2 stay 2 after days pass', () {
      final s = CreditState.initial(t0);
      final later = t0.add(const Duration(days: 5));
      final r = refreshState(s, later);
      expect(r.freeDaily, 2);
      expect(r.freeDailyDate, istDate(later));
      // Refreshing twice the same day never adds.
      expect(refreshState(r, later).freeDaily, 2);
    });

    test('free daily credits only pay for HD', () {
      final s = CreditState.initial(t0);
      final d = decideEnhance(
        s,
        const EnhanceSpec(tier: QualityTier.fullHd),
        t0,
      );
      expect(d.allowed, isFalse);
      expect(d.reason, DenyReason.noCredits);
    });
  });

  group('cost depends only on quality', () {
    test('tier credits 1/2/4/8', () {
      expect(QualityTier.values.map((t) => t.credits), [1, 2, 4, 8]);
    });

    test('zoom does not change cost (Pro at 30x HD = 1 credit)', () {
      var s = applyPurchase(CreditState.initial(t0), kProMonthly, t0);
      s = s.copyWith(freeDaily: 0);
      final d = decideEnhance(
        s,
        const EnhanceSpec(tier: QualityTier.hd, zoom: 30, opticalLimit: 5),
        t0,
      );
      expect(d.credits, 1);
      expect(d.fromSub, 1);
    });

    test('pack pays Full HD for free user', () {
      var s = applyPurchase(
        CreditState.initial(t0),
        productById('pack_25')!,
        t0,
      );
      s = spend(s, const EnhanceSpec(tier: QualityTier.fullHd), t0);
      expect(s.packCredits, 23);
      expect(s.freeDaily, 2);
    });

    test('HD uses free first, then sub, then pack', () {
      var s = applyPurchase(CreditState.initial(t0), kProMonthly, t0);
      s = applyPurchase(s, productById('pack_25')!, t0);
      s = spend(s, hd, t0);
      s = spend(s, hd, t0);
      s = spend(s, hd, t0);
      expect([s.freeDaily, s.subCredits, s.packCredits], [0, 99, 25]);
      final d = decideEnhance(
        s.copyWith(subCredits: 1),
        const EnhanceSpec(tier: QualityTier.ultraHd),
        t0,
      );
      expect([d.fromSub, d.fromPack], [1, 3]);
    });
  });

  group('Pro gate above optical + starter trials', () {
    const highZoom = EnhanceSpec(
      tier: QualityTier.hd,
      zoom: 20,
      opticalLimit: 5,
    );

    test('at optical limit free user is fine (no trial burned)', () {
      final d = decideEnhance(
        CreditState.initial(t0),
        const EnhanceSpec(tier: QualityTier.hd, zoom: 5, opticalLimit: 5),
        t0,
      );
      expect(d.allowed, isTrue);
      expect(d.trials, isEmpty);
      expect(d.fromFree, 1);
    });

    test('high-zoom trial once, free; then Pro only', () {
      var s = CreditState.initial(t0);
      final d = decideEnhance(s, highZoom, t0);
      expect(d.trials, [StarterTrial.highZoom]);
      expect(d.credits, 0);
      s = applyDecision(s, d);
      expect(s.freeDaily, 2);
      expect(decideEnhance(s, highZoom, t0).reason, DenyReason.zoomNeedsPro);
      // Pro unlocks it (costs credits, no trial).
      s = applyPurchase(s, kProMonthly, t0);
      final p = decideEnhance(s, highZoom, t0);
      expect(p.allowed, isTrue);
      expect(p.trials, isEmpty);
    });

    test('decide alone never consumes (deduct only on success)', () {
      final s = CreditState.initial(t0);
      decideEnhance(s, highZoom, t0);
      decideEnhance(s, hd, t0);
      expect(s.trialsUsed, isEmpty);
      expect(s.freeDaily, 2);
    });

    test('Ultra HD / 4K trial once, then needs credits', () {
      var s = CreditState.initial(t0);
      const uhd = EnhanceSpec(tier: QualityTier.k4);
      s = spend(s, uhd, t0);
      expect(s.trialsUsed, {StarterTrial.premiumQuality});
      expect(decideEnhance(s, uhd, t0).reason, DenyReason.noCredits);
      s = applyPurchase(s, productById('pack_60')!, t0);
      s = spend(s, uhd, t0);
      expect(s.packCredits, 52);
    });

    test('library style + AI filter trials are independent', () {
      var s = CreditState.initial(t0);
      s = spend(
        s,
        const EnhanceSpec(tier: QualityTier.hd, libraryStyle: true),
        t0,
      );
      expect(
        decideEnhance(
          s,
          const EnhanceSpec(tier: QualityTier.hd, libraryStyle: true),
          t0,
        ).reason,
        DenyReason.styleNeedsPro,
      );
      s = spend(s, const EnhanceSpec(tier: QualityTier.hd, aiFilter: true), t0);
      expect(
        decideEnhance(
          s,
          const EnhanceSpec(tier: QualityTier.hd, aiFilter: true),
          t0,
        ).reason,
        DenyReason.filterNeedsPro,
      );
      expect(s.freeDaily, 2); // trials were free
      expect(s.trialsUsed.length, 2);
    });

    test('own prompt / custom style: Pro only', () {
      final s = CreditState.initial(t0);
      expect(
        decideEnhance(
          s,
          const EnhanceSpec(tier: QualityTier.hd, customPrompt: true),
          t0,
        ).reason,
        DenyReason.promptNeedsPro,
      );
      final pro = applyPurchase(s, kProMonthly, t0);
      expect(
        decideEnhance(
          pro,
          const EnhanceSpec(tier: QualityTier.hd, customStyle: true),
          t0,
        ).allowed,
        isTrue,
      );
    });
  });

  group('Pro subscription', () {
    test('100 credits / 30 days, expiry drops unused sub credits', () {
      var s = applyPurchase(CreditState.initial(t0), kProMonthly, t0);
      expect(s.isPro(t0), isTrue);
      expect(s.subCredits, 100);
      final after = t0.add(const Duration(days: 30, minutes: 1));
      s = refreshState(s, after);
      expect(s.isPro(after), isFalse);
      expect(s.subCredits, 0);
      expect(s.total(after), 2);
    });

    test(
      'early renewal extends period, credits reset to 100 (no rollover)',
      () {
        var s = applyPurchase(CreditState.initial(t0), kProMonthly, t0);
        s = s.copyWith(subCredits: 30);
        final mid = t0.add(const Duration(days: 10));
        s = applyPurchase(s, kProMonthly, mid);
        expect(s.subCredits, 100);
        expect(s.proUntil, t0.add(const Duration(days: 60)));
      },
    );

    test('packs stack and never expire', () {
      var s = CreditState.initial(t0);
      s = applyPurchase(s, productById('pack_25')!, t0);
      s = applyPurchase(s, productById('pack_140')!, t0);
      s = refreshState(s, t0.add(const Duration(days: 400)));
      expect(s.packCredits, 165);
    });

    test('JSON round trip', () {
      var s = applyPurchase(CreditState.initial(t0), kProMonthly, t0);
      s = applyDecision(
        s,
        decideEnhance(s, const EnhanceSpec(tier: QualityTier.hd), t0),
      );
      final back = CreditState.fromJson(s.toJson());
      expect(back.toJson(), s.toJson());
    });
  });
}
