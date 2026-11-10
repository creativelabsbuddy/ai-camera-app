import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:http/http.dart' as http;

import '../config/ai_config.dart';
import '../models/quality_tier.dart';
import 'ai_call.dart';
import 'entitlements.dart';
import 'upload_prep.dart';

class ServerApiException implements Exception {
  ServerApiException(
    this.message, {
    this.statusCode,
    this.denyReason,
    this.failureKind,
  });
  final String message;
  final int? statusCode;

  /// Set when the server refused for entitlement reasons (HTTP 402).
  final DenyReason? denyReason;

  /// Set when the AI produced nothing (HTTP 502/504 `{detail:{reason}}`).
  final AiFailureKind? failureKind;

  AiFailure? get failure =>
      failureKind == null ? null : AiFailure(failureKind!, message);

  @override
  String toString() => message;
}

AiFailureKind? failureKindFromWire(String? s) {
  switch (s) {
    case 'timeout':
      return AiFailureKind.timeout;
    case 'no_image':
      return AiFailureKind.noImage;
    case 'refused':
      return AiFailureKind.refused;
    case 'blocked':
      return AiFailureKind.blocked;
    case 'enhance_only':
      return AiFailureKind.enhanceOnly;
    case 'upstream':
      return AiFailureKind.other;
    case 'too_dark':
      return AiFailureKind.tooDark;
    case 'structure_changed':
      return AiFailureKind.structureChanged;
    case 'framing_changed':
      return AiFailureKind.framingChanged;
  }
  return null;
}

DenyReason? denyReasonFromWire(String? s) {
  switch (s) {
    case 'zoom_needs_pro':
      return DenyReason.zoomNeedsPro;
    case 'filter_needs_pro':
      return DenyReason.filterNeedsPro;
    case 'style_needs_pro':
      return DenyReason.styleNeedsPro;
    case 'prompt_needs_pro':
      return DenyReason.promptNeedsPro;
    case 'no_credits':
      return DenyReason.noCredits;
    case 'bad_request':
      return DenyReason.badRequest;
  }
  return null;
}

/// Decodes the base64url `account` header / field into a state.
CreditState? decodeAccountBlob(String? encoded) {
  if (encoded == null || encoded.isEmpty) return null;
  try {
    return CreditState.fromJson(
      (jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(encoded))))
              as Map)
          .cast<String, Object?>(),
    );
  } catch (_) {
    return null;
  }
}

class ServerLookResult {
  const ServerLookResult({
    required this.images,
    required this.creditsCharged,
    required this.trialsUsed,
    this.account,
    this.costUsd,
    this.referencesUsed = 0,
  });

  final List<Uint8List> images;
  final int creditsCharged;
  final List<StarterTrial> trialsUsed;
  final CreditState? account;
  final double? costUsd;
  final int referencesUsed;
}

class ServerEnhanceResult {
  const ServerEnhanceResult({
    required this.bytes,
    required this.contextUsed,
    required this.creditsCharged,
    required this.trialsUsed,
    this.account,
    this.structure,
  });

  final Uint8List bytes;
  final bool contextUsed;
  final int creditsCharged;
  final List<StarterTrial> trialsUsed;
  final CreditState? account;

  /// v11 Pro Night structure similarity (X-Structure), when checked.
  final double? structure;
}

/// enhance-server v1 API (key + credits ledger live on the server).
class ServerApiClient {
  ServerApiClient({http.Client? httpClient, this.aiTimeout = kAiServerTimeout})
    : _injected = httpClient;

  /// Server AI calls: the server's own upstream timeout (90 s) + upload /
  /// download slack on mobile data. Covers the WHOLE response (headers and
  /// body), so a stalled download can't spin forever.
  static const Duration kAiServerTimeout = Duration(seconds: 120);

  final http.Client? _injected;
  final Duration aiTimeout;
  http.Client? _shared;

  http.Client get _http => _injected ?? (_shared ??= http.Client());

  /// Sends [req] on its own client (so Cancel / timeout aborts the socket)
  /// and reads the full body within [timeout].
  Future<http.Response> _sendAi(
    http.BaseRequest req,
    Duration timeout,
    AiCancelToken? cancel,
  ) async {
    final own = _injected == null;
    final client = _injected ?? http.Client();
    if (own) cancel?.onCancel(client.close);
    try {
      return await raceCancel(
        client.send(req).then(http.Response.fromStream).timeout(timeout),
        cancel,
      );
    } finally {
      if (own) client.close();
    }
  }

  static String root(String baseUrl) =>
      baseUrl.trim().replaceAll(RegExp(r'/+$'), '');

