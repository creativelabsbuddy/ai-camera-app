import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/ai_config.dart';
import 'ai_call.dart';
import 'upload_prep.dart' show prepareUpload, kLookInputLongSide;

/// v11.58: FLUX.2 Klein 4B on Runware (violent / bloody style looks). Key
/// TEST builds call it directly with the dart-define RUNWARE_API_KEY (never
/// logged); server builds go through `/v1/looks/apply`.
const int kRunwareLongSide = 1024; // ~1 MP output

/// Runware sizes: 128–2048 px, multiples of 16, same aspect as the photo.
(int, int) runwareSize(int w, int h, {int longSide = kRunwareLongSide}) {
  final s = longSide / math.max(1, math.max(w, h));
  int r16(double v) => ((v / 16).round() * 16).clamp(128, 2048);
  return (r16(w * s), r16(h * s));
}

Map<String, Object?> buildRunwareTask({
  required String prompt,
  required String imageDataUrl,
  required int width,
  required int height,
  String? taskUuid,
}) {
  final (w, h) = runwareSize(width, height);
  return {
    'taskType': 'imageInference',
    'taskUUID': taskUuid ?? _uuid4(),
    'model': AiConfig.runwareKlein4bModel,
    'positivePrompt': prompt,
    'width': w,
    'height': h,
    'inputs': {
      'referenceImages': [imageDataUrl],
    },
    'outputType': 'base64Data',
    'outputFormat': 'JPG',
    'numberResults': 1,
    'includeCost': true,
  };
}

String _uuid4() {
  final r = math.Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

class RunwareClient {
  RunwareClient({http.Client? client, String? apiKey, this.timeout = kAiRequestTimeout})
    : _injected = client,
      _key = apiKey ?? AiConfig.runwareApiKey;

  final http.Client? _injected;
  final String _key;
  final Duration timeout;

  bool get isConfigured => _key.isNotEmpty;

  Future<({Uint8List image, double cost})> generate({
    required File image,
    required String prompt,
    AiCancelToken? cancel,
  }) async {
    if (!isConfigured) throw const AiFailure(AiFailureKind.other, 'Runware is not set up');
    final main = await prepareUpload(await image.readAsBytes(), maxLong: kLookInputLongSide);
    cancel?.throwIfCancelled();
    final body = jsonEncode([
      buildRunwareTask(prompt: prompt, imageDataUrl: main.dataUrl, width: main.width, height: main.height),
    ]);
    final own = _injected == null;
    final client = _injected ?? http.Client();
    if (own) cancel?.onCancel(client.close);
    http.Response resp;
    try {
      resp = await raceCancel(
        client
            .post(
              Uri.parse(AiConfig.runwareUrl),
              headers: {'Authorization': 'Bearer $_key', 'Content-Type': 'application/json'},
              body: body,
            )
            .timeout(timeout),
        cancel,
      );
    } finally {
      if (own) client.close();
    }
    if (resp.statusCode != 200) {
      final t = resp.body.length > 300 ? resp.body.substring(0, 300) : resp.body;
      throw AiFailure(
        looksLikeRefusal(t) ? AiFailureKind.refused : AiFailureKind.other,
        'Runware HTTP ${resp.statusCode}: ${t.replaceAll(_key, '***')}',
      );
    }
    final js = jsonDecode(resp.body);
    final data = js is Map ? js['data'] : null;
    var cost = 0.0;
    if (data is List) {
      for (final d in data.whereType<Map>()) {
        cost += (d['cost'] as num?)?.toDouble() ?? 0;
        final b64 = d['imageBase64Data'];
        if (b64 is String && b64.isNotEmpty) {
          return (image: base64Decode(b64.contains(',') ? b64.split(',').last : b64), cost: cost);
        }
        final url = d['imageURL'];
        if (url is String && url.isNotEmpty) {
          final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 60));
          if (r.statusCode == 200 && r.bodyBytes.isNotEmpty) return (image: r.bodyBytes, cost: cost);
        }
      }
    }
    throw const AiFailure(AiFailureKind.noImage, 'Runware returned no image');
  }
}
