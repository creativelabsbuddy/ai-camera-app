import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/ai_config.dart';
import 'account_service.dart';
import 'entitlements.dart';
import 'server_api_client.dart' show decodeAccountBlob;
import 'video_notifier.dart';

/// v11.53 AI video: 8scale Wan 2.2 14B for ≤5 s, Phosor MiniMax H3 Turbo for
/// longer clips. Key TEST builds call the providers directly (like the image
/// AI); server builds go through `/v1/video/*`. Credits are charged only when
/// a video is delivered.
enum VideoProvider { wan, minimax }

enum VideoKind { t2v, i2v }

const kWanSeconds = [5];
const kVideoLengths = [5, 8, 10, 15]; // 5 = Wan, longer = MiniMax
const kWanResolutions = ['480p', '580p', '720p'];
const kMiniMaxResolutions = ['480p', '768p'];
const kVideoAspects = ['9:16', '16:9'];
const kMiniMaxLabel = 'MiniMax H3';

/// v11.58: the user-facing chip on AI videos (replaces the model chip).
const kAiGeneratedLabel = 'AI-generated';

/// v11.58: a video that is not ready after this long is given up and its
/// credits refunded (nothing is charged before delivery).
const kVideoTimeout = Duration(minutes: 30);
const kVideoTimeoutMessage =
    'No video after 30 min. Your credits were refunded. Please try again later.';

/// v11.58: wait note shown while a longer (MiniMax) video is made.
const kLongVideoWaitNote = 'Usually ready in 15–20 min';

// Provider cost (₹, $1 = ₹95) → PROVISIONAL credits =
// ceil(cost × 1.5 / ₹0.99). Same numbers as the server; admin can override.
const _wanCost5s = {'480p': 1.43, '580p': 2.28, '720p': 4.18};
const _mmCostPerS = {'480p': 0.57, '768p': 0.855};

int _prov(double inr) => math.max(1, (inr * 1.5 / 0.99 - 1e-9).ceil());

/// Provisional credit table, keyed like the server (`wan_5_480p`).
Map<String, int> defaultVideoCredits() => {
  for (final r in kWanResolutions)
    for (final s in [3, 5]) 'wan_${s}_$r': _prov(_wanCost5s[r]! * s / 5),
  for (final r in kMiniMaxResolutions)
    for (final s in [6, 8, 10, 15]) 'minimax_${s}_$r': _prov(_mmCostPerS[r]! * s),
};

VideoProvider providerFor(int seconds) =>
    seconds <= 5 ? VideoProvider.wan : VideoProvider.minimax;

List<String> resolutionsFor(int seconds) =>
    providerFor(seconds) == VideoProvider.wan ? kWanResolutions : kMiniMaxResolutions;

class VideoRequest {
  const VideoRequest({
    required this.kind,
    required this.prompt,
    this.seconds = 5,
    this.resolution = '480p',
    this.aspect = '9:16',
    this.image,
    this.styleId,
  });

  final VideoKind kind;
  final String prompt;
  final int seconds;
  final String resolution;
  final String aspect;
  final File? image;
  final String? styleId;

  VideoProvider get provider => providerFor(seconds);
  String get creditKey => '${provider.name}_${seconds}_$resolution';
  bool get isMiniMax => provider == VideoProvider.minimax;

  String? validate() {
    if (prompt.trim().isEmpty) return 'Describe the video';
    if (kind == VideoKind.i2v && image == null) return 'Choose a photo';
    if (!kVideoLengths.contains(seconds)) return 'Unsupported length';
    if (!resolutionsFor(seconds).contains(resolution)) return 'Unsupported resolution';
    if (!kVideoAspects.contains(aspect)) return 'Unsupported aspect ratio';
    if (isMiniMax && !AiConfig.minimaxEnabled) return 'Videos longer than 5 s are not available';
    return null;
  }
}

enum VideoPhase { submitting, queued, running, downloading, done, failed, cancelled }

