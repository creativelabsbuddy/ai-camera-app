import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'account_service.dart';
import 'macro_fill.dart';
import 'mode_prompts.dart';
import 'openrouter_client.dart';
import 'server_api_client.dart';

/// v11.15 result of the step-photo check.
class PartResult {
  const PartResult({
    this.sameSubject,
    this.part = '',
    this.object = '',
    this.fill,
  });

  /// v11.32 how much of the step photo the subject fills.
  final FrameFill? fill;

  /// v11.22: still in the same place (in_scene); false = drift.
  final bool? sameSubject;
  final String part;

  /// v11.22: which known object the red box is on ('' = unknown).
  final String object;
  bool? get inScene => sameSubject;
}

/// v11.15 Macro subject detection: one cheap cloud vision call
/// (google/gemini-2.5-flash-lite) on the silent 1x photo, then one per
/// 2x/3x/4x step photo. Server URL set → server endpoint; else the test
/// key → OpenRouter direct. Never more than one call in flight; free.
class SubjectDetector {
  SubjectDetector({
    OpenRouterClient? openRouter,
    ServerApiClient? server,
    Future<String> Function()? serverUrl,
    Future<String> Function()? deviceId,
  }) : _openRouter = openRouter ?? OpenRouterClient(),
       _server = server ?? ServerApiClient(),
       _serverUrl = serverUrl ?? (() => AccountService.instance.serverUrl()),
       _deviceId = deviceId ?? (() => AccountService.instance.deviceId());

  final OpenRouterClient _openRouter;
  final ServerApiClient _server;
  final Future<String> Function() _serverUrl;
  final Future<String> Function() _deviceId;

  /// v11.24: the call that owns the detector. A cancelled / timed-out
  /// call loses ownership at once, so it never keeps the detector busy and
  /// its late result is dropped.
  Object? _owner;
  bool get busy => _owner != null;
  int _subjectGen = 0;
  String? _reasonAfterCancel;

  /// v11.21 test-build debug: why the last call gave nothing ('ok',
  /// 'timeout', 'http 401', 'empty (length)', 'busy', 'server …').
  String lastReason = '';

  /// v11.27 object / part of the last shutter spot reply.
  String? lastSpotObject;
  String? lastSpotPart;

  /// v11.29 'flash' / 'lite' (which model answered the spot).
  String lastSpotModel = '';

  /// v11.22: other visible objects from the last 1.5x detection.
  List<String> lastOthers = const [];

  /// v11.32 frame fill of the last subject detection (null = unknown).
  FrameFill? lastFill;

  String _direct(String name) {
    final r = _openRouter.lastDetectReason;
    return name.isNotEmpty ? 'ok' : (r.isEmpty || r == 'ok' ? 'empty' : r);
  }

  Future<T?> _guard<T>(Future<T?> Function() run) async {
    if (_owner != null) {
      lastReason = 'busy';
      return null; // one call in flight at most
    }
    final me = Object();
    _owner = me;
    try {
      final r = await run();
      return identical(_owner, me) ? r : null; // stale → ignored
    } catch (e) {
      if (identical(_owner, me)) lastReason = 'error ${e.runtimeType}';
      return null;
    } finally {
      if (identical(_owner, me)) {
        _owner = null;
      } else if (_owner == null && _reasonAfterCancel != null) {
        lastReason = _reasonAfterCancel!; // stale call must not overwrite
      }
    }
  }

  /// v11.24: drop the in-flight call (re-tap 1.5x, 1x, timeout). The
  /// detector is free immediately; the old result is ignored.
  void cancelInFlight([String reason = 'cancelled']) {
    _subjectGen++;
    if (_owner == null) return;
    _owner = null;
    lastReason = reason;
    _reasonAfterCancel = reason;
  }

  /// v11.24: the 1.5x subject call with ONE overall [timeout] covering
  /// photo prep + network. Single attempt (no retry). Starts fresh: any
  /// in-flight call is cancelled first. Null on failure / timeout / when
  /// cancelled meanwhile; [lastReason] says why.
  Future<String?> detectSubjectTimed(
    File photo, {
    Duration timeout = kDetectSubjectTimeout,
  }) async {
    cancelInFlight();
    _reasonAfterCancel = null;
    final gen = ++_subjectGen;
    try {
      final r = await detectSubject(photo).timeout(timeout);
      return gen == _subjectGen ? r : null;
    } on TimeoutException {
      if (gen == _subjectGen) cancelInFlight('timeout ${timeout.inSeconds}s');
      return null;
    }
  }

  /// Parent label (≤8 words) or null (busy / failure / empty reply).
  Future<String?> detectSubject(File oneX) => _guard(() async {
    final url = await _serverUrl();
    String name;
    if (url.isNotEmpty) {
      final j = await _server.macroDetect(
        baseUrl: url,
        deviceId: await _deviceId(),
        files: [('image', oneX)],
      );
      name = cleanDetected(j?['name'] as String?);
      lastFill = FrameFill.fromJson(j);
      final o = j?['others'];
      lastOthers = o is List
          ? o
                .map((e) => cleanDetected(e is String ? e : ''))
                .where((e) => e.isNotEmpty && e != name)
                .take(kDetectMaxOthers)
                .toList()
          : const [];
      lastReason = j == null ? 'server error' : (name.isEmpty ? 'empty' : 'ok');
    } else {
      final raw = await _openRouter.detectSubject(oneX);
      lastFill = FrameFill.parse(raw);
      final (main, others) = parseSubjectReply(raw);
      name = main;
      lastOthers = others;
      lastReason = _direct(name);
    }
    return name.isEmpty ? null : name;
  });

