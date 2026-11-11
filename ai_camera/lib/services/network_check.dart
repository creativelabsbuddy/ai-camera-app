import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'ai_call.dart';

/// v11.59 exact English offline message (Pro AI shutter, enhance, styles,
/// custom, video).
const String kCheckInternet = kCheckInternetMessage;

/// Whole precheck budget: every probe runs in parallel, the first success
/// wins; nothing answers within this → offline.
const Duration kNetProbeTimeout = Duration(milliseconds: 1800);

/// A positive answer is reused this long (no lag on the next shutter).
const Duration kNetOnlineTtl = Duration(seconds: 20);

/// While an AI call runs: probe this often; [kNetLostAfter] failures in a
/// row = connection lost → the call is cancelled (nothing charged).
const Duration kNetWatchEvery = Duration(seconds: 4);
const int kNetLostAfter = 2;

/// One reachability probe: true when it reached the internet.
typedef NetProbe = Future<bool> Function(Duration timeout);

/// TCP connect (DNS + route + handshake of the TCP layer). A Wi-Fi link
/// without internet fails here; an OS DNS cache alone cannot pass it.
NetProbe tcpProbe(String host, int port) => (t) async {
  Socket? s;
  try {
    s = await Socket.connect(host, port, timeout: t);
    return true;
  } catch (_) {
    return false;
  } finally {
    s?.destroy();
  }
};

/// Several independent endpoints (AI host by name, two public resolvers
/// by IP) — not one fragile third-party probe.
List<NetProbe> defaultProbes({String? serverHost}) => [
  tcpProbe('openrouter.ai', 443),
  tcpProbe('1.1.1.1', 443),
  tcpProbe('8.8.8.8', 443),
  if (serverHost != null && serverHost.isNotEmpty) tcpProbe(serverHost, 443),
];

/// Short, bounded internet check (not just "Wi-Fi connected").
class NetworkCheck {
  NetworkCheck({List<NetProbe>? probes, DateTime Function()? clock})
    : _probes = probes,
      _injected = probes != null,
      _clock = clock ?? DateTime.now;

  static NetworkCheck instance = NetworkCheck();

  List<NetProbe>? _probes;
  final bool _injected;
  final DateTime Function() _clock;
  DateTime? _okAt;
  Future<bool>? _inFlight;
  String? _serverHost;

  /// AI server host (Settings URL), probed too when set.
  set serverHost(String? h) {
    if (h == _serverHost) return;
    _serverHost = h;
    if (!_injected) _probes = null;
  }

  List<NetProbe> get _list =>
      _probes ??= defaultProbes(serverHost: _serverHost);

  /// Last positive answer still fresh?
  bool get recentlyOnline {
    final t = _okAt;
    return t != null && _clock().difference(t) < kNetOnlineTtl;
  }

  void markOffline() => _okAt = null;

  /// True when any probe reaches the internet within [timeout].
  Future<bool> online({
    Duration timeout = kNetProbeTimeout,
    bool fresh = false,
  }) {
    if (!fresh && recentlyOnline) return Future.value(true);
    return _inFlight ??= _probe(timeout).whenComplete(() => _inFlight = null);
  }

  Future<bool> _probe(Duration timeout) async {
    final probes = _list;
    if (probes.isEmpty) return true;
    final done = Completer<bool>();
    var left = probes.length;
    for (final p in probes) {
      p(timeout).then(
        (ok) {
          if (ok && !done.isCompleted) done.complete(true);
          if (--left == 0 && !done.isCompleted) done.complete(false);
        },
        onError: (_) {
          if (--left == 0 && !done.isCompleted) done.complete(false);
        },
      );
    }
    final ok = await done.future.timeout(
      timeout + const Duration(milliseconds: 200),
      onTimeout: () => false,
    );
    if (ok) {
      _okAt = _clock();
    } else {
      _okAt = null;
    }
    return ok;
  }
}

/// DNS / socket / TLS / closed-connection errors = no internet (not a
/// provider error such as HTTP 5xx or a refusal).
bool isOfflineError(Object e) {
  if (e is OfflineException) return true;
  if (e is SocketException) return true;
  if (e is HandshakeException) return true;
  if (e is HttpException) return true;
  if (e is http.ClientException) {
    final m = e.message.toLowerCase();
    return m.contains('socket') ||
        m.contains('host lookup') ||
        m.contains('network') ||
        m.contains('connection');
  }
  if (e is AiFailure) return e.kind == AiFailureKind.network;
  return false;
}

/// Thrown when the connection was lost while an AI call was running.
class OfflineException implements Exception {
  const OfflineException();
  @override
  String toString() => kCheckInternet;
}

/// Runs [body] with a child cancel token; while it runs the network is
/// probed every [every]; [lostAfter] failed probes in a row cancel the call
/// and throw [OfflineException]. A cancel of [parent] still cancels.
Future<T> watchNetwork<T>(
  Future<T> Function(AiCancelToken token) body, {
  AiCancelToken? parent,
  NetworkCheck? net,
  Duration every = kNetWatchEvery,
  int lostAfter = kNetLostAfter,
}) async {
  final n = net ?? NetworkCheck.instance;
  final child = AiCancelToken();
  parent?.onCancel(child.cancel);
  final lostC = Completer<T>();
  var lost = false;
  var misses = 0;
  var probing = false;
  final timer = Timer.periodic(every, (t) async {
    if (probing || child.isCancelled) return;
    probing = true;
    try {
      final ok = await n.online(fresh: true);
      if (!t.isActive) return;
      misses = ok ? 0 : misses + 1;
      if (misses >= lostAfter) {
        lost = true;
        t.cancel();
        n.markOffline();
        debugPrint('Network lost during AI call → cancelled');
        child.cancel();
        // Bounded: the caller is released NOW even if the request hangs.
        if (!lostC.isCompleted) lostC.completeError(const OfflineException());
      }
    } finally {
      probing = false;
    }
  });
  try {
    final bf = body(child);
    // A late error of an abandoned (lost) request is not unhandled.
    unawaited(bf.then((_) {}, onError: (_) {}));
    final r = await Future.any([bf, lostC.future]);
    if (lost) throw const OfflineException();
    return r;
  } catch (e) {
    if (lost) throw const OfflineException();
    rethrow;
  } finally {
    timer.cancel();
  }
}