@immutable
class VideoJob {
  const VideoJob({
    required this.request,
    required this.phase,
    required this.started,
    required this.credits,
    this.jobId,
    this.file,
    this.error,
    this.creditsCharged = 0,
  });

  final VideoRequest request;
  final VideoPhase phase;
  final DateTime started;
  final int credits;
  final String? jobId;
  final File? file;
  final String? error;
  final int creditsCharged;

  bool get active =>
      phase != VideoPhase.done && phase != VideoPhase.failed && phase != VideoPhase.cancelled;
  String get modelLabel => request.isMiniMax ? kMiniMaxLabel : 'Wan 2.2';

  VideoJob copy({VideoPhase? phase, String? jobId, File? file, String? error, int? creditsCharged}) =>
      VideoJob(
        request: request,
        phase: phase ?? this.phase,
        started: started,
        credits: credits,
        jobId: jobId ?? this.jobId,
        file: file ?? this.file,
        error: error ?? this.error,
        creditsCharged: creditsCharged ?? this.creditsCharged,
      );
}

class VideoException implements Exception {
  VideoException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Provider status, normalised.
class VideoStatus {
  const VideoStatus(this.state, {this.url, this.error, this.account, this.charged = 0});
  final String state; // queued | running | done | failed
  final String? url;
  final String? error;
  final CreditState? account;
  final int charged;
}

abstract class VideoBackend {
  /// Local = key test build: the app charges its own ledger on success.
  bool get chargesLocally;
  Future<String> submit(VideoRequest r);
  Future<VideoStatus> status(String jobId);
  Future<void> cancel(String jobId);
}

String _redact(String s) {
  for (final k in [AiConfig.videoApiKey, AiConfig.phosorApiKey]) {
    if (k.isNotEmpty) s = s.replaceAll(k, '<redacted>');
  }
  s = s.replaceAll(RegExp(r'\s+'), ' ');
  return s.length > 200 ? s.substring(0, 200) : s;
}

String? findVideoUrl(Object? j) {
  if (j is String) return j.startsWith('http') ? j : null;
  if (j is Map) {
    for (final k in ['video_url', 'url', 'output', 'video', 'result', 'data']) {
      if (j.containsKey(k)) {
        final u = findVideoUrl(j[k]);
        if (u != null) return u;
      }
    }
  }
  if (j is List) {
    for (final x in j) {
      final u = findVideoUrl(x);
      if (u != null) return u;
    }
  }
  return null;
}

const _done = {'completed', 'succeeded', 'success', 'done'};
const _failed = {'failed', 'error', 'cancelled', 'canceled'};

/// Key test build: calls 8scale / Phosor directly. Job id = `provider~rid`.
class DirectVideoBackend implements VideoBackend {
  DirectVideoBackend({http.Client? client}) : _http = client ?? http.Client();
  final http.Client _http;
  static const _t = Duration(seconds: 60);

  @override
  bool get chargesLocally => true;

  Map<String, String> _h(VideoProvider p) => p == VideoProvider.wan
      ? {'Authorization': 'Bearer ${AiConfig.videoApiKey}'}
      : {'X-API-Key': AiConfig.phosorApiKey};

  static bool configured(VideoProvider p) => p == VideoProvider.wan
      ? AiConfig.videoApiKey.isNotEmpty
      : AiConfig.phosorApiKey.isNotEmpty;

  VideoException _fail(String what, http.Response r) {
    var msg = r.body;
    try {
      final j = jsonDecode(r.body);
      if (j is Map) msg = '${j['detail'] ?? j['error'] ?? j['message'] ?? j}';
    } catch (_) {}
    if (r.statusCode == 402) return VideoException('$what: provider balance too low (${_redact(msg)})');
    return VideoException('$what failed (HTTP ${r.statusCode}): ${_redact(msg)}');
  }