  /// v11.19 shutter spot (≤8 words) or null (busy / failure / empty).
  Future<String?> detectSpot(
    File overview,
    File closerBoxed,
    String? subject, {
    List<String> others = const [],
  }) => _guard(() async {
    lastSpotObject = null;
    lastSpotPart = null;
    lastSpotModel = '';
    final url = await _serverUrl();
    String spot;
    if (url.isNotEmpty) {
      final j = await _server.macroDetect(
        baseUrl: url,
        deviceId: await _deviceId(),
        files: [('overview', overview), ('closer', closerBoxed)],
        endpoint: 'spot',
        fields: {'subject': subject ?? '', 'others': jsonEncode(others)},
        timeout: kSpotTimeout,
      );
      lastSpotModel = (j?['model'] as String?) ?? '';
      spot = cleanDetected(
        j?['spot'] as String?,
        maxWords: kDetectMaxWords + 6,
      );
      lastSpotObject = j?['object'] as String?;
      lastSpotPart = j?['part'] as String?;
      lastReason = j == null ? 'server error' : (spot.isEmpty ? 'empty' : 'ok');
    } else {
      final (o, p, _) = parseObjectPartReply(
        await _openRouter.detectSpot(
          overview,
          closerBoxed,
          subject,
          others: others,
        ),
      );
      spot = spotText(o, p);
      lastSpotModel = _openRouter.lastSpotModel;
      lastSpotObject = o;
      lastSpotPart = p;
      lastReason = _direct(spot);
    }
    return spot.isEmpty ? null : spot;
  });

  /// v11.33 shutter: ONE check on the box area → description (whole
  /// object / several parts / one part + colour), or null when unclear,
  /// failed or over [timeout] (then nothing is charged).
  /// v11.49: [wide] = optional overview photo (sent first).
  Future<String?> detectBox(
    File box, {
    File? wide,
    Duration timeout = kSpotTimeout,
  }) async {
    cancelInFlight();
    _reasonAfterCancel = null;
    lastSpotModel = '';
    try {
      return await _guard(() async {
        final url = await _serverUrl();
        String d;
        bool clear;
        if (url.isNotEmpty) {
          final j = await _server.macroDetect(
            baseUrl: url,
            deviceId: await _deviceId(),
            files: [('image', box), if (wide != null) ('wide', wide)],
            endpoint: 'box',
            timeout: timeout,
          );
          lastSpotModel = (j?['model'] as String?) ?? '';
          d = cleanDetected(j?['spot'] as String?);
          clear = j?['clear'] == true && d.isNotEmpty;
          lastReason = j == null ? 'server error' : (clear ? 'ok' : 'unclear');
        } else {
          (d, clear) = parseBoxReply(
            await _openRouter.detectBox(box, wide: wide),
          );
          lastSpotModel = _openRouter.lastSpotModel;
          lastReason = clear ? 'ok' : (d.isEmpty ? _direct(d) : 'unclear');
        }
        // v11.49: only look / colour words → nothing found.
        if (clear && isVagueDetect(d)) {
          clear = false;
          lastReason = 'vague';
        }
        lastSpotPart = d;
        return clear ? d : null;
      }).timeout(timeout);
    } on TimeoutException {
      cancelInFlight('timeout ${timeout.inSeconds}s');
      return null;
    }
  }

  /// Which object + part is boxed, still in the scene? Null on failure.
  Future<PartResult?> detectPart(
    File oneX,
    File boxedStep,
    String parent, {
    List<String> others = const [],
  }) => _guard(() async {
    final url = await _serverUrl();
    String obj, part;
    bool? ins;
    FrameFill? fill;
    if (url.isNotEmpty) {
      final j = await _server.macroDetect(
        baseUrl: url,
        deviceId: await _deviceId(),
        files: [('one_x', oneX), ('step', boxedStep)],
        parent: parent,
        fields: {'others': jsonEncode(others)},
      );
      if (j == null) {
        lastReason = 'server error';
        return null;
      }
      final i = j['in_scene'] ?? j['same_subject'];
      ins = i is bool ? i : null;
      obj = cleanDetected(j['object'] as String?);
      part = cleanDetected(j['part'] as String?);
      fill = FrameFill.fromJson(j);
    } else {
      final raw = await _openRouter.detectPart(
        oneX,
        boxedStep,
        parent,
        others: others,
      );
      (obj, part, ins) = parseObjectPartReply(raw);
      fill = FrameFill.parse(raw);
    }
    if (ins == null && part.isEmpty && obj.isEmpty) {
      lastReason = url.isNotEmpty ? 'empty' : _direct('');
      return null;
    }
    lastReason = 'ok';
    return PartResult(sameSubject: ins, part: part, object: obj, fill: fill);
  });
}

/// v11.24: one overall limit for the 1.5x detection (prep + network).
const Duration kDetectSubjectTimeout = Duration(seconds: 8);

/// v11.21 small on-screen debug line (test builds only).
String detectDebugText(String reason) => 'detect: $reason';
