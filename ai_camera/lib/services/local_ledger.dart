import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/products.dart';
import 'entitlements.dart';

/// On-device credits ledger — the ONLY place local credit / trial state is
/// stored. Used when no enhance server URL is configured (TEST profile APK
/// with an embedded key, or offline). Same rules as the server
/// (entitlements.dart ⇄ enhance-server/ledger.py).
///
/// ⚠ Local state can be reset by clearing app data; production uses the
/// server ledger keyed by device id.
class LocalLedger {
  LocalLedger({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  static const prefsKey = 'local_ledger_v1';

  final DateTime Function() _clock;

  DateTime get now => _clock();

  Future<CreditState> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(prefsKey);
    CreditState s;
    if (raw == null || raw.isEmpty) {
      s = CreditState.initial(now);
    } else {
      try {
        s = CreditState.fromJson(
          (jsonDecode(raw) as Map).cast<String, Object?>(),
        );
      } catch (_) {
        s = CreditState.initial(now);
      }
    }
    final refreshed = refreshState(s, now);
    if (raw == null || jsonEncode(refreshed.toJson()) != raw) {
      await _save(prefs, refreshed);
    }
    return refreshed;
  }

  Future<EnhanceDecision> decide(EnhanceSpec spec) async =>
      decideEnhance(await load(), spec, now);

  /// Commit after a SUCCESSFUL AI result only. Re-decides against the latest
  /// state so a concurrent change can never overdraw.
  Future<CreditState> commit(EnhanceSpec spec) async {
    final s = await load();
    final d = decideEnhance(s, spec, now);
    if (!d.allowed) return s;
    final next = applyDecision(s, d);
    await _save(await SharedPreferences.getInstance(), next);
    return next;
  }

  Future<EnhanceDecision> decideLookSpec(LookSpec spec) async =>
      decideLook(await load(), spec, now);

  /// Commit a SUCCESSFUL look (style apply / custom change). Returns the new
  /// state and what was actually charged.
  Future<(CreditState, EnhanceDecision)> commitLook(LookSpec spec) async {
    final s = await load();
    final d = decideLook(s, spec, now);
    if (!d.allowed) return (s, d);
    final next = applyDecision(s, d);
    await _save(await SharedPreferences.getInstance(), next);
    return (next, d);
  }

  Future<CreditState> purchase(Product p) async {
    final next = applyPurchase(await load(), p, now);
    await _save(await SharedPreferences.getInstance(), next);
    return next;
  }

  /// Settings → "reset test ledger" (local test builds only).
  Future<CreditState> resetForTesting() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(prefsKey);
    return load();
  }

  Future<void> _save(SharedPreferences prefs, CreditState s) =>
      prefs.setString(prefsKey, jsonEncode(s.toJson()));
}
