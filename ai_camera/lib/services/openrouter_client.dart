import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/ai_config.dart';
import '../models/quality_tier.dart';
import 'ai_call.dart';
import 'mode_prompts.dart'
    show
        kDetectModel,
        kDetectSpotModel,
        kDetectSpotMaxTokens,
        kDetectSubjectPrompt,
        kDetectPartPrompt,
        kDetectSpotPrompt,
        kDetectBoxPrompt,
        kDetectBoxWideLine,
        kDetectJsonMaxTokens,
        objectsText,
        sanitizeDetected;
import 'upload_prep.dart';

export 'upload_prep.dart'
    show PreparedImage, prepareUpload, UploadPrep;

class OpenRouterEnhanceException implements Exception {
  OpenRouterEnhanceException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

/// Successful AI output.
class AiImageResult {
  const AiImageResult({
    required this.bytes,
    required this.contextUsed,
    this.costUsd,
    this.fellBackToSingleImage = false,
  });

  final Uint8List bytes;

  /// True when the second (context) image was accepted by the model.
  final bool contextUsed;

  /// True when 2 images were rejected and the call was retried crop-only.
  final bool fellBackToSingleImage;
  final double? costUsd;
}

/// Closest Flare-supported aspect ratio for [w]×[h].
String aspectRatioFor(int w, int h) {
  if (w <= 0 || h <= 0) return '3:4';
  final ratio = w / h;
  const candidates = <String, double>{
    '1:1': 1.0,
    '3:2': 1.5,
    '2:3': 2 / 3,
    '4:3': 4 / 3,
    '3:4': 3 / 4,
    '16:9': 16 / 9,
    '9:16': 9 / 16,
    '21:9': 21 / 9,
  };
  var best = '3:4';
  var bestDiff = double.infinity;
  for (final e in candidates.entries) {
    final d = (e.value - ratio).abs();
    if (d < bestDiff) {
      bestDiff = d;
      best = e.key;
    }
  }
  return best;
}

/// OpenRouter Images API payload. First reference = image to enhance;
/// optional second = downscaled full frame (scene context only).
Map<String, dynamic> buildImagesPayload({
  required String prompt,
  required QualityTier tier,
  required String aspectRatio,
  required String? imageDataUrl,
  String? contextDataUrl,
  List<String> leadingDataUrls = const [],
  List<String> trailingDataUrls = const [],
}) {
  // v11.30: imageDataUrl null + no other refs → text-only (Macro Extreme /
  // Ultra); `input_references` is omitted.
  final refs = [
    // v11.12 Macro: boxed step photos first, the zoomed crop after them.
    for (final u in leadingDataUrls)
      {
        'type': 'image_url',
        'image_url': {'url': u},
      },
    if (imageDataUrl != null)
      {
        'type': 'image_url',
        'image_url': {'url': imageDataUrl},
      },
    if (contextDataUrl != null)
      {
        'type': 'image_url',
        'image_url': {'url': contextDataUrl},
      },
    // v11.31 zoom ladder: the photo first, reference crops after it.
    for (final u in trailingDataUrls)
      {
        'type': 'image_url',
        'image_url': {'url': u},
      },
  ];
  return {
    'model': AiConfig.model,
    'prompt': prompt,
    'quality': tier.flareQuality,
    'resolution': tier.flareResolution,
    'aspect_ratio': aspectRatio,
    'n': 1,
    'output_format': 'jpeg',
    if (refs.isNotEmpty) 'input_references': refs,
  };
}

/// Flare quality for AI looks (style / custom change). Measured v9.1:
/// `high` roughly doubles latency and cost for no visible gain on edits,
/// and Flare ignores `resolution` (it always returns ~1.5K), so looks use
/// `medium` (HD custom changes: `low`).
String lookQualityFor(QualityTier tier) =>
    tier == QualityTier.hd ? 'low' : 'medium';

/// Look payload: user photo first, then style reference images; n images.
/// JPEG output (a fraction of the PNG download on mobile data).
Map<String, dynamic> buildLookPayload({
  required String prompt,
  required QualityTier tier,
  required String aspectRatio,
  required String imageDataUrl,
  List<String> referenceDataUrls = const [],
  int n = 1,
  String? model,
}) => {
  'model': model ?? AiConfig.model,
  'prompt': prompt,
  // v11.58: FLUX Klein takes neither quality nor resolution.
  if (model != AiConfig.kleinModel) 'quality': lookQualityFor(tier),
  if (model != AiConfig.kleinModel) 'resolution': tier == QualityTier.hd ? '1K' : '1.5K',
  'aspect_ratio': aspectRatio,
  'n': n,
  'output_format': 'jpeg',
  'input_references': <Map<String, Object>>[
    {
      'type': 'image_url',
      'image_url': {'url': imageDataUrl},
    },
    for (final u in referenceDataUrls)
      {
        'type': 'image_url',
        'image_url': {'url': u},
      },
  ],
};

/// Extracts every image in an Images API body. A 200 without any image
/// (text-only answer / refusal / empty data) becomes an [AiFailure].
List<Map<String, dynamic>> imageItemsOrThrow(Map<String, dynamic> body) {
  final data = body['data'];
  final items = <Map<String, dynamic>>[
    if (data is List)
      for (final d in data)
        if (d is Map &&
            ((d['b64_json'] ?? d['b64'] ?? d['url']) is String) &&
            ('${d['b64_json'] ?? d['b64'] ?? d['url']}').isNotEmpty)
          d.cast<String, dynamic>(),
  ];
  if (items.isNotEmpty) return items;
  final text = [
    body['error'],
    body['output_text'],
    body['message'],
    body['text'],
    if (data is List)
      for (final d in data)
        if (d is Map) d['revised_prompt'] ?? d['text'],
  ].whereType<Object>().join(' ');
  debugPrint(
    'AI returned no image. ${text.length > 300 ? text.substring(0, 300) : text}',
  );
  throw AiFailure(
    looksLikeRefusal(text) ? AiFailureKind.refused : AiFailureKind.noImage,
    'The AI returned no image${text.isEmpty ? '' : ': ${text.length > 160 ? text.substring(0, 160) : text}'}',
  );
}

/// 4xx that suggests the model/endpoint did not like the 2-image request
/// (not auth / payment / rate-limit problems).
bool isMultiImageRejection(int status) =>
    status >= 400 &&
    status < 500 &&
    status != 401 &&
    status != 402 &&
    status != 403 &&
    status != 429;

/// v11.29: retry the spot on flash-lite when the reply is empty or cut.
bool spotNeedsRetry(String reply, String finishReason) =>
    reply.trim().isEmpty || finishReason == 'length';

/// Direct OpenRouter Images API client. Only used by TEST profile APKs that
/// embed a key via --dart-define (release APKs never contain the key).
/// v11.15 detection chat payload (same as the server's detect_payload).
Map<String, dynamic> detectPayload(
  String text,
  List<String> dataUrls, {
  int maxTokens = 24,
  String model = kDetectModel,
  bool noThinking = false,
}) => {
  'model': model,
  // v11.29: never spend the budget on hidden reasoning (spot call).
  if (noThinking) 'reasoning': {'max_tokens': 0},
  'max_tokens': maxTokens,
  'temperature': 0,
  'messages': [
    {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': text},
        for (final u in dataUrls)
          {
            'type': 'image_url',
            'image_url': {'url': u},
          },
      ],
    },
  ],
};