  @override
  Future<String> submit(VideoRequest r) async {
    final p = r.provider;
    String? rid;
    try {
      if (p == VideoProvider.wan) {
        final body = <String, Object?>{
          'prompt': r.prompt,
          'resolution': r.resolution,
          'aspect_ratio': r.aspect,
          'seconds': r.seconds,
        };
        var path = '/wan-2.2/14b/text-to-video';
        if (r.kind == VideoKind.i2v) {
          body['image'] = 'data:image/jpeg;base64,${base64Encode(await r.image!.readAsBytes())}';
          path = '/wan-2.2/14b/image-to-video';
        }
        final res = await _http
            .post(Uri.parse('${AiConfig.wanBaseUrl}$path'),
                headers: {..._h(p), 'Content-Type': 'application/json'}, body: jsonEncode(body))
            .timeout(_t);
        if (res.statusCode >= 400) throw _fail('Wan 2.2 submit', res);
        final j = (jsonDecode(res.body) as Map);
        rid = '${j['requestId'] ?? j['request_id'] ?? j['id'] ?? ''}';
      } else {
        final body = <String, Object?>{
          'prompt': r.prompt,
          'resolution_tier': r.resolution,
          'aspect_ratio': r.aspect,
          'duration': r.seconds,
          'model': 'minimax/h3/${r.kind == VideoKind.i2v ? 'image' : 'text'}-to-video/turbo',
        };
        if (r.kind == VideoKind.i2v) body['image_url'] = await _upload(r.image!);
        final res = await _http
            .post(Uri.parse('${AiConfig.phosorBaseUrl}/inference/submit'),
                headers: {..._h(p), 'Content-Type': 'application/json'}, body: jsonEncode(body))
            .timeout(_t);
        if (res.statusCode >= 400) throw _fail('MiniMax submit', res);
        final j = (jsonDecode(res.body) as Map);
        rid = '${j['request_id'] ?? j['id'] ?? ''}';
      }
    } on TimeoutException {
      // Never resubmit: the job may exist and be billed.
      throw VideoException('The video service timed out — not retried');
    }
    if (rid.isEmpty || rid == 'null') throw VideoException('The video service returned no job');
    return '${p.name}~$rid';
  }

  Future<String> _upload(File f) async {
    for (final path in ['/storage/image/upload', '/storage/upload_image']) {
      final req = http.MultipartRequest('POST', Uri.parse('${AiConfig.phosorBaseUrl}$path'))
        ..headers.addAll(_h(VideoProvider.minimax))
        ..files.add(await http.MultipartFile.fromPath('image', f.path, filename: 'photo.jpg'));
      final res = await http.Response.fromStream(await _http.send(req).timeout(_t));
      if (res.statusCode == 404) continue;
      if (res.statusCode >= 400) throw _fail('MiniMax image upload', res);
      final j = jsonDecode(res.body) as Map;
      final u = j['s3_url'] ?? j['url'];
      if (u is String && u.isNotEmpty) return u;
      throw VideoException('MiniMax image upload returned no URL');
    }
    throw VideoException('MiniMax image upload not available');
  }

  (VideoProvider, String) _parse(String id) {
    final i = id.indexOf('~');
    return (VideoProvider.values.byName(id.substring(0, i)), id.substring(i + 1));
  }

  @override
  Future<VideoStatus> status(String jobId) async {
    final (p, rid) = _parse(jobId);
    final url = p == VideoProvider.wan
        ? '${AiConfig.wanBaseUrl}/status/$rid'
        : '${AiConfig.phosorBaseUrl}/inference/status/$rid';
    final res = await _http.get(Uri.parse(url), headers: _h(p)).timeout(_t);
    if (res.statusCode >= 400) throw _fail('Status', res);
    final j = jsonDecode(res.body);
    final st = '${j is Map ? j['status'] : ''}'.toLowerCase();
    if (_failed.contains(st)) {
      return VideoStatus('failed', error: _redact('${(j as Map)['error'] ?? j['message'] ?? st}'));
    }
    if (!_done.contains(st)) {
      return VideoStatus(const {'in_queue', 'queued', 'pending'}.contains(st) ? 'queued' : 'running');
    }
    var u = findVideoUrl(j);
    if (u == null && p == VideoProvider.minimax) {
      final rr = await _http
          .get(Uri.parse('${AiConfig.phosorBaseUrl}/inference/result/$rid'), headers: _h(p))
          .timeout(_t);
      // v11.58: Phosor answers 202 while the result is not published yet
      // (status can say "completed" a moment before) → keep polling.
      if (rr.statusCode == 202) return const VideoStatus('running');
      if (rr.statusCode >= 400) throw _fail('Result', rr);
      u = findVideoUrl(jsonDecode(rr.body));
      if (u == null) return const VideoStatus('running');
    }
    return u == null
        ? const VideoStatus('failed', error: 'The video service returned no video')
        : VideoStatus('done', url: u);
  }

