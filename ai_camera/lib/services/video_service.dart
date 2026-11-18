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
import 'network_check.dart';
import 'server_api_client.dart' show decodeAccountBlob;
import 'upload_prep.dart' show prepareUpload;
import 'video_notifier.dart';

/// v11.63 AI video: Phosor MiniMax H3 Turbo for every length (5/8/10/15 s).
/// Key TEST builds call Phosor directly (like the image AI); server builds
/// go through `/v1/video/*`. Credits are charged only when a video is delivered.
/// [VideoProvider.wan] remains only so legacy job ids still parse.
/// v11.65: [VideoProvider.fal] = Fast ⚡ (fal.ai MiniMax H3 Max Turbo, ready
/// in seconds). Standard stays Phosor. Fast credits = the matching Standard
/// cell for now (credits TBD).
enum VideoProvider { wan, minimax, fal }

enum VideoKind { t2v, i2v }

const kVideoLengths = [5, 8, 10, 15];
const kMiniMaxResolutions = ['480p', '768p'];
const kVideoAspects = ['9:16', '16:9'];
const kMiniMaxLabel = 'MiniMax H3';
const kFastVideoLabel = 'MiniMax H3 Max Turbo';

/// v11.65 speed options shown before a video is made (English UI).
const kStandardVideoTitle = 'Standard';
const kStandardVideoNote = 'May take 10–15 min';
const kFastVideoTitle = 'Fast ⚡';
const kFastVideoNote = 'Ready in seconds';

/// v11.65: wait note while a Fast job runs.
const kFastVideoWaitNote = 'Usually ready in under a minute';

/// v11.65: a Standard job still not ready after this long shows "Make it Fast".
const kMakeItFastAfter = Duration(minutes: 3);
const kMakeItFastLabel = 'Make it Fast ⚡';

/// v11.65 fal MiniMax H3 Max Turbo endpoints (queue API).
String falModelPath(VideoKind k) =>
    '${AiConfig.falApp}/${k == VideoKind.i2v ? 'image' : 'text'}-to-video';
const kFalResolutions = {'480p': '480P', '768p': '768P'};

/// fal input (llms.txt, Nov 2026): prompt, duration (s), resolution
/// 480P/768P, prompt_expansion_mode (required), image_url (i2v: first frame,
/// the canvas follows the photo), aspect_ratio (t2v only).
Map<String, Object?> buildFalBody(
  VideoKind kind, {
  required String prompt,
  required int seconds,
  required String resolution,
  required String aspect,
  String? imageUrl,
}) => {
  'prompt': prompt,
  'duration': seconds,
  'resolution': kFalResolutions[resolution] ?? '480P',
  'prompt_expansion_mode': 'disabled',
  'enable_safety_checker': true,
  if (kind == VideoKind.i2v) 'image_url': imageUrl,
  if (kind == VideoKind.t2v) 'aspect_ratio': aspect,
};

/// v11.58: the user-facing chip on AI videos (replaces the model chip).
const kAiGeneratedLabel = 'AI-generated';

/// v11.58: a video that is not ready after this long is given up and its
/// credits refunded (nothing is charged before delivery).
const kVideoTimeout = Duration(minutes: 30);
const kVideoTimeoutMessage =
    'No video after 30 min. Your credits were refunded. Please try again later.';

/// v11.58 / v11.63: wait note shown while any AI video is made (all lengths).
const kLongVideoWaitNote = 'Usually ready in 15–20 min';

// Provider cost (₹, $1 = ₹95) → PROVISIONAL credits =
// ceil(cost × 1.5 / ₹0.99). Same numbers as the server for 8/10/15 s;
// minimax_5_480p is hard-set to 3 (the formula would be 5).
const _mmCostPerS = {'480p': 0.57, '768p': 0.855};

int _prov(double inr) => math.max(1, (inr * 1.5 / 0.99 - 1e-9).ceil());

/// Credit table, keyed like the server (`minimax_5_480p`).
Map<String, int> defaultVideoCredits() {
  final t = <String, int>{
    for (final r in kMiniMaxResolutions)
      for (final s in kVideoLengths) 'minimax_${s}_$r': _prov(_mmCostPerS[r]! * s),
  };
  t['minimax_5_480p'] = 3;
  // v11.65 Fast ⚡: credits TBD — same as the matching Standard cell for now.
  for (final r in kMiniMaxResolutions) {
    for (final s in kVideoLengths) {
      t['fal_${s}_$r'] = t['minimax_${s}_$r']!;
    }
  }
  return t;
}

VideoProvider providerFor(int seconds) => VideoProvider.minimax;

List<String> resolutionsFor(int seconds) => kMiniMaxResolutions;

