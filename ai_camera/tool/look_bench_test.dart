// Bench for the look (style / custom change) path. NOT part of `flutter test`
// (lives in tool/). Run:
//   BENCH_IMAGE=/path.jpg BENCH_TIER=ultra_hd BENCH_PROMPT="black suit" \
//   [BENCH_REAL=1] flutter test tool/look_bench_test.dart
// Without BENCH_REAL the network is mocked (measures prep + payload only).
import 'dart:convert';
import 'dart:io';

import 'package:ai_camera/models/quality_tier.dart';
import 'package:ai_camera/services/openrouter_client.dart';
import 'package:ai_camera/services/prompt_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Timed extends http.BaseClient {
  _Timed(this.inner);
  final http.Client inner;
  int reqBytes = 0;
  int respBytes = 0;
  int ms = 0;
  String shape = '';
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.Request) reqBytes = request.bodyBytes.length;
    final sw = Stopwatch()..start();
    final r = await inner.send(request);
    final bytes = await r.stream.toBytes();
    ms = sw.elapsedMilliseconds;
    respBytes = bytes.length;
    try {
      final j = jsonDecode(utf8.decode(bytes));
      if (j is Map) {
        final data = j['data'];
        shape = 'status ${r.statusCode} keys=${j.keys.toList()} '
            'data=${data is List ? data.length : data} '
            'item0=${data is List && data.isNotEmpty ? (data.first as Map).keys.toList() : null} '
            'err=${j['error'] ?? ''}';
      }
    } catch (_) {
      shape = 'status ${r.statusCode} non-json';
    }
    return http.StreamedResponse(Stream.value(bytes), r.statusCode,
        headers: r.headers, request: request);
  }
}

void main() {
  test('look bench', () async {
    final env = Platform.environment;
    final file = File(env['BENCH_IMAGE']!);
    final tier = QualityTier.fromId(env['BENCH_TIER'] ?? 'full_hd');
    final real = env['BENCH_REAL'] == '1';
    final prompt = buildLookPrompt(customPrompt: env['BENCH_PROMPT'] ?? 'black suit');
    final fakePng = base64Encode(File('${file.parent.path}/portrait.jpg').readAsBytesSync());
    final inner = real
        ? http.Client()
        : MockClient((_) async => http.Response(
            jsonEncode({'data': [{'b64_json': fakePng}], 'usage': {'cost': 0}}), 200));
    final timed = _Timed(inner);
    final client = OpenRouterClient(
        httpClient: timed, apiKey: real ? env['OPENROUTER_API_KEY'] : 'mock');
    final sw = Stopwatch()..start();
    try {
      final r = await client.generateLook(image: file, prompt: prompt, tier: tier);
      final total = sw.elapsedMilliseconds;
      final out = '${Directory.systemTemp.path}/bench_out_${tier.id}_${DateTime.now().millisecondsSinceEpoch}.img';
      File(out).writeAsBytesSync(r.images.first);
      // ignore: avoid_print
      print('BENCH ok tier=${tier.id} input=${file.lengthSync()}B request=${timed.reqBytes}B '
          'response=${timed.respBytes}B network=${timed.ms}ms total=${total}ms '
          'local=${total - timed.ms}ms out=${r.images.first.length}B cost=${r.cost} file=$out\n${timed.shape}');
    } catch (e) {
      // ignore: avoid_print
      print('BENCH error after ${sw.elapsedMilliseconds}ms network=${timed.ms}ms '
          'request=${timed.reqBytes}B: $e\n${timed.shape}');
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}
