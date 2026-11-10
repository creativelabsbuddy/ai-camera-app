import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/ai_config.dart';
import '../models/products.dart';
import 'enhance_settings.dart';
import 'entitlements.dart';
import 'local_ledger.dart';
import 'server_api_client.dart';

/// Where credits / trials are tracked for this install.
enum AccountBackend {
  /// enhance-server (Settings URL): key + ledger server-side. Production.
  server,

  /// LocalLedger on the phone (TEST APK with embedded key / no server).
  local,
}

/// App-wide account facade: device id, credit balance, Pro status, starter
/// trials, purchases. UI listens to [state].
class AccountService {
  AccountService._({
    LocalLedger? ledger,
    ServerApiClient? server,
    EnhanceSettings? settings,
  }) : ledger = ledger ?? LocalLedger(),
       _server = server ?? ServerApiClient(),
       _settings = settings ?? EnhanceSettings();

  static AccountService instance = AccountService._();

  /// Tests: swap in a fresh instance (e.g. with a fake clock).
  @visibleForTesting
  static void resetForTest({LocalLedger? ledger, ServerApiClient? server}) {
    instance = AccountService._(ledger: ledger, server: server);
  }

  static const _deviceChannel = MethodChannel('ai_camera/device');
  static const _deviceIdKey = 'device_id_v1';
  static const _cacheKey = 'account_cache_v1';

  final LocalLedger ledger;
  final ServerApiClient _server;
  final EnhanceSettings _settings;

  /// Latest known state (null until first load).
  final ValueNotifier<CreditState?> state = ValueNotifier(null);
  final ValueNotifier<AccountBackend> backend = ValueNotifier(
    AccountBackend.local,
  );

  /// Last server error (shown in Settings), null when fine.
  String? lastError;
  String? _deviceId;

  DateTime get now => ledger.now;

  Future<String> serverUrl() => _settings.getServerUrl();

  /// AI is possible at all (server URL or embedded test key).
  Future<bool> aiAvailable() async =>
      (await serverUrl()).isNotEmpty || AiConfig.hasEmbeddedApiKey;

  Future<String> deviceId() async {
    if (_deviceId != null) return _deviceId!;
    String? id;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        id = await _deviceChannel.invokeMethod<String>('getDeviceId');
      } catch (_) {}
    }
    final prefs = await SharedPreferences.getInstance();
    if (id == null || id.isEmpty) {
      id = prefs.getString(_deviceIdKey);
      if (id == null || id.isEmpty) {
        final r = math.Random.secure();
        id = List.generate(
          16,
          (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
        await prefs.setString(_deviceIdKey, id);
      }
    } else {
      id = 'a_$id';
    }
    return _deviceId = id;
  }

  /// Loads the current state from the active backend. Server failures fall
  /// back to the cached server state (never to local credits).
  Future<CreditState> refresh() async {
    final url = await serverUrl();
    if (url.isEmpty) {
      backend.value = AccountBackend.local;
      final s = await ledger.load();
      lastError = null;
      state.value = s;
      return s;
    }
    backend.value = AccountBackend.server;
    try {
      final s = await _server.account(url, await deviceId());
      lastError = null;
      await _cache(s);
      state.value = s;
      return s;
    } catch (e) {
      lastError = '$e';
      final cached = await _cached();
      final s = refreshState(cached ?? CreditState.initial(now), now);
      state.value = s;
      return s;
    }
  }

  /// Client-side check with the same rules the server/ledger enforce.
  Future<EnhanceDecision> precheck(EnhanceSpec spec) async {
    final s = state.value ?? await refresh();
    return decideEnhance(refreshState(s, now), spec, now);
  }

  /// Called by EnhanceService after a successful AI result.
  Future<void> onServerResult(CreditState? s) async {
    if (s != null) {
      await _cache(s);
      state.value = s;
    } else {
      await refresh();
    }
  }

  Future<void> commitLocal(EnhanceSpec spec) async {
    state.value = await ledger.commit(spec);
  }

  /// Client-side look check (style apply / custom change), same rules as
  /// the server.
  Future<EnhanceDecision> precheckLook(LookSpec spec) async {
    final s = state.value ?? await refresh();
    return decideLook(refreshState(s, now), spec, now);
  }

  /// Local (test-key) look commit after success; returns what was charged.
  Future<EnhanceDecision> commitLocalLook(LookSpec spec) async {
    final (s, d) = await ledger.commitLook(spec);
    state.value = s;
    return d;
  }

  /// Grants a purchase on the active backend (called by BillingService after
  /// the store confirmed payment — or immediately in TEST MODE).
  Future<CreditState> grantPurchase(Product p) async {
    final url = await serverUrl();
    if (url.isEmpty) {
      final s = await ledger.purchase(p);
      state.value = s;
      return s;
    }
    final s = await _server.purchase(url, await deviceId(), p.id);
    await _cache(s);
    state.value = s;
    return s;
  }

  Future<void> _cache(CreditState s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheKey, jsonEncode(s.toJson()));
  }

  Future<CreditState?> _cached() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cacheKey);
    if (raw == null) return null;
    try {
      return CreditState.fromJson(
        (jsonDecode(raw) as Map).cast<String, Object?>(),
      );
    } catch (_) {
      return null;
    }
  }
}