class VideoRequest {
  const VideoRequest({
    required this.kind,
    required this.prompt,
    this.seconds = 5,
    this.resolution = '480p',
    this.aspect = '9:16',
    this.image,
    this.styleId,
    this.fast = false,
  });

  final VideoKind kind;
  final String prompt;
  final int seconds;
  final String resolution;
  final String aspect;
  final File? image;
  final String? styleId;

  /// v11.65 Fast ⚡ (fal) instead of Standard (Phosor).
  final bool fast;

  VideoProvider get provider => fast ? VideoProvider.fal : providerFor(seconds);
  String get creditKey => '${provider.name}_${seconds}_$resolution';
  bool get isMiniMax => provider == VideoProvider.minimax || provider == VideoProvider.fal;

  VideoRequest asFast() => VideoRequest(
    kind: kind,
    prompt: prompt,
    seconds: seconds,
    resolution: resolution,
    aspect: aspect,
    image: image,
    styleId: styleId,
    fast: true,
  );

  String? validate() {
    if (prompt.trim().isEmpty) return 'Describe the video';
    if (kind == VideoKind.i2v && image == null) return 'Choose a photo';
    if (!kVideoLengths.contains(seconds)) return 'Unsupported length';
    if (!resolutionsFor(seconds).contains(resolution)) return 'Unsupported resolution';
    if (!kVideoAspects.contains(aspect)) return 'Unsupported aspect ratio';
    if (!AiConfig.minimaxEnabled) return 'AI video is not available';
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
  String get modelLabel => request.fast ? kFastVideoLabel : kMiniMaxLabel;

  /// v11.65: Standard job failed or still waiting after [kMakeItFastAfter].
  bool canMakeFast(DateTime now) =>
      !request.fast &&
      (phase == VideoPhase.failed ||
          (active && phase != VideoPhase.downloading && now.difference(started) >= kMakeItFastAfter));

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
  for (final k in [AiConfig.videoApiKey, AiConfig.phosorApiKey, AiConfig.falApiKey]) {
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

/// Key test build: calls Phosor directly. Job id = `provider~rid`.
/// Needs only PHOSOR_API_KEY (VIDEO_API_KEY is unused).
class DirectVideoBackend implements VideoBackend {
  DirectVideoBackend({http.Client? client}) : _http = client ?? http.Client();
  final http.Client _http;
  static const _t = Duration(seconds: 60);

  @override
  bool get chargesLocally => true;

  Map<String, String> _h([VideoProvider? p]) => p == VideoProvider.fal
      ? {'Authorization': 'Key ${AiConfig.falApiKey}'}
      : {'X-API-Key': AiConfig.phosorApiKey};

  static bool configured(VideoProvider p) =>
      p == VideoProvider.fal ? AiConfig.falApiKey.isNotEmpty : AiConfig.phosorApiKey.isNotEmpty;

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
    if (p == VideoProvider.fal) return _falSubmit(r);
    String? rid;
    try {
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
    } on TimeoutException {
      // Never resubmit: the job may exist and be billed.
      throw VideoException('The video service timed out — not retried');
    }
    if (rid.isEmpty || rid == 'null') throw VideoException('The video service returned no job');
    return '${p.name}~$rid';
  }

  // -- v11.65 Fast ⚡: fal queue API ----------------------------------------
  String get _falBase => '${AiConfig.falQueueUrl}/${AiConfig.falApp}/requests';

  Future<String> _falSubmit(VideoRequest r) async {
    String? rid;
    try {
      String? img;
      if (r.kind == VideoKind.i2v) {
        // Base64 data URI (fal accepts it), ≤1536 px.
        img = (await prepareUpload(await r.image!.readAsBytes(), maxLong: 1536)).dataUrl;
      }
      final body = buildFalBody(r.kind,
          prompt: r.prompt, seconds: r.seconds, resolution: r.resolution, aspect: r.aspect, imageUrl: img);
      final res = await _http
          .post(Uri.parse('${AiConfig.falQueueUrl}/${falModelPath(r.kind)}'),
              headers: {..._h(VideoProvider.fal), 'Content-Type': 'application/json'}, body: jsonEncode(body))
          .timeout(_t);
      if (res.statusCode >= 400) throw _fail('Fast video submit', res);
      rid = '${(jsonDecode(res.body) as Map)['request_id'] ?? ''}';
    } on TimeoutException {
      throw VideoException('The video service timed out — not retried');
    }
    if (rid.isEmpty || rid == 'null') throw VideoException('The video service returned no job');
    return '${VideoProvider.fal.name}~$rid';
  }

  Future<VideoStatus> _falStatus(String rid) async {
    final h = _h(VideoProvider.fal);
    final res = await _http.get(Uri.parse('$_falBase/$rid/status'), headers: h).timeout(_t);
    if (res.statusCode >= 400) throw _fail('Status', res);
    final j = jsonDecode(res.body);
    final st = '${j is Map ? j['status'] : ''}'.toUpperCase();
    if (st == 'IN_QUEUE') return const VideoStatus('queued');
    if (st != 'COMPLETED') return const VideoStatus('running');
    if (j is Map && j['error'] != null) return VideoStatus('failed', error: _redact('${j['error']}'));
    final rr = await _http.get(Uri.parse('$_falBase/$rid'), headers: h).timeout(_t);
    if (rr.statusCode == 202) return const VideoStatus('running');
    if (rr.statusCode >= 400) {
      // Failed generation (e.g. 422 / safety) → failed, never charged.
      return VideoStatus('failed', error: _fail('Fast video', rr).message);
    }
    final out = jsonDecode(rr.body);
    final v = out is Map ? out['video'] : null;
    final u = (v is Map ? v['url'] as String? : null) ?? findVideoUrl(out);
    if (u == null || !u.startsWith('http')) return const VideoStatus('failed', error: 'No video returned');
    return VideoStatus('done', url: u);
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
    if (p == VideoProvider.fal) return _falStatus(rid);
    if (p != VideoProvider.minimax) {
      // Legacy 8scale job ids still parse; no 8scale API calls.
      return const VideoStatus('failed', error: 'This video job is no longer available');
    }
    final url = '${AiConfig.phosorBaseUrl}/inference/status/$rid';
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
    if (u == null) {
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
    return VideoStatus('done', url: u);
  }

  @override
  Future<void> cancel(String jobId) async {
    // Phosor has no cancel API. fal: cancel works only while IN_QUEUE.
    try {
      final (p, rid) = _parse(jobId);
      if (p != VideoProvider.fal) return;
      await _http
          .put(Uri.parse('$_falBase/$rid/cancel'), headers: _h(VideoProvider.fal))
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
        if (r.fast) 'speed': 'fast',
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

  /// v11.65 Fast ⚡: available (fal key in this build, or the server says
  /// so) and the user's last speed pick (Standard by default).
  final ValueNotifier<bool> fastAvailable = ValueNotifier(AiConfig.falApiKey.isNotEmpty);
  final ValueNotifier<bool> preferFast = ValueNotifier(false);

  int creditsFor(VideoRequest r) => credits.value[r.creditKey] ?? 0;
  int creditsForKey(int seconds, String res, {bool fast = false}) =>
      credits.value['${fast ? VideoProvider.fal.name : providerFor(seconds).name}_${seconds}_$res'] ?? 0;

  bool _cancelled = false;
  int _gen = 0;
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
      final js = jsonDecode(r.body) as Map;
      final fast = js['fast'];
      if (AiConfig.falApiKey.isEmpty && fast is Map) fastAvailable.value = fast['enabled'] == true;
      final c = js['credits'];
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
    // v11.59: no working internet → nothing submitted, nothing charged.
    if (!await NetworkCheck.instance.online()) {
      throw VideoException(kCheckInternet);
    }
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
    final g = ++_gen; // v11.65: a newer run (e.g. Make it Fast) wins
    var j = job.value!;
    try {
      final id = resumeId ?? await be.submit(j.request);
      if (_cancelled || g != _gen) {
        await be.cancel(id);
        return;
      }
      job.value = j = j.copy(phase: VideoPhase.queued, jobId: id);
      await _savePending(j);
      // v11.58: 30 min from the start (also across an app restart).
      final deadline = j.started.add(maxWait);
      while (true) {
        await Future<void>.delayed(pollEvery);
        if (_cancelled || g != _gen) return;
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
        if (_cancelled || g != _gen) return;
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
        if (_cancelled || g != _gen) return;
        job.value = j.copy(phase: VideoPhase.done, file: f, creditsCharged: charged);
        await _clearPending();
        unawaited(VideoNotifier.instance.show('Your AI video is ready', 'Tap to open AI Camera and watch it.'));
        return;
      }
    } catch (e) {
      if (_cancelled || g != _gen) return;
      final msg = e is VideoException
          ? e.message
          : isOfflineError(e)
          ? kCheckInternet
          : _redact('$e');
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

  /// v11.65 "Make it Fast": the Standard job failed or is taking too long →
  /// stop waiting for it (never charged) and start the same video on Fast ⚡.
  Future<void> makeFast() async {
    final j = job.value;
    if (j == null || j.request.fast) return;
    if (j.active) await cancel();
    job.value = null;
    await start(j.request.asFast());
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
          'fast': j.request.fast,
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
        fast: m['fast'] == true,
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