  @override
  Future<void> cancel(String jobId) async {
    final (p, rid) = _parse(jobId);
    if (p != VideoProvider.wan) return;
    try {
      await _http
          .post(Uri.parse('${AiConfig.wanBaseUrl}/cancel/$rid'), headers: _h(p))
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }
}

/// Server build: `/v1/video/*` (server charges once on delivery).
class ServerVideoBackend implements VideoBackend {
  ServerVideoBackend(this.baseUrl, this.deviceId, {http.Client? client})
    : _http = client ?? http.Client();
  final String baseUrl;
  final String deviceId;
  final http.Client _http;

  @override
  bool get chargesLocally => false;

  String get _root => baseUrl.replaceAll(RegExp(r'/+$'), '');

  VideoException _fail(http.Response r) {
    var msg = r.body;
    try {
      final j = jsonDecode(r.body);
      if (j is Map && j['detail'] != null) msg = '${j['detail']}';
    } catch (_) {}
    if (r.statusCode == 402) return VideoException('Not enough credits for this video');
    return VideoException(_redact('Video failed (HTTP ${r.statusCode}): $msg'));
  }

  @override
  Future<String> submit(VideoRequest r) async {
    final req = http.MultipartRequest('POST', Uri.parse('$_root/v1/video/generate'))
      ..fields.addAll({
        'device_id': deviceId,
        'prompt': r.prompt,
        'kind': r.kind.name,
        'seconds': '${r.seconds}',
        'resolution': r.resolution,
        'aspect_ratio': r.aspect,
        if (r.styleId != null) 'style_id': r.styleId!,
      });
    if (r.kind == VideoKind.i2v) {
      req.files.add(await http.MultipartFile.fromPath('image', r.image!.path, filename: 'photo.jpg'));
    }
    final res = await http.Response.fromStream(
      await _http.send(req).timeout(const Duration(seconds: 90)),
    );
    if (res.statusCode != 200) throw _fail(res);
    return '${(jsonDecode(res.body) as Map)['job_id']}';
  }