/// v11.24: per-request cap for the 1.5x call, above the 8 s overall limit
/// (SubjectDetector.detectSubjectTimed) so that one decides.
const Duration kDetectSubjectRequestTimeout = Duration(seconds: 10);

/// v11.21: room for the colour wording (24 could end empty / cut off).
const int kDetectMaxTokens = 60;

/// v11.21: reply text from a chat completion body, tolerant of content as
/// a string OR a list of parts. Returns (text, reason-if-empty).
(String, String) visionReplyText(String body) {
  try {
    final j = jsonDecode(body);
    if (j is! Map) return ('', 'bad json');
    final choices = j['choices'];
    if (choices is! List || choices.isEmpty) {
      return ('', j['error'] != null ? 'api error' : 'no choices');
    }
    final ch = choices.first as Map;
    final m = ch['message'];
    final c = m is Map ? m['content'] : null;
    var text = '';
    if (c is String) {
      text = c;
    } else if (c is List) {
      text = [
        for (final p in c)
          if (p is Map && p['text'] is String) p['text'] as String,
      ].join(' ');
    }
    if (text.trim().isNotEmpty) return (text, 'ok');
    final fin = ch['finish_reason'];
    return ('', fin is String && fin.isNotEmpty ? 'empty ($fin)' : 'empty');
  } catch (_) {
    return ('', 'bad json');
  }
}

class OpenRouterClient {
  OpenRouterClient({
    http.Client? httpClient,
    String? apiKey,
    this.timeout = kAiRequestTimeout,
  }) : _injected = httpClient,
       _apiKey = apiKey ?? AiConfig.openRouterApiKey;