  Future<CreditState> account(String baseUrl, String deviceId) async {
    final uri = Uri.parse(
      '${root(baseUrl)}/v1/account',
    ).replace(queryParameters: {'device_id': deviceId});
    final r = await _http.get(uri).timeout(const Duration(seconds: 20));
    return _parseAccount(r);
  }

  Future<CreditState> purchase(
    String baseUrl,
    String deviceId,
    String productId,
  ) async {
    final r = await _http
        .post(
          Uri.parse('${root(baseUrl)}/v1/purchase'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'device_id': deviceId, 'product_id': productId}),
        )
        .timeout(const Duration(seconds: 20));
    return _parseAccount(r);
  }

  /// v11.15 Macro detection via the server (free). Returns the parsed
  /// JSON, or null on any failure / ~6 s timeout.
  Future<Map<String, dynamic>?> macroDetect({
    required String baseUrl,
    required String deviceId,
    required List<(String, File)> files,
    String? parent,
    String endpoint = '',
    Map<String, String> fields = const {},
    Duration timeout = const Duration(seconds: 6),
  }) async {
    try {
      final ep = endpoint.isNotEmpty
          ? endpoint
          : (parent == null ? 'subject' : 'part');
      final req = http.MultipartRequest(
        'POST',
        Uri.parse('${root(baseUrl)}/v1/macro/$ep'),
      );
      req.fields.addAll(fields);
      for (final (field, f) in files) {
        final p = await prepareUpload(
          await f.readAsBytes(),
          maxLong: AiConfig.detectLongSide, // v11.49: 768
        );
        req.files.add(
          http.MultipartFile.fromBytes(field, p.bytes, filename: '$field.jpg'),
        );
      }
      req.fields['device_id'] = deviceId;
      if (parent != null) req.fields['parent'] = parent;
      final r = await _sendAi(req, timeout, null);
      if (r.statusCode != 200) return null;
      final j = jsonDecode(r.body);
      return j is Map<String, dynamic> ? j : null;
    } catch (e) {
      debugPrint('Server detect failed: $e');
      return null;
    }
  }

  Future<ServerEnhanceResult> enhance({
    required String baseUrl,
    required String deviceId,
    required File image,
    File? context,
    required QualityTier tier,
    required double zoom,
    required double opticalLimit,
    String? filterId,
    bool night = false,
    String mode = 'photo',
    String? colorFilter,
    String? subject,
    bool subjectSure = false,
    bool contextBoxed = false,
    List<File> steps = const [],
    bool zoomLadder = false,
    bool zoomClean = false,
    String? macroLevel,
    String? part,
    AiCancelToken? cancel,
    int? mainLong,
    int stepLong = kMacroContextLongSide,
  }) async {
    final req = http.MultipartRequest(
      'POST',
      Uri.parse('${root(baseUrl)}/v1/enhance'),
    );
    // Downscale on the phone: never upload a 12–50 MP original.
    final main = await prepareUpload(
      await image.readAsBytes(),
      maxLong: mainLong ?? kEnhanceInputLongSide,
    );
    req.files.add(
      http.MultipartFile.fromBytes('image', main.bytes, filename: 'image.jpg'),
    );
    if (context != null && await context.exists()) {
      final ctx = await prepareUpload(
        await context.readAsBytes(),
        maxLong: contextLongSideFor(context.path),
      );
      req.files.add(
        http.MultipartFile.fromBytes(
          'context',
          ctx.bytes,
          filename: 'context.jpg',
        ),
      );
    }
    // v11.12 Macro: boxed 2x / 3x / 4x step photos.
    for (final (i, f) in steps.indexed) {
      if (!await f.exists()) continue;
      final b = await prepareUpload(await f.readAsBytes(), maxLong: stepLong);
      req.files.add(
        http.MultipartFile.fromBytes('steps', b.bytes, filename: 'step$i.jpg'),
      );
    }
    req.fields.addAll({
      'device_id': deviceId,
      'quality': tier.id,
      'zoom': zoom.toStringAsFixed(3),
      'optical_limit': opticalLimit.toStringAsFixed(3),
      if (filterId != null) 'filter_id': filterId,
      if (night) 'night': 'true',
      if (mode != 'photo') 'mode': mode,
      if (colorFilter != null) 'color_filter': colorFilter,
      if (subject != null && subject.trim().isNotEmpty) 'subject': subject,
      if (macroLevel != null) 'macro_level': macroLevel,
      if (part != null && part.trim().isNotEmpty) 'part': part,
      if (subjectSure) 'subject_sure': 'true',
      if (contextBoxed) 'context_boxed': 'true',
      if (zoomLadder) 'zoom_ladder': 'true', // v11.30
      if (zoomClean) 'zoom_clean': 'true', // v11.34
    });
    final resp = await _sendAi(req, aiTimeout, cancel);
    _throwIfNotOk(resp, 'Enhance');
    final h = resp.headers;
    final acct = decodeAccountBlob(h['x-account']);
    return ServerEnhanceResult(
      bytes: resp.bodyBytes,
      contextUsed: h['x-context-used'] == '1',
      creditsCharged: int.tryParse(h['x-credits-charged'] ?? '') ?? 0,
      trialsUsed: (h['x-trials-used'] ?? '')
          .split(',')
          .map((e) => StarterTrial.fromId(e.trim()))
          .whereType<StarterTrial>()
          .toList(),
      account: acct,
      structure: double.tryParse(h['x-structure'] ?? ''),
    );
  }

  /// v9 AI look: library style (by id — the server composes the hidden
  /// prompt + reference images) or a custom "Prompt" prompt.
  Future<ServerLookResult> applyLook({
    required String baseUrl,
    required String deviceId,
    required File image,
    String? styleId,
    String? customPrompt,
    QualityTier tier = QualityTier.fullHd,
    AiCancelToken? cancel,
  }) async {
    final req = http.MultipartRequest(
      'POST',
      Uri.parse('${root(baseUrl)}/v1/looks/apply'),
    );
    final main = await prepareUpload(
      await image.readAsBytes(),
      maxLong: kLookInputLongSide,
    );
    req.files.add(
      http.MultipartFile.fromBytes('image', main.bytes, filename: 'image.jpg'),
    );
    req.fields.addAll({
      'device_id': deviceId,
      // v11.56: always one image (4 variations removed).
      'variations': '1',
      if (styleId != null) 'style_id': styleId,
      if (styleId == null && customPrompt != null)
        'custom_prompt': customPrompt,
      if (styleId == null) 'quality': tier.id,
    });
    final resp = await _sendAi(req, aiTimeout, cancel);
    _throwIfNotOk(resp, 'Style');
    final j = (jsonDecode(resp.body) as Map).cast<String, Object?>();
    final imgs = (j['images'] as List? ?? const [])
        .map((e) => base64Decode('$e'))
        .toList();
    if (imgs.isEmpty) {
      throw ServerApiException(
        'Server returned no image',
        statusCode: 502,
        failureKind: AiFailureKind.noImage,
      );
    }
    return ServerLookResult(
      images: imgs,
      creditsCharged: (j['credits_charged'] as num?)?.toInt() ?? 0,
      trialsUsed: (j['trials_used'] as List? ?? const [])
          .map((e) => StarterTrial.fromId('$e'))
          .whereType<StarterTrial>()
          .toList(),
      account: decodeAccountBlob(j['account'] as String?),
      costUsd: (j['cost'] as num?)?.toDouble(),
      referencesUsed: (j['references_used'] as num?)?.toInt() ?? 0,
    );
  }

  static void _throwIfNotOk(http.Response resp, String what) {
    if (resp.statusCode == 402) {
      String? reason;
      try {
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        final detail = j['detail'];
        reason = detail is Map ? '${detail['reason']}' : '${j['reason']}';
      } catch (_) {}
      throw ServerApiException(
        'Not allowed: $reason',
        statusCode: 402,
        denyReason: denyReasonFromWire(reason) ?? DenyReason.noCredits,
      );
    }
    if (resp.statusCode != 200) {
      AiFailureKind? kind;
      try {
        final detail = (jsonDecode(resp.body) as Map)['detail'];
        if (detail is Map) kind = failureKindFromWire('${detail['reason']}');
      } catch (_) {}
      if (resp.statusCode == 504) kind ??= AiFailureKind.timeout;
      if (resp.statusCode == 502) kind ??= AiFailureKind.other;
      throw ServerApiException(
        '$what server HTTP ${resp.statusCode}: ${_snippet(resp.body)}',
        statusCode: resp.statusCode,
        failureKind: kind,
      );
    }
  }

  CreditState _parseAccount(http.Response r) {
    if (r.statusCode != 200) {
      throw ServerApiException(
        'Server HTTP ${r.statusCode}: ${_snippet(r.body)}',
        statusCode: r.statusCode,
      );
    }
    final j = (jsonDecode(r.body) as Map).cast<String, Object?>();
    final state = j['state'];
    return CreditState.fromJson(
      (state is Map ? state : j).cast<String, Object?>(),
    );
  }

  static String _snippet(String s) => s.length > 300 ? s.substring(0, 300) : s;
}