  @override
  Future<VideoStatus> status(String jobId) async {
    final res = await _http
        .get(Uri.parse('$_root/v1/video/status/${Uri.encodeComponent(jobId)}?device_id=$deviceId'))
        .timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) throw _fail(res);
    final j = (jsonDecode(res.body) as Map).cast<String, Object?>();
    CreditState? acc;
    final a = j['account'];
    if (a is String) acc = decodeAccountBlob(a);
    if (a is Map) {
      try {
        final m = a['state'] is Map ? a['state'] as Map : a;
        acc = CreditState.fromJson(m.cast<String, Object?>());
      } catch (_) {}
    }
    return VideoStatus(
      '${j['status']}',
      url: j['video_url'] as String?,
      error: j['error'] as String?,
      account: acc,
      charged: (j['credits_charged'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<void> cancel(String jobId) async {
    try {
      await _http
          .post(Uri.parse('$_root/v1/video/cancel/${Uri.encodeComponent(jobId)}'),
              body: {'device_id': deviceId})
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }
}

/// Runs one video at a time in the background so the user can leave the
/// video screen and come back (the job keeps polling; a pending job is also
/// saved and resumed after an app restart).
class VideoService {
  VideoService({
    Future<VideoBackend?> Function(VideoProvider p)? backend,
    Future<File> Function(String url)? download,
    this.pollEvery = const Duration(seconds: 4),
    this.maxWait = kVideoTimeout,
  }) : _backendFor = backend ?? _defaultBackend,
       _download = download ?? _defaultDownload;

  static VideoService instance = VideoService();
  static void resetForTest(VideoService s) => instance = s;

  final Future<VideoBackend?> Function(VideoProvider p) _backendFor;
  final Future<File> Function(String url) _download;
  final Duration pollEvery;
  final Duration maxWait;

  final ValueNotifier<VideoJob?> job = ValueNotifier(null);

  /// Credits table (provisional defaults ← server `/v1/video/options`).
  final ValueNotifier<Map<String, int>> credits = ValueNotifier(defaultVideoCredits());

  int creditsFor(VideoRequest r) => credits.value[r.creditKey] ?? 0;
  int creditsForKey(int seconds, String res) =>
      credits.value['${providerFor(seconds).name}_${seconds}_$res'] ?? 0;

  bool _cancelled = false;
  static const _pendingKey = 'video_pending_v1';

  static Future<VideoBackend?> _defaultBackend(VideoProvider p) async {
    if (DirectVideoBackend.configured(p)) return DirectVideoBackend();
    final url = (await AccountService.instance.serverUrl()).trim();
    if (url.isEmpty) return null;
    return ServerVideoBackend(url, await AccountService.instance.deviceId());
  }

  static Future<File> _defaultDownload(String url) async {
    final r = await http.get(Uri.parse(url)).timeout(const Duration(minutes: 3));
    if (r.statusCode != 200 || r.bodyBytes.isEmpty) {
      throw VideoException('Could not download the video (HTTP ${r.statusCode})');
    }
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/ai_video_${DateTime.now().millisecondsSinceEpoch}.mp4');
    await f.writeAsBytes(r.bodyBytes, flush: true);
    return f;
  }

  /// Server options (admin-edited credits). Silent on failure.
  Future<void> refreshOptions() async {
    try {
      final url = (await AccountService.instance.serverUrl()).trim();
      if (url.isEmpty) return;
      final r = await http
          .get(Uri.parse('${url.replaceAll(RegExp(r'/+$'), '')}/v1/video/options'))
          .timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return;
      final c = (jsonDecode(r.body) as Map)['credits'];
      if (c is Map) {
        credits.value = {
          ...defaultVideoCredits(),
          for (final e in c.entries)
            if (e.value is num) '${e.key}': (e.value as num).toInt(),
        };
      }
    } catch (_) {}
  }

  /// Credit precheck (local ledger mirror) — null if allowed.
  Future<String?> precheck(VideoRequest r) async {
    final d = await AccountService.instance.precheckLook(_spec(creditsFor(r)));
    return d.allowed ? null : denyMessage(d.reason ?? DenyReason.noCredits);
  }

  LookSpec _spec(int c) => LookSpec(creditCost: c, isStyle: false, allowTrial: false);

  /// Starts a video (one at a time). Errors land in [job] as failed.
  Future<void> start(VideoRequest r) async {
    if (job.value?.active == true) throw VideoException('A video is already being made');
    final bad = r.validate();
    if (bad != null) throw VideoException(bad);
    final be = await _backendFor(r.provider);
    if (be == null) throw VideoException('AI video is not set up in this build');
    _cancelled = false;
    unawaited(VideoNotifier.instance.requestPermission());
    job.value = VideoJob(
      request: r,
      phase: VideoPhase.submitting,
      started: DateTime.now(),
      credits: creditsFor(r),
    );
    unawaited(_run(be));
  }

  Future<void> _run(VideoBackend be, {String? resumeId}) async {
    var j = job.value!;
    try {
      final id = resumeId ?? await be.submit(j.request);
      if (_cancelled) {
        await be.cancel(id);
        return;
      }
      job.value = j = j.copy(phase: VideoPhase.queued, jobId: id);
      await _savePending(j);
      // v11.58: 30 min from the start (also across an app restart).
      final deadline = j.started.add(maxWait);
      while (true) {
        await Future<void>.delayed(pollEvery);
        if (_cancelled) return;
        if (DateTime.now().isAfter(deadline)) {
          await be.cancel(id);
          throw VideoException(kVideoTimeoutMessage);
        }
        VideoStatus st;
        try {
          st = await be.status(id);
        } on VideoException {
          rethrow;
        } catch (_) {
          continue; // transient network error: keep polling
        }
        if (_cancelled) return;
        if (st.state == 'failed') {
          throw VideoException(st.error?.isNotEmpty == true ? st.error! : 'The video failed');
        }
        if (st.state != 'done') {
          final ph = st.state == 'queued' ? VideoPhase.queued : VideoPhase.running;
          if (ph != j.phase) job.value = j = j.copy(phase: ph);
          continue;
        }
        job.value = j = j.copy(phase: VideoPhase.downloading);
        final f = await _download(st.url!);
        var charged = st.charged;
        if (be.chargesLocally) {
          // Delivered → charge now (never before success).
          final d = await AccountService.instance.commitLocalLook(_spec(j.credits));
          charged = d.allowed ? d.credits : 0;
        } else if (st.account != null) {
          await AccountService.instance.onServerResult(st.account);
        }
        if (_cancelled) return;
        job.value = j.copy(phase: VideoPhase.done, file: f, creditsCharged: charged);
        await _clearPending();
        unawaited(VideoNotifier.instance.show('Your AI video is ready', 'Tap to open AI Camera and watch it.'));
        return;
      }
    } catch (e) {
      if (_cancelled) return;
      final msg = e is VideoException ? e.message : _redact('$e');
      job.value = j.copy(phase: VideoPhase.failed, error: msg);
      await _clearPending();
      unawaited(VideoNotifier.instance.show(
        'Your AI video could not be made',
        msg == kVideoTimeoutMessage ? msg : 'No credits were used. Please try again.',
      ));
    }
  }

  /// Stops waiting; cancels at the provider when possible. Never charges.
  Future<void> cancel() async {
    final j = job.value;
    if (j == null || !j.active) return;
    _cancelled = true;
    job.value = j.copy(phase: VideoPhase.cancelled);
    await _clearPending();
    final id = j.jobId;
    if (id != null) {
      final be = await _backendFor(j.request.provider);
      await be?.cancel(id);
    }
  }

  void dismiss() {
    if (job.value?.active != true) job.value = null;
  }

  Future<void> _savePending(VideoJob j) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
        _pendingKey,
        jsonEncode({
          'id': j.jobId,
          'kind': j.request.kind.name,
          'prompt': j.request.prompt,
          'seconds': j.request.seconds,
          'res': j.request.resolution,
          'aspect': j.request.aspect,
          'credits': j.credits,
          'started': j.started.toIso8601String(),
        }),
      );
    } catch (_) {}
  }

  Future<void> _clearPending() async {
    try {
      (await SharedPreferences.getInstance()).remove(_pendingKey);
    } catch (_) {}
  }

  /// After an app restart: keep polling a job that was still running.
  Future<void> resumePending() async {
    if (job.value != null) return;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_pendingKey);
      if (raw == null) return;
      final m = (jsonDecode(raw) as Map).cast<String, Object?>();
      final started = DateTime.parse('${m['started']}');
      // v11.58: past the 30 min window → given up, nothing was charged.
      if (DateTime.now().difference(started) > maxWait) {
        await _clearPending();
        return;
      }
      final r = VideoRequest(
        kind: VideoKind.values.byName('${m['kind']}'),
        prompt: '${m['prompt']}',
        seconds: (m['seconds'] as num).toInt(),
        resolution: '${m['res']}',
        aspect: '${m['aspect']}',
      );
      final be = await _backendFor(r.provider);
      if (be == null) return;
      _cancelled = false;
      job.value = VideoJob(
        request: r,
        phase: VideoPhase.queued,
        started: started,
        credits: (m['credits'] as num).toInt(),
        jobId: '${m['id']}',
      );
      unawaited(_run(be, resumeId: '${m['id']}'));
    } catch (_) {}
  }
}