  /// Test client; when null every request gets its own client so a timeout
  /// or Cancel can abort the socket by closing it.
  final http.Client? _injected;
  final String _apiKey;

  /// Per-request timeout (each AI call).
  final Duration timeout;

  bool get isConfigured => _apiKey.isNotEmpty;

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $_apiKey',
    'Content-Type': 'application/json',
    'HTTP-Referer': 'https://ai-camera.local',
    'X-Title': 'AI Camera Flutter',
  };

  /// v11.15 cheap vision text call ('' on any failure / ~5 s timeout).
  Future<String> _visionText(
    List<File> images,
    String text,
    int maxTokens, {
    Duration? requestTimeout,
    String model = kDetectModel,
    bool noThinking = false,
  }) async {
    lastFinishReason = '';
    if (!isConfigured) {
      lastDetectReason = 'no key';
      return '';
    }
    try {
      final urls = <String>[];
      for (final f in images) {
        final p = await prepareUpload(
          await f.readAsBytes(),
          maxLong: AiConfig.detectLongSide,
        );
        urls.add(p.dataUrl);
      }
      final client = _injected ?? http.Client();
      try {
        final r = await client
            .post(
              Uri.parse(AiConfig.openRouterChatUrl),
              headers: _headers,
              body: jsonEncode(
                detectPayload(
                  text,
                  urls,
                  maxTokens: maxTokens,
                  model: model,
                  noThinking: noThinking,
                ),
              ),
            )
            .timeout(requestTimeout ?? AiConfig.detectTimeout);
        if (r.statusCode != 200) {
          lastDetectReason = 'http ${r.statusCode}';
          debugPrint('Detect HTTP ${r.statusCode}: ${_snippet(r.body)}');
          return '';
        }
        lastFinishReason = _finishReason(r.body);
        final (reply, why) = visionReplyText(r.body);
        lastDetectReason = reply.trim().isEmpty ? why : 'ok';
        return reply;
      } finally {
        if (_injected == null) client.close();
      }
    } on TimeoutException {
      lastDetectReason = 'timeout';
      return '';
    } catch (e) {
      debugPrint('Detect call failed: $e');
      lastDetectReason = 'error ${e.runtimeType}';
      return '';
    }
  }

  /// v11.21 test-build debug: why the last detection call gave nothing
  /// ('ok', 'timeout', 'http 4xx', 'empty', 'empty (length)', …).
  String lastDetectReason = '';

  /// v11.29 finish_reason of the last detection reply ('' = unknown).
  String lastFinishReason = '';

  /// v11.29 which model answered the last spot call ('flash' / 'lite').
  String lastSpotModel = '';

  static String _finishReason(String body) {
    try {
      final j = jsonDecode(body);
      final f = (j['choices'] as List).first['finish_reason'];
      return f is String ? f : '';
    } catch (_) {
      return '';
    }
  }

  /// 1.5x photo → raw JSON reply {"main", "others"} (v11.22).
  /// v11.24: the caller's ONE 8 s overall limit governs this call, so the
  /// request itself may run a little longer than it.
  Future<String> detectSubject(File oneX) => _visionText(
    [oneX],
    kDetectSubjectPrompt,
    kDetectJsonMaxTokens,
    requestTimeout: kDetectSubjectRequestTimeout,
  );

  static String _main(String? s) =>
      sanitizeDetected(s).isEmpty ? 'the subject' : sanitizeDetected(s);

  /// v11.19 shutter: overview + closer photo with the final zoom boxed →
  /// raw JSON reply {"object", "part", "in_scene"} (v11.22).
  Future<String> detectSpot(
    File overview,
    File closerBoxed,
    String? subject, {
    List<String> others = const [],
  }) async {
    final text = kDetectSpotPrompt
        .replaceAll('{subject}', _main(subject))
        .replaceAll('{objects}', objectsText(_main(subject), others));
    // v11.29: flash, thinking off, 200 tokens; empty / cut off → one
    // retry on flash-lite.
    lastSpotModel = 'flash';
    final r = await _visionText(
      [overview, closerBoxed],
      text,
      kDetectSpotMaxTokens,
      model: kDetectSpotModel,
      noThinking: true,
      requestTimeout: const Duration(seconds: 6),
    );
    if (!spotNeedsRetry(r, lastFinishReason)) return r;
    final first = lastDetectReason == 'ok'
        ? 'cut ($lastFinishReason)'
        : lastDetectReason;
    lastSpotModel = 'lite';
    final r2 = await _visionText(
      [overview, closerBoxed],
      text,
      kDetectJsonMaxTokens,
      requestTimeout: const Duration(seconds: 4),
    );
    if (r2.trim().isEmpty) lastDetectReason = '$first → $lastDetectReason';
    return r2;
  }

  /// v11.33 shutter: the box area alone → raw JSON {"part", "clear"}.
  /// Spot-check setup: flash, thinking off; empty / cut off → one retry on
  /// flash-lite.
  /// v11.49: [wide] (optional) goes first as the overview.
  Future<String> detectBox(File box, {File? wide}) async {
    lastSpotModel = 'flash';
    final imgs = [if (wide != null) wide, box];
    final prompt = wide == null
        ? kDetectBoxPrompt
        : '$kDetectBoxWideLine$kDetectBoxPrompt';
    final r = await _visionText(
      imgs,
      prompt,
      kDetectSpotMaxTokens,
      model: kDetectSpotModel,
      noThinking: true,
      requestTimeout: const Duration(seconds: 6),
    );
    if (!spotNeedsRetry(r, lastFinishReason)) return r;
    lastSpotModel = 'lite';
    return _visionText(
      imgs,
      prompt,
      kDetectJsonMaxTokens,
      requestTimeout: const Duration(seconds: 4),
    );
  }

  /// 1.5x photo + boxed step photo → raw JSON reply (v11.22 objects).
  Future<String> detectPart(
    File oneX,
    File boxedStep,
    String parent, {
    List<String> others = const [],
  }) => _visionText(
    [oneX, boxedStep],
    kDetectPartPrompt
        .replaceAll('{parent}', _main(parent))
        .replaceAll('{objects}', objectsText(_main(parent), others)),
    kDetectJsonMaxTokens,
  );

  Future<http.Response> _post(String body, AiCancelToken? cancel) async {
    final own = _injected == null;
    final client = _injected ?? http.Client();
    if (own) cancel?.onCancel(client.close);
    try {
      return await raceCancel(
        client
            .post(
              Uri.parse(AiConfig.openRouterImagesUrl),
              headers: _headers,
              body: body,
            )
            .timeout(timeout),
        cancel,
      );
    } finally {
      if (own) client.close();
    }
  }

  static AiFailure _httpFailure(http.Response resp) {
    final snippet = _snippet(resp.body);
    final kind = resp.statusCode == 400 && looksLikeRefusal(resp.body)
        ? AiFailureKind.refused
        : AiFailureKind.other;
    return AiFailure(kind, 'OpenRouter HTTP ${resp.statusCode}: $snippet');
  }

  Future<AiImageResult> enhanceImages({
    required File image,
    File? context,
    List<File> leading = const [],
    required QualityTier tier,
    required String Function(bool hasContext) promptFor,
    AiCancelToken? cancel,
    int? mainLong,
    int leadingLong = kMacroContextLongSide,
    bool textOnly = false,
    bool leadingAfterMain = false,
  }) async {
    if (!isConfigured) {
      throw OpenRouterEnhanceException('OpenRouter API key not configured');
    }
    final main = await prepareUpload(
      await image.readAsBytes(),
      maxLong: mainLong ?? kEnhanceInputLongSide,
    );
    PreparedImage? ctx;
    if (context != null && await context.exists()) {
      ctx = await prepareUpload(
        await context.readAsBytes(),
        maxLong: contextLongSideFor(context.path),
      );
    }
    final lead = <String>[];
    for (final f in leading) {
      if (!await f.exists()) continue;
      lead.add(
        (await prepareUpload(
          await f.readAsBytes(),
          maxLong: leadingLong,
        )).dataUrl,
      );
    }
    cancel?.throwIfCancelled();
    final aspect = aspectRatioFor(main.width, main.height);

    Future<http.Response> send(bool withContext) => _post(
      jsonEncode(
        buildImagesPayload(
          prompt: promptFor(withContext),
          tier: tier,
          aspectRatio: aspect,
          // v11.30: the crop only sets the aspect ratio when text-only.
          imageDataUrl: textOnly ? null : main.dataUrl,
          contextDataUrl: withContext ? ctx?.dataUrl : null,
          leadingDataUrls: withContext && !leadingAfterMain ? lead : const [],
          trailingDataUrls: withContext && leadingAfterMain ? lead : const [],
        ),
      ),
      cancel,
    );

    var withContext = ctx != null || lead.isNotEmpty;
    var fellBack = false;
    var resp = await send(withContext);
    if (withContext &&
        resp.statusCode != 200 &&
        isMultiImageRejection(resp.statusCode) &&
        !looksLikeRefusal(resp.body)) {
      debugPrint(
        'OpenRouter rejected 2-image input (HTTP ${resp.statusCode}): '
        '${_snippet(resp.body)} — retrying with the crop only',
      );
      withContext = false;
      fellBack = true;
      resp = await send(false);
    }
    if (resp.statusCode != 200) throw _httpFailure(resp);

    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final items = imageItemsOrThrow(body);
    final bytes = await _decodeItem(items.first, cancel);
    final usage = body['usage'];
    final cost = usage is Map ? (usage['cost'] as num?)?.toDouble() : null;
    cancel?.throwIfCancelled();
    // v11.58: the AI image is delivered as it came (no 1920 / tier upscale,
    // no re-encode).
    return AiImageResult(
      bytes: bytes,
      contextUsed: withContext,
      fellBackToSingleImage: fellBack,
      costUsd: cost,
    );
  }

  /// AI look (style / custom change) with up to [n] images. Providers that
  /// return fewer than n are topped up with single calls IN PARALLEL. Only
  /// one request is made when n == 1. Returns what came back (callers charge
  /// per image received); throws [AiFailure] when nothing came back.
  /// The input is downscaled to [kLookInputLongSide] and the output is NOT
  /// upscaled (looks are delivered at the model's native ~1.5K).
  Future<({List<Uint8List> images, double cost})> generateLook({
    required File image,
    required String prompt,
    required QualityTier tier,
    List<Uint8List> references = const [],
    int n = 1,
    AiCancelToken? cancel,
    String? model,
  }) async {
    if (!isConfigured) {
      throw OpenRouterEnhanceException('OpenRouter API key not configured');
    }
    // v11.58: Klein gets only the user's photo (no reference images).
    if (model == AiConfig.kleinModel) references = const [];
    final main = await prepareUpload(
      await image.readAsBytes(),
      maxLong: kLookInputLongSide,
    );
    final refs = <String>[
      for (final r in references)
        (await prepareUpload(r, maxLong: kReferenceLongSide)).dataUrl,
    ];
    cancel?.throwIfCancelled();
    final aspect = aspectRatioFor(main.width, main.height);
    final images = <Uint8List>[];
    var cost = 0.0;
    Object? lastError;

    Future<void> call(int count) async {
      try {
        final resp = await _post(
          jsonEncode(
            buildLookPayload(
              prompt: prompt,
              tier: tier,
              aspectRatio: aspect,
              imageDataUrl: main.dataUrl,
              referenceDataUrls: refs,
              n: count,
              model: model,
            ),
          ),
          cancel,
        );
        if (resp.statusCode != 200) throw _httpFailure(resp);
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        final usage = body['usage'];
        cost += usage is Map ? (usage['cost'] as num?)?.toDouble() ?? 0 : 0;
        for (final item in imageItemsOrThrow(body)) {
          if (images.length >= n) break;
          images.add(await _decodeItem(item, cancel));
        }
      } on AiCancelledException {
        rethrow;
      } catch (e) {
        lastError = e;
      }
    }

    await call(n);
    cancel?.throwIfCancelled();
    final missing = n - images.length;
    if (images.isNotEmpty && missing > 0) {
      await Future.wait([for (var i = 0; i < missing; i++) call(1)]);
    }
    cancel?.throwIfCancelled();
    if (images.isEmpty) {
      final e = lastError;
      if (e is AiFailure) throw e;
      if (e != null) throw AiFailure(classifyAiError(e), '$e');
      throw const AiFailure(AiFailureKind.noImage, 'No image returned');
    }
    return (images: images.take(n).toList(), cost: cost);
  }

  Future<Uint8List> _decodeItem(
    Map<String, dynamic> data,
    AiCancelToken? cancel,
  ) async {
    final b64 = data['b64_json'] as String? ?? data['b64'] as String?;
    if (b64 != null && b64.isNotEmpty) return base64Decode(b64);
    final url = data['url'] as String?;
    if (url != null && url.isNotEmpty) {
      final own = _injected == null;
      final client = _injected ?? http.Client();
      if (own) cancel?.onCancel(client.close);
      try {
        final r = await raceCancel(
          client.get(Uri.parse(url)).timeout(const Duration(seconds: 60)),
          cancel,
        );
        if (r.statusCode != 200) {
          throw AiFailure(
            AiFailureKind.other,
            'Failed to fetch image URL (${r.statusCode})',
          );
        }
        return r.bodyBytes;
      } finally {
        if (own) client.close();
      }
    }
    throw const AiFailure(
      AiFailureKind.noImage,
      'Unexpected OpenRouter image payload',
    );
  }

  static String _snippet(String s) => s.length > 300 ? s.substring(0, 300) : s;
}
